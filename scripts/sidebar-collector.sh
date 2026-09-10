#!/usr/bin/env bash

# Sidebar data collector daemon.
# One instance per tmux server. Sources lib/collect.sh for data collection
# and writes a cache file that all sidebar renderers read from.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/session-status.sh"
source "$SCRIPT_DIR/lib/collect.sh"
source "$SCRIPT_DIR/lib/status-summary.sh"
source "$SCRIPT_DIR/lib/sidebar-clients.sh"

CACHE_FILE="$STATUS_DIR/.sidebar-cache"
PID_FILE="$STATUS_DIR/.sidebar-collector.pid"
LOCK_FILE="$STATUS_DIR/.sidebar-collector.flock"
RUN_ONCE=0

# Poll tuning. The loop wakes every TICK_SECONDS to animate the spinner for
# active sessions, and runs the (much more expensive) collection every
# TICKS_PER_COLLECT wakeups.
#
# Defaults are 1s tick / 5s collect. Override with tmux options:
#   set -g @agent-tick-seconds 0.25
#   set -g @agent-ticks-per-collect 4
TICK_SECONDS=$(tmux show-option -gqv "@agent-tick-seconds" 2>/dev/null)
[ -z "$TICK_SECONDS" ] && TICK_SECONDS=1
TICKS_PER_COLLECT=$(tmux show-option -gqv "@agent-ticks-per-collect" 2>/dev/null)
[ -z "$TICKS_PER_COLLECT" ] && TICKS_PER_COLLECT=5

# Validate once at startup: invalid sleep values would busy-loop, and a zero
# collection count would terminate the daemon in the modulo expression.
if [[ ! "$TICK_SECONDS" =~ ^[0-9]*\.?[0-9]+$ || ! "$TICK_SECONDS" =~ [1-9] ]]; then
    echo 'tmux-agent-status: @agent-tick-seconds must be positive; using 1' >&2
    TICK_SECONDS=1
fi
if [[ "$TICKS_PER_COLLECT" =~ ^0*([1-9][0-9]{0,8})$ ]]; then
    TICKS_PER_COLLECT="${BASH_REMATCH[1]}"
else
    echo 'tmux-agent-status: @agent-ticks-per-collect must be an integer from 1 to 999999999; using 5' >&2
    TICKS_PER_COLLECT=5
fi

if [[ "${1:-}" == "--once" ]]; then
    RUN_ONCE=1
fi

# Only the persistent daemon owns the singleton lock. One-shot refreshes use
# their own temporary cache files and must not remove the daemon's PID file.
if (( ! RUN_ONCE )); then
    if [[ "${1:-}" != --lock-held ]]; then
        exec "$BASH" "$SCRIPT_DIR/with-collector-lock.sh" "$LOCK_FILE" \
            "$BASH" "${BASH_SOURCE[0]}" --lock-held
    fi
    # Also respect a daemon started before the kernel-lock implementation.
    old_pid=$(cat "$PID_FILE" 2>/dev/null)
    if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
        exit 0
    fi
    echo $$ > "$PID_FILE"
    trap 'rm -f "$PID_FILE"' EXIT
    trap 'exit 0' INT TERM HUP
fi

# Persistent cross-cycle state (survives across collect_data calls)
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
SUMMARY_WORKING=0
SUMMARY_WAITING=0
SUMMARY_DONE=0
SUMMARY_TOTAL=0
SUMMARY_HAS_WORKING=0
SUMMARY_AGENTS=()

_tab=$'\t'

serialize_cache() {
    {
        echo "TS:$(date +%s)"
        echo "SESS_START:$SESS_START"
        for sname in "${!PANE_COUNTS[@]}"; do
            echo "PC:${sname}:${PANE_COUNTS[$sname]}"
        done
        local si=0
        for entry in "${ENTRIES[@]}"; do
            local etype="${entry%%|*}"
            if [[ "$etype" == "G" ]]; then
                echo "E:${entry}"
            else
                printf 'R:%s\t%s\t%s\n' "$entry" "${SEL_NAMES[$si]}" "${SEL_TYPES[$si]}"
                ((si++))
            fi
        done
    } > "${CACHE_FILE}.tmp.$$"
    mv -f "${CACHE_FILE}.tmp.$$" "$CACHE_FILE"
}

publish_status_summary() {
    local prev_done=""

    if [ -f "$STATUS_LINE_COUNTS_FILE" ]; then
        IFS=: read -r _ _ prev_done _ < "$STATUS_LINE_COUNTS_FILE"
    fi

    write_status_summary_cache \
        "$SUMMARY_WORKING" \
        "$SUMMARY_WAITING" \
        "$SUMMARY_DONE" \
        "$SUMMARY_TOTAL" \
        "${SUMMARY_AGENTS[@]}"

    if (( ! RUN_ONCE )) && [ -n "$prev_done" ] && [ "$SUMMARY_DONE" -gt "$prev_done" ]; then
        "$SCRIPT_DIR/play-sound.sh" &
    fi
}

tick=0
while true; do
    tmux list-sessions >/dev/null 2>&1 || exit 0

    if (( tick == 0 )); then
        collect_data
        if (( _COLLECT_CHANGED )); then
            serialize_cache
            publish_status_summary
            (( ! RUN_ONCE )) && signal_sidebar_clients USR1 all
        fi
    fi

    if (( RUN_ONCE )); then
        exit 0
    fi

    if (( SUMMARY_HAS_WORKING )); then
        signal_sidebar_clients USR2 active
    fi

    sleep "$TICK_SECONDS"
    tick=$(( (tick + 1) % TICKS_PER_COLLECT ))
done
