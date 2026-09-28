#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
PARKED_DIR="$STATUS_DIR/parked"
PANE_DIR="$STATUS_DIR/panes"

mkdir -p "$FAKE_BIN" "$STATUS_DIR" "$PARKED_DIR" "$PANE_DIR"

tab=$'\t'
cat > "$FAKE_BIN/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail

case "\${1:-}" in
    list-sessions)
        case "\${2:-}" in
            -F)
                case "\${3:-}" in
                    "#{session_name}")
                        echo "parked-task"
                        ;;
                    *)
                        exit 1
                        ;;
                esac
                ;;
            *)
                exit 1
                ;;
        esac
        ;;
    list-panes)
        case "\${2:-}" in
            -a)
                # session, pane_id, win_idx, win_name, pane_cmd, pane_title
                printf 'parked-task${tab}%%1${tab}0${tab}bash${tab}bash${tab}\n'
                ;;
            -t)
                case "\${5:-}" in
                    "#{pane_id}") echo "%1" ;;
                    "#{pane_pid}") echo "300" ;;
                    *) exit 0 ;;
                esac
                ;;
        esac
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"

# Simulate a running Claude agent in the session
cat > "$FAKE_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
    "-P 300")
        echo "301"
        ;;
    "-P 301"*)
        exit 1
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$FAKE_BIN/pgrep"

cat > "$FAKE_BIN/ps" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" != "-eo" ] || [ "${2:-}" != "pid=,ppid=,args=" ]; then
    exit 1
fi
cat <<'OUT'
300 1 -zsh
301 300 claude --model opus
OUT
EOF
chmod +x "$FAKE_BIN/ps"

cat > "$FAKE_BIN/pkill" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_BIN/pkill"

echo "parked" > "$PANE_DIR/parked-task_%1.status"
: > "$PARKED_DIR/parked-task_%1.parked"
mkdir -p "$STATUS_DIR/completions/4242"
completion_record="$STATUS_DIR/completions/4242/%1.saved.unread"
printf '%%1\t300\t123\tclaude\n' > "$completion_record"

reset_output="$(PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" "$REPO_DIR/scripts/hook-based-switcher.sh" --reset)"

# Parked panes should show magenta P icon (ESC[1;35m) after reset
if ! printf '%s\n' "$reset_output" | grep -q $'\033\[1;35m'; then
    echo "Assertion failed: reset output should still show parked icon" >&2
    exit 1
fi
if ! printf '%s\n' "$reset_output" | grep -Fq "parked-task"; then
    echo "Assertion failed: parked sessions should remain visible after reset" >&2
    exit 1
fi
# Parked marker file should survive reset
if [ ! -f "$PARKED_DIR/parked-task_%1.parked" ]; then
    echo "Assertion failed: parked marker should survive reset" >&2
    exit 1
fi
if [ ! -f "$completion_record" ]; then
    echo "Assertion failed: unread completion history should survive reset" >&2
    exit 1
fi

echo "switcher reset parked preservation regression checks passed"
