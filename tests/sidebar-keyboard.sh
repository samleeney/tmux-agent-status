#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR=$(mktemp -d)
socket="$TMP_DIR/tmux.sock"
cleanup() {
    tmux -S "$socket" kill-server >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT
mkdir -p "$TMP_DIR/home"
tmux -S "$socket" -f /dev/null new-session -d -s keyboard -x 80 -y 24 'sleep 120'
target=$(tmux -S "$socket" display-message -p -t keyboard '#{pane_id}')
printf -v launch 'env HOME=%q bash %q' "$TMP_DIR/home" "$REPO_DIR/scripts/sidebar.sh"
sidebar=$(tmux -S "$socket" split-window -h -b -l 34 -t keyboard -P -F '#{pane_id}' "$launch")
registry="$TMP_DIR/home/.cache/tmux-agent-status/sidebar-clients/$sidebar.pid"
for ((i=0; i<100; i++)); do
    [[ -s "$registry" ]] && break
    sleep 0.02
done
[[ -s "$registry" ]]
sidebar_pid=$(cat "$registry")

# Unknown CSI and SS3 sequences must leave the pane alive. Modifier bytes
# must also be consumed rather than appearing in the search query.
tmux -S "$socket" send-keys -t "$sidebar" Left Home End PPage NPage F1 C-Right
sleep 0.15
kill -0 "$sidebar_pid"
tmux -S "$socket" send-keys -t "$sidebar" /
tmux -S "$socket" send-keys -t "$sidebar" C-Right
sleep 0.15
screen=$(tmux -S "$socket" capture-pane -p -t "$sidebar")
if [[ "$screen" == *5C* ]]; then
    echo 'Modifier sequence leaked into sidebar search' >&2
    exit 1
fi
tmux -S "$socket" send-keys -t "$sidebar" Escape
sleep 0.15
kill -0 "$sidebar_pid"
kill -USR1 "$sidebar_pid"
sleep 0.05
tmux -S "$socket" send-keys -t "$sidebar" Right
sleep 0.15
[[ $(tmux -S "$socket" display-message -p -t keyboard '#{pane_id}') == "$target" ]]
tmux -S "$socket" send-keys -t "$sidebar" Escape
for ((i=0; i<100; i++)); do
    if ! tmux -S "$socket" list-panes -t keyboard -F '#{pane_id}' | grep -Fxq -- "$sidebar"; then
        echo 'Sidebar keyboard and refresh-signal checks passed'
        exit 0
    fi
    sleep 0.02
done
echo 'Bare Escape did not close the sidebar' >&2
exit 1
