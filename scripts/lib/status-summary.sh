#!/usr/bin/env bash

[[ -n "${_STATUS_SUMMARY_LOADED:-}" ]] && return 0
_STATUS_SUMMARY_LOADED=1

# The status bar shows one glyph per agent. The glyph identifies the agent
# type, the colour identifies its status, and working agents flip between
# two glyph frames once per second (tmux status-interval is 1) so busy
# agents visibly pulse while idle ones hold still.
#
# Agents are passed around as "name:status" specs, e.g. "codex:working".

# Per-agent-type glyph frames: "frameA frameB". Text-presentation symbols
# (not emoji) so tmux colour styles apply.
agent_glyph_frames() {
    case "$1" in
        claude) echo "✳ ✻" ;;
        codex)  echo "⬢ ⬡" ;;
        devin)  echo "◆ ◇" ;;
        *)      echo "● ○" ;;
    esac
}

# Per-status tmux style prefix.
agent_status_style() {
    case "$1" in
        working) echo "#[fg=yellow,bold]" ;;
        wait)    echo "#[fg=cyan]" ;;
        ask)     echo "#[fg=magenta,bold]" ;;
        *)       echo "#[fg=green]" ;;
    esac
}

# Current animation frame (0 or 1), derived from the wall clock.
# TMUX_AGENT_STATUS_FRAME overrides it so tests stay deterministic.
status_summary_frame() {
    if [ -n "${TMUX_AGENT_STATUS_FRAME:-}" ]; then
        printf '%s\n' "$TMUX_AGENT_STATUS_FRAME"
        return
    fi
    local now
    printf -v now '%(%s)T' -1
    printf '%s\n' $(( now % 2 ))
}

# render_status_summary <frame> [name:status ...]
# One glyph per agent spec, in the order given.
render_status_summary() {
    local frame="$1"
    shift

    if [ "$#" -eq 0 ]; then
        echo ""
        return
    fi

    local spec name status glyph_a glyph_b glyph
    local i=0
    local parts=()
    for spec in "$@"; do
        name="${spec%%:*}"
        status="${spec#*:}"
        read -r glyph_a glyph_b <<< "$(agent_glyph_frames "$name")"
        glyph="$glyph_a"
        if [ "$status" = "working" ] && (( (frame + i) % 2 == 1 )); then
            glyph="$glyph_b"
        fi
        parts+=("$(agent_status_style "$status")${glyph}#[default]")
        i=$((i + 1))
    done
    printf '%s\n' "${parts[*]}"
}

# write_status_summary_cache <working> <waiting> <done> <total> [name:status ...]
# The counts feed the counts file (used for done-notification diffing); the
# agent specs feed the rendered cache. The cache stores one line per
# animation frame; the status line picks the line matching the current frame
# so the animation keeps running even when the collector has no data changes
# to publish.
write_status_summary_cache() {
    local working="$1"
    local waiting="$2"
    local done="$3"
    local total_agents="$4"
    shift 4

    printf '%s\n' "$working:$waiting:$done:$total_agents" > "${STATUS_LINE_COUNTS_FILE}.tmp.$$"
    mv -f "${STATUS_LINE_COUNTS_FILE}.tmp.$$" "$STATUS_LINE_COUNTS_FILE"
    {
        render_status_summary 0 "$@"
        render_status_summary 1 "$@"
    } > "${STATUS_LINE_CACHE_FILE}.tmp.$$"
    mv -f "${STATUS_LINE_CACHE_FILE}.tmp.$$" "$STATUS_LINE_CACHE_FILE"
}
