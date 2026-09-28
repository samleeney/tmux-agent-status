#!/usr/bin/env bash

# Devin CLI hook for tmux-agent-status.
# Hook events are passed as the first argument by the configured Devin command
# hook. The JSON payload is read from stdin and ignored
# here because tmux-agent-status only needs the event name to update session
# state.

STATUS_DIR="$HOME/.cache/tmux-agent-status"
WAIT_DIR="$STATUS_DIR/wait"
PARKED_DIR="$STATUS_DIR/parked"
PANE_DIR="$STATUS_DIR/panes"
REFRESH_FILE="$STATUS_DIR/.sidebar-refresh"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib/completion-inbox.sh
source "$HOOK_DIR/../scripts/lib/completion-inbox.sh"
mkdir -p "$STATUS_DIR" "$WAIT_DIR" "$PARKED_DIR" "$PANE_DIR"
[ -f "$REFRESH_FILE" ] || : > "$REFRESH_FILE"

# Drain the JSON payload from stdin so Devin can close the hook cleanly.
cat >/dev/null 2>&1 || true

in_remote_session() {
    [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_TTY:-}" ]
}

get_tmux_session() {
    local tmux_session=""

    # Hooks belong to their agent pane, even when another client/window has focus.
    if [ -n "${TMUX_PANE:-}" ]; then
        tmux_session=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
        if [ -n "$tmux_session" ]; then
            printf '%s\n' "$tmux_session"
            return 0
        fi
    fi

    if [ -n "${TMUX:-}" ] || in_remote_session; then
        tmux_session=$(tmux display-message -p '#{session_name}' 2>/dev/null)

        if [ -z "$tmux_session" ]; then
            if in_remote_session; then
                case "$(hostname -s 2>/dev/null)" in
                    instance-*) tmux_session="reachgpu" ;;
                    keen-schrodinger) tmux_session="sd1" ;;
                    sam-l4-workstation-image) tmux_session="l4-workstation" ;;
                    persistent-faraday) tmux_session="tig" ;;
                    instance-20250620-122051) tmux_session="reachgpu" ;;
                    *) tmux_session=$(hostname -s 2>/dev/null) ;;
                esac
            elif [ -n "${TMUX:-}" ]; then
                local socket_path="${TMUX%%,*}"
                tmux_session=$(basename "$socket_path")
            fi
        fi
    fi

    [ -n "$tmux_session" ] || return 1
    printf '%s\n' "$tmux_session"
}

set_status() {
    local tmux_session="$1"
    local requested_status="$2"
    local session_status="$requested_status"
    local status_file="$STATUS_DIR/${tmux_session}.status"
    local remote_status_file="$STATUS_DIR/${tmux_session}-remote.status"

    if [ -n "${TMUX_PANE:-}" ]; then
        local pane_file="$PANE_DIR/${tmux_session}_${TMUX_PANE}.status"
        local agent_file="$PANE_DIR/${tmux_session}_${TMUX_PANE}.agent"
        local previous_status=""
        [ -f "$pane_file" ] && previous_status=$(cat "$pane_file" 2>/dev/null)
        echo "$requested_status" > "$pane_file"
        echo "devin" > "$agent_file"
        if [ "${HOOK_TYPE:-}" = Stop ]; then
            completion_record "$TMUX_PANE" devin "$previous_status" "$requested_status"
        fi

        session_status="done"
        local existing_pane_file=""
        for existing_pane_file in "$PANE_DIR/${tmux_session}_"*.status; do
            [ -f "$existing_pane_file" ] || continue

            local pane_status=""
            pane_status=$(cat "$existing_pane_file" 2>/dev/null || echo "")
            case "$pane_status" in
                working)
                    session_status="working"
                    break
                    ;;
                wait)
                    if [ "$session_status" != "working" ]; then
                        session_status="wait"
                    fi
                    ;;
            esac
        done
    fi

    echo "$session_status" > "$status_file"
    if in_remote_session; then
        echo "$session_status" > "$remote_status_file" 2>/dev/null
    fi
}

clear_interaction_overrides() {
    local tmux_session="$1"
    local session_wait_file="$WAIT_DIR/${tmux_session}.wait"
    local session_parked_file="$PARKED_DIR/${tmux_session}.parked"

    if [ -f "$session_wait_file" ]; then
        rm -f "$session_wait_file" "$WAIT_DIR/${tmux_session}_"*.wait 2>/dev/null
    elif [ -n "${TMUX_PANE:-}" ]; then
        rm -f "$WAIT_DIR/${tmux_session}_${TMUX_PANE}.wait"
    fi

    if [ -f "$session_parked_file" ]; then
        rm -f "$session_parked_file" "$PARKED_DIR/${tmux_session}_"*.parked 2>/dev/null
    elif [ -n "${TMUX_PANE:-}" ]; then
        rm -f "$PARKED_DIR/${tmux_session}_${TMUX_PANE}.parked"
    fi
}

mark_refresh() {
    touch "$REFRESH_FILE" 2>/dev/null || true
}

TMUX_SESSION=$(get_tmux_session) || exit 0
HOOK_TYPE="${1:-}"
WAIT_FILE="$WAIT_DIR/${TMUX_SESSION}.wait"
PARKED_FILE="$PARKED_DIR/${TMUX_SESSION}.parked"

case "$HOOK_TYPE" in
    SessionStart)
        if [ ! -f "$WAIT_FILE" ] && [ ! -f "$PARKED_FILE" ]; then
            set_status "$TMUX_SESSION" "done"
            mark_refresh
        fi
        ;;
    UserPromptSubmit)
        clear_interaction_overrides "$TMUX_SESSION"
        set_status "$TMUX_SESSION" "working"
        mark_refresh
        ;;
    PreToolUse|PostToolUse)
        rm -f "$WAIT_FILE"
        if [ ! -f "$PARKED_FILE" ]; then
            set_status "$TMUX_SESSION" "working"
        fi
        mark_refresh
        ;;
    Stop)
        set_status "$TMUX_SESSION" "done"
        mark_refresh
        ;;
esac

exit 0
