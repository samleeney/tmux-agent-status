#!/usr/bin/env bash

# Unread completions are separate from live agent status. Records belong to a
# tmux server and pane process, not a session name (which can be renamed).
# Keep this helper Bash 3 compatible: agent hooks also source it on macOS.
[[ -n "${_COMPLETION_INBOX_LOADED:-}" ]] && return 0
_COMPLETION_INBOX_LOADED=1

completion_inbox_init() {
    local server="${TMUX:-}"
    server="${server#*,}"
    server="${server%%,*}"
    case "$server" in
        ''|*[!0-9]*) server=$(tmux display-message -p '#{pid}' 2>/dev/null) ;;
    esac
    case "$server" in ''|*[!0-9]*) return 1 ;; esac
    STATUS_DIR="${STATUS_DIR:-$HOME/.cache/tmux-agent-status}"
    COMPLETION_DIR="$STATUS_DIR/completions/$server"
}

completion_inbox_enabled() {
    [ "$(tmux show-option -gqv @agent-completion-inbox 2>/dev/null)" != off ]
}

completion_inbox_refresh() {
    touch "${STATUS_DIR:-$HOME/.cache/tmux-agent-status}/.sidebar-refresh" 2>/dev/null || true
}

# Snapshot filenames before observing focus. Removing exactly these immutable
# records cannot erase a new completion published while acknowledgement runs.
completion_ack_active() {
    completion_inbox_init || return 0
    local records=("$COMPLETION_DIR/"*.unread)
    [ -f "${records[0]}" ] || return 0
    local active file pane pid stamp agent
    active=$(tmux list-clients -F '#{pane_id}' 2>/dev/null) || return 0
    for file in "${records[@]}"; do
        IFS=$'\t' read -r pane pid stamp agent 2>/dev/null < "$file" || continue
        case $'\n'"$active"$'\n' in
            *$'\n'"$pane"$'\n'*) rm -f -- "$file"; completion_inbox_refresh ;;
        esac
    done
}

completion_mark_read() {
    local pane="$1"
    [[ "$pane" =~ ^%[0-9]+$ ]] || return 0
    completion_inbox_init || return 0
    local records=("$COMPLETION_DIR/$pane."*.unread)
    [ -f "${records[0]}" ] || return 0
    rm -f -- "${records[@]}"
    completion_inbox_refresh
}

# Called only for Stop events, with the state captured before the hook writes
# done. Startup, idle reminders and repeated Stop events are not completions.
completion_record() {
    local pane="$1" agent="$2" previous="$3" current="$4"
    [ "$current" = done ] || return 0
    case "$previous" in working|ask|wait|parked) ;; *) return 0 ;; esac
    [[ "$pane" =~ ^%[0-9]+$ ]] || return 0
    completion_inbox_init && completion_inbox_enabled || return 0

    local resolved pid temp file
    IFS=$'\t' read -r resolved pid < <(
        tmux display-message -p -t "$pane" '#{pane_id}'$'\t''#{pane_pid}' 2>/dev/null
    )
    [ "$resolved" = "$pane" ] || return 0
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    mkdir -p "$COMPLETION_DIR" || return 0
    local previous_records=("$COMPLETION_DIR/$pane."*.unread)
    temp=$(mktemp "$COMPLETION_DIR/.event.XXXXXX") || return 0
    printf '%s\t%s\t%s\t%s\n' "$pane" "$pid" "$(date +%s)" "$agent" > "$temp"
    file="$COMPLETION_DIR/$pane.${temp##*.}.unread"
    mv -f -- "$temp" "$file" || { rm -f -- "$temp"; return 0; }
    # Coalesce repeated completions, but never delete a concurrent new record.
    rm -f -- "${previous_records[@]}"
    completion_ack_active
    completion_inbox_refresh
}

# Emits timestamp, pane, session, window index, pane index, agent, window name.
# A live snapshot validates identities and supplies labels after renames. Only
# stale/dead targets are discarded; wait/park hide records without reading them.
completion_inbox_rows() {
    completion_inbox_init && completion_inbox_enabled || return 0
    local records=("$COMPLETION_DIR/"*.unread)
    [ -f "${records[0]}" ] || return 0
    local snapshot
    snapshot=$(tmux list-panes -a -F '#{pane_id}'$'\t''#{pane_pid}'$'\t''#{session_name}'$'\t''#{window_index}'$'\t''#{pane_index}'$'\t''#{window_name}'$'\t''#{pane_dead}' 2>/dev/null) || return 0
    local file pane pid stamp agent live_pane live_pid session window index name dead found expiry now
    now=$(date +%s)
    for file in "${records[@]}"; do
        IFS=$'\t' read -r pane pid stamp agent 2>/dev/null < "$file" || continue
        found=0
        while IFS=$'\t' read -r live_pane live_pid session window index name dead; do
            [ "$live_pane" = "$pane" ] && [ "$live_pid" = "$pid" ] && [ "$dead" != 1 ] || continue
            found=1
            if [ -f "$STATUS_DIR/parked/$session.parked" ] || [ -f "$STATUS_DIR/parked/${session}_${pane}.parked" ]; then
                break
            fi
            local deferred=0 wait_file
            for wait_file in "$STATUS_DIR/wait/$session.wait" "$STATUS_DIR/wait/${session}_${pane}.wait"; do
                [ -f "$wait_file" ] || continue
                expiry=$(cat "$wait_file" 2>/dev/null)
                if [ "$expiry" -gt "$now" ] 2>/dev/null; then deferred=1; fi
            done
            [ "$deferred" = 1 ] && break
            # UI cache rows use | as a separator. Never pass label control
            # characters into the terminal or allow labels to change the format.
            name=$(printf '%s' "$name" | tr '\t\r\n|' '    ' | LC_ALL=C tr -d '\000-\037\177')
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$stamp" "$pane" "$session" "$window" "$index" "$agent" "$name"
            break
        done <<< "$snapshot"
        [ "$found" = 1 ] || rm -f -- "$file"
    done | sort -t $'\t' -k1,1nr -k3,3 -k4,4n -k5,5n | awk -F '\t' '!seen[$2]++'
}
