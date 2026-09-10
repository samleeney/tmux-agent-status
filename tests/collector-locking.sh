#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR=$(mktemp -d)
children=()
cleanup() {
    touch "$TMP_DIR/flock/finish" "$TMP_DIR/perl/finish" 2>/dev/null || true
    for pid in "${daemon_pid:-}" "${next_pid:-}"; do
        [[ -n "$pid" && "$pid" != $$ ]] && kill "$pid" 2>/dev/null || true
    done
    for pid in "${children[@]}"; do kill "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT
real_sleep=$(command -v sleep)
real_perl=$(command -v perl || true)
real_flock=$(command -v flock || true)

wait_for_file() {
    local attempt
    for ((attempt=0; attempt<100; attempt++)); do
        [[ -s "$1" ]] && return 0
        "$real_sleep" 0.02
    done
    echo "Timed out waiting for $1" >&2
    return 1
}

cat > "$TMP_DIR/worker.sh" <<'EOF'
#!/usr/bin/env bash
echo $$ >> "$TEST_DIR/entered"
while [[ ! -f "$TEST_DIR/finish" ]]; do "$TEST_SLEEP" 0.02; done
EOF

for backend in flock perl; do
    binary="$real_flock"
    [[ "$backend" == perl ]] && binary="$real_perl"
    [[ -n "$binary" ]] || continue
    mkdir -p "$TMP_DIR/$backend/bin"
    ln -s "$binary" "$TMP_DIR/$backend/bin/$backend"
    run_dir="$TMP_DIR/$backend"
    start_worker() {
        PATH="$run_dir/bin" TEST_DIR="$run_dir" TEST_SLEEP="$real_sleep" \
            "$BASH" "$REPO_DIR/scripts/with-collector-lock.sh" "$run_dir/lock" \
            "$BASH" "$TMP_DIR/worker.sh" &
        children+=("$!")
    }

    for ((i=0; i<8; i++)); do start_worker; done
    wait_for_file "$run_dir/entered"
    "$real_sleep" 0.15
    [[ $(wc -l < "$run_dir/entered") -eq 1 ]]

    # Kill the owning command without cleanup. The kernel must release the
    # lock once its short-lived child exits, even though the file still exists.
    owner=$(cat "$run_dir/entered")
    kill -9 "$owner"
    for pid in "${children[@]}"; do wait "$pid" 2>/dev/null || true; done
    children=()
    "$real_sleep" 0.1
    mv "$run_dir/entered" "$run_dir/first-owner"
    start_worker
    wait_for_file "$run_dir/entered"
    [[ $(cat "$run_dir/entered") != "$owner" ]]
    touch "$run_dir/finish"
    for pid in "${children[@]}"; do wait "$pid"; done
    children=()
    [[ -f "$run_dir/lock" ]]
    echo "$backend contention and crash-recovery checks passed"
done

# --once must run without disturbing a live daemon's PID or lock files.
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home/.cache/tmux-agent-status"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_DIR/bin/tmux"
chmod +x "$TMP_DIR/bin/tmux"
status_dir="$TMP_DIR/home/.cache/tmux-agent-status"
echo $$ > "$status_dir/.sidebar-collector.pid"
echo lock-marker > "$status_dir/.sidebar-collector.flock"
PATH="$TMP_DIR/bin:$PATH" HOME="$TMP_DIR/home" \
    bash "$REPO_DIR/scripts/sidebar-collector.sh" --once
[[ $(cat "$status_dir/.sidebar-collector.pid") == $$ ]]
[[ $(cat "$status_dir/.sidebar-collector.flock") == lock-marker ]]
[[ -f "$status_dir/.sidebar-cache" ]]
echo 'One-shot collector preserves daemon ownership'

# Concurrent refreshes must not overwrite or rename one another's temp files.
for ((i=0; i<8; i++)); do
    PATH="$TMP_DIR/bin:$PATH" HOME="$TMP_DIR/home" \
        bash "$REPO_DIR/scripts/sidebar-collector.sh" --once 2> "$TMP_DIR/once-$i.errors" &
    children+=("$!")
done
for pid in "${children[@]}"; do wait "$pid"; done
children=()
for ((i=0; i<8; i++)); do [[ ! -s "$TMP_DIR/once-$i.errors" ]]; done
echo 'Concurrent one-shot cache publication checks passed'

# Exercise the complete daemon startup path, including the PID metadata left
# by SIGKILL, rather than only testing the lock wrapper in isolation.
rm -f "$status_dir/.sidebar-collector.pid"
start_daemon() {
    PATH="$TMP_DIR/bin:$PATH" HOME="$TMP_DIR/home" \
        bash "$REPO_DIR/scripts/sidebar-collector.sh" &
    daemon_wrapper=$!
    children+=("$daemon_wrapper")
}
start_daemon
wait_for_file "$status_dir/.sidebar-collector.pid"
daemon_pid=$(cat "$status_dir/.sidebar-collector.pid")
PATH="$TMP_DIR/bin:$PATH" HOME="$TMP_DIR/home" \
    bash "$REPO_DIR/scripts/sidebar-collector.sh"
PATH="$TMP_DIR/bin:$PATH" HOME="$TMP_DIR/home" \
    bash "$REPO_DIR/scripts/sidebar-collector.sh" --once
[[ $(cat "$status_dir/.sidebar-collector.pid") == "$daemon_pid" ]]
kill -9 "$daemon_pid"
wait "$daemon_wrapper" 2>/dev/null || true
children=()
[[ $(cat "$status_dir/.sidebar-collector.pid") == "$daemon_pid" ]]
# Any inherited descriptor held by the current one-second sleep closes too.
sleep 1.1
start_daemon
for ((i=0; i<100; i++)); do
    next_pid=$(cat "$status_dir/.sidebar-collector.pid")
    [[ "$next_pid" != "$daemon_pid" ]] && break
    sleep 0.02
done
[[ "$next_pid" != "$daemon_pid" ]]
kill -TERM "$next_pid"
wait "$daemon_wrapper"
children=()
[[ ! -f "$status_dir/.sidebar-collector.pid" ]]
echo 'Daemon singleton, stale PID recovery, and graceful cleanup checks passed'
