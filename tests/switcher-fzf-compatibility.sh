#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home"

cat > "$TMP_DIR/bin/tmux" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$TMP_DIR/bin/fzf" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --help ]]; then
    [[ "$TEST_FZF_IDENTITY" == 1 ]] && echo '  --id-nth=NTH'
    exit 0
fi
printf '%s\n' "$@" > "$TEST_FZF_ARGS"
cat >/dev/null
EOF
chmod +x "$TMP_DIR/bin/"*

for supported in 0 1; do
    PATH="$TMP_DIR/bin:$PATH" HOME="$TMP_DIR/home" \
        TEST_FZF_IDENTITY="$supported" TEST_FZF_ARGS="$TMP_DIR/args" \
        bash "$REPO_DIR/scripts/hook-based-switcher.sh"
    if [[ "$supported" == 1 ]]; then
        grep -Fxq -- '--track' "$TMP_DIR/args"
        grep -Fxq -- '--id-nth=1,2' "$TMP_DIR/args"
    else
        if grep -Eq -- '^--(track|id-nth)' "$TMP_DIR/args"; then
            echo 'Older fzf must not receive identity tracking options' >&2
            exit 1
        fi
    fi
done
echo 'fzf compatibility checks passed'
