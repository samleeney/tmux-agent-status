#!/usr/bin/env bash

# Shared selection helpers for sidebar and popup switcher targets.

[[ -n "${_SELECTION_TARGETS_LOADED:-}" ]] && return 0
_SELECTION_TARGETS_LOADED=1

# shellcheck source=completion-inbox.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/completion-inbox.sh"

selection_scope() {
    local sel_name="$1"
    local sel_type="$2"

    case "$sel_type" in
        S|W)
            echo "session"
            ;;
        P|C)
            local target="${sel_name#*:}"
            if [[ "$target" == w* ]]; then
                echo "window"
            else
                echo "pane"
            fi
            ;;
        *)
            echo ""
            return 1
            ;;
    esac
}

selection_session() {
    local sel_name="$1"
    local sel_type="$2"

    case "$sel_type" in
        P|C)
            echo "${sel_name%%:*}"
            ;;
        *)
            echo "$sel_name"
            ;;
    esac
}

selection_token() {
    local sel_name="$1"
    local sel_type="$2"

    if [[ "$sel_type" == "P" || "$sel_type" == "C" ]]; then
        echo "${sel_name#*:}"
    else
        echo "$sel_name"
    fi
}

selection_window_index() {
    local sel_name="$1"
    local sel_type="$2"
    local scope token
    scope=$(selection_scope "$sel_name" "$sel_type") || return 1
    token=$(selection_token "$sel_name" "$sel_type")

    case "$scope" in
        window)
            echo "${token#w}"
            ;;
        pane)
            tmux display-message -p -t "$token" "#{window_index}" 2>/dev/null
            ;;
        session)
            tmux display-message -p -t "$(selection_session "$sel_name" "$sel_type")" "#{window_index}" 2>/dev/null
            ;;
    esac
}

selection_tmux_target() {
    local sel_name="$1"
    local sel_type="$2"
    local scope token session
    scope=$(selection_scope "$sel_name" "$sel_type") || return 1
    token=$(selection_token "$sel_name" "$sel_type")
    session=$(selection_session "$sel_name" "$sel_type")

    case "$scope" in
        session)
            echo "$session"
            ;;
        window)
            echo "${session}:${token#w}"
            ;;
        pane)
            echo "$token"
            ;;
    esac
}

selection_requires_confirmation() {
    # Customized: close sessions/windows/panes immediately without a
    # confirmation prompt. Original behavior asked to confirm for any
    # non-pane scope: [ "$scope" != "pane" ].
    return 1
}

selection_label() {
    local sel_name="$1"
    local sel_type="$2"
    local scope session token window_index window_name
    scope=$(selection_scope "$sel_name" "$sel_type") || return 1
    session=$(selection_session "$sel_name" "$sel_type")
    token=$(selection_token "$sel_name" "$sel_type")

    case "$scope" in
        session)
            printf 'session %s' "$session"
            ;;
        window)
            window_index="${token#w}"
            window_name=$(tmux display-message -p -t "${session}:${window_index}" "#{window_name}" 2>/dev/null || true)
            if [ -n "$window_name" ]; then
                printf 'window %s:%s (%s)' "$session" "$window_index" "$window_name"
            else
                printf 'window %s:%s' "$session" "$window_index"
            fi
            ;;
        pane)
            window_index=$(tmux display-message -p -t "$token" "#{window_index}" 2>/dev/null || true)
            if [ -n "$window_index" ]; then
                printf 'pane %s in %s:%s' "$token" "$session" "$window_index"
            else
                printf 'pane %s' "$token"
            fi
            ;;
    esac
}

selection_close_prompt() {
    local sel_name="$1"
    local sel_type="$2"
    local scope label
    scope=$(selection_scope "$sel_name" "$sel_type") || return 1
    label=$(selection_label "$sel_name" "$sel_type")

    case "$scope" in
        session)
            printf 'Close %s and all child windows and panes?' "$label"
            ;;
        window)
            printf 'Close %s and all child panes?' "$label"
            ;;
        pane)
            printf 'Close %s?' "$label"
            ;;
    esac
}

selection_list_panes() {
    local sel_name="$1"
    local sel_type="$2"
    local scope session token
    scope=$(selection_scope "$sel_name" "$sel_type") || return 1
    session=$(selection_session "$sel_name" "$sel_type")
    token=$(selection_token "$sel_name" "$sel_type")

    case "$scope" in
        session)
            tmux list-panes -t "$session" -F "#{pane_id}" 2>/dev/null
            ;;
        window)
            tmux list-panes -t "${session}:${token#w}" -F "#{pane_id}" 2>/dev/null
            ;;
        pane)
            printf '%s\n' "$token"
            ;;
    esac
}

selection_includes_current_client() {
    local sel_name="$1"
    local sel_type="$2"
    local scope session token
    local current_session current_window current_pane

    scope=$(selection_scope "$sel_name" "$sel_type") || return 1
    session=$(selection_session "$sel_name" "$sel_type")
    token=$(selection_token "$sel_name" "$sel_type")
    current_session=$(tmux display-message -p "#{client_session}" 2>/dev/null || true)
    current_window=$(tmux display-message -p "#{window_index}" 2>/dev/null || true)
    current_pane=$(tmux display-message -p "#{pane_id}" 2>/dev/null || true)

    case "$scope" in
        session)
            [ "$session" = "$current_session" ]
            ;;
        window)
            [ "$session" = "$current_session" ] && [ "${token#w}" = "$current_window" ]
            ;;
        pane)
            [ "$token" = "$current_pane" ]
            ;;
        *)
            return 1
            ;;
    esac
}

selection_switch_client() {
    local sel_name="$1"
    local sel_type="$2"
    local scope session token win_idx
    scope=$(selection_scope "$sel_name" "$sel_type") || return 1
    session=$(selection_session "$sel_name" "$sel_type")
    token=$(selection_token "$sel_name" "$sel_type")

    case "$scope" in
        pane)
            win_idx=$(tmux display-message -t "$token" -p "#{window_index}" 2>/dev/null || true)
            tmux switch-client -t "$session" 2>/dev/null
            [ -n "$win_idx" ] && tmux select-window -t "${session}:${win_idx}" 2>/dev/null
            tmux select-pane -t "$token" 2>/dev/null
            ;;
        window)
            tmux switch-client -t "$session" 2>/dev/null
            tmux select-window -t "${session}:${token#w}" 2>/dev/null
            ;;
        session)
            tmux switch-client -t "$session" 2>/dev/null
            ;;
    esac
    local switch_result=$?
    if [ "$switch_result" -eq 0 ]; then
        completion_ack_active
    fi
    return "$switch_result"
}

# Explicit acknowledgement applies to the selected scope. Merely highlighting
# or previewing a row never acknowledges it.
selection_mark_read() {
    local scope target pane
    scope=$(selection_scope "$1" "$2") || return 0
    target=$(selection_tmux_target "$1" "$2")
    case "$scope" in
        pane) completion_mark_read "$target" ;;
        window|session)
            local args=()
            [ "$scope" = session ] && args=(-s)
            while IFS= read -r pane; do
                completion_mark_read "$pane"
            done < <(tmux list-panes "${args[@]}" -t "$target" -F '#{pane_id}' 2>/dev/null)
            ;;
    esac
}
