#!/usr/bin/env bash

# Cycle through inbox targets in the same order shown in the sidebar.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/session-status.sh
source "$SCRIPT_DIR/lib/session-status.sh"
# shellcheck source=lib/selection-targets.sh
source "$SCRIPT_DIR/lib/selection-targets.sh"
# shellcheck source=lib/collect.sh
source "$SCRIPT_DIR/lib/collect.sh"

EXCLUDE_NAME=""
EXCLUDE_TYPE=""
if [[ "${1:-}" == "--exclude" ]]; then
    EXCLUDE_NAME="${2:-}"
    EXCLUDE_TYPE="${3:-}"
fi

current_session=$(tmux display-message -p "#{session_name}")
current_window=$(tmux display-message -p "#{window_index}")
current_pane=$(tmux display-message -p "#{pane_id}")

declare -A KNOWN_AGENTS=()
declare -A LIVE_PANES=()
declare -A PID_PPID=()
declare -A PANE_COUNTS=()
ENTRIES=()
SEL_NAMES=()
SEL_TYPES=()
SESS_START=0
_COLLECT_TICK=0
_LAST_STATUS_MTIME=""
_COLLECT_CHANGED=0

inbox_target_current_rank() {
    local sel_name="$1"
    local sel_type="$2"
    local scope session token

    scope=$(selection_scope "$sel_name" "$sel_type") || return 1
    session=$(selection_session "$sel_name" "$sel_type")
    token=$(selection_token "$sel_name" "$sel_type")

    case "$scope" in
        pane)
            if [ "$session" = "$current_session" ] && [ "$token" = "$current_pane" ]; then
                echo 3
            else
                echo 0
            fi
            ;;
        window)
            if [ "$session" = "$current_session" ] && [ "${token#w}" = "$current_window" ]; then
                echo 2
            else
                echo 0
            fi
            ;;
        session)
            if [ "$session" = "$current_session" ]; then
                echo 1
            else
                echo 0
            fi
            ;;
        *)
            echo 0
            ;;
    esac
}

inbox_target_is_excluded() {
    local sel_name="$1"
    local sel_type="$2"
    local candidate_session

    [ -n "$EXCLUDE_NAME" ] || return 1

    candidate_session=$(selection_session "$sel_name" "$sel_type")
    [ "$candidate_session" = "$(selection_session "$EXCLUDE_NAME" "$EXCLUDE_TYPE")" ]
}

collect_data

target_names=()
target_types=()
sel_index=0
for entry in "${ENTRIES[@]}"; do
    if [[ "${entry%%|*}" == "G" ]]; then
        continue
    fi
    if (( sel_index >= SESS_START )); then
        break
    fi
    target_names+=("${SEL_NAMES[$sel_index]}")
    target_types+=("${SEL_TYPES[$sel_index]}")
    sel_index=$((sel_index + 1))
done

# Unread completions take precedence; otherwise retain the live inbox order.
if (( ${RECENT_COUNT:-0} > 0 )); then
    target_names=("${target_names[@]:0:RECENT_COUNT}")
    target_types=("${target_types[@]:0:RECENT_COUNT}")
fi

if (( ${#target_names[@]} == 0 )); then
    tmux display-message "No inbox items"
    exit 1
fi

current_index=-1
current_rank=0
for i in "${!target_names[@]}"; do
    rank=$(inbox_target_current_rank "${target_names[$i]}" "${target_types[$i]}")
    if (( rank > current_rank )); then
        current_rank=$rank
        current_index=$i
    fi
done

next_index=-1
if (( current_index >= 0 )); then
    for ((step=1; step<=${#target_names[@]}; step++)); do
        idx=$(( (current_index + step) % ${#target_names[@]} ))
        if inbox_target_is_excluded "${target_names[$idx]}" "${target_types[$idx]}"; then
            continue
        fi
        next_index=$idx
        break
    done
else
    for i in "${!target_names[@]}"; do
        if inbox_target_is_excluded "${target_names[$i]}" "${target_types[$i]}"; then
            continue
        fi
        next_index=$i
        break
    done
fi

if (( next_index < 0 )); then
    tmux display-message "No inbox items"
    exit 1
fi

selection_switch_client "${target_names[$next_index]}" "${target_types[$next_index]}"
