#!/usr/bin/env bash

# Agent sidebar — persistent split-pane TUI showing session status.
# Supports worktree nesting and multi-agent pane display.
# Runs inside a tmux pane created by sidebar-toggle.sh.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$CURRENT_DIR")"

# shellcheck source=lib/session-status.sh
source "$CURRENT_DIR/lib/session-status.sh"
# shellcheck source=lib/sidebar-clients.sh
source "$CURRENT_DIR/lib/sidebar-clients.sh"
# shellcheck source=lib/selection-targets.sh
source "$CURRENT_DIR/lib/selection-targets.sh"
# shellcheck source=lib/sidebar-selection.sh
source "$CURRENT_DIR/lib/sidebar-selection.sh"

# ─── Mode ─────────────────────────────────────────────────────────
PREVIEW_MODE=0
[[ "${1:-}" == "--preview" ]] && PREVIEW_MODE=1

# ─── Terminal setup ───────────────────────────────────────────────
cleanup() {
    [ -n "${SELF_PANE:-}" ] && unregister_sidebar_client "$SELF_PANE"
    printf '\033[?1000l\033[?1006l' 2>/dev/null  # disable mouse
    tput cnorm 2>/dev/null
    stty echo 2>/dev/null
}

handle_refresh_signal() {
    NEEDS_COLLECT=1
    NEEDS_RENDER=1
    _PREVIEW_DIRTY=1
}

handle_animation_signal() {
    (( _HAS_WORKING )) && ANIMATE_TICK=1
}

# cleanup runs via the EXIT trap; the signal traps must actually exit —
# a bare handler would swallow the signal (tmux sends HUP when the pane
# closes) and leave an orphaned sidebar looping forever.
trap cleanup EXIT
trap 'exit 0' INT TERM HUP
trap handle_refresh_signal USR1
trap handle_animation_signal USR2
RESIZED=0
trap 'RESIZED=1' WINCH

tput civis  # hide cursor
stty -echo 2>/dev/null
# Enable mouse click tracking (SGR mode) only in sidebar pane mode.
# In popup/preview mode, skip mouse to avoid event storms.
if (( ! PREVIEW_MODE )); then
    printf '\033[?1000h\033[?1006h'
    SELF_PANE="${TMUX_PANE:-}"
    if [ -z "$SELF_PANE" ]; then
        SELF_TTY="$(tty 2>/dev/null | sed 's#/dev/##')"
        if [ -n "$SELF_TTY" ]; then
            while IFS=$'\t' read -r pane_id pane_tty; do
                if [ "$pane_tty" = "$SELF_TTY" ]; then
                    SELF_PANE="$pane_id"
                    break
                fi
            done < <(tmux list-panes -a -F '#{pane_id}'$'\t''#{pane_tty}' 2>/dev/null)
        fi
    fi
    [ -n "$SELF_PANE" ] || SELF_PANE="$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)"
    if [ -n "$SELF_PANE" ]; then
        tmux select-pane -t "$SELF_PANE" -T "$SIDEBAR_TITLE" >/dev/null 2>&1 || true
        register_sidebar_client "$SELF_PANE" >/dev/null 2>&1 || true
    fi
fi

# ─── State ────────────────────────────────────────────────────────
SELECTED=0
SCROLL_OFFSET=0
SESS_START=0  # index in SEL_NAMES where SESSIONS section begins
SEARCH_QUERY=""
SEARCH_ACTIVE=0

# Cached values from collect(), used by render().
CUR_SESSION=""
CUR_PANE=""


# Screen row (1-based) → selectable index. Populated by render().
declare -a SCREEN_SEL=()
declare -a SPINNER_ROWS=()
declare -a SPINNER_COLS=()
declare -a SPINNER_BGS=()
declare -a SPINNER_STYLES=()

# Change detection: skip collect when status dir hasn't changed.
_LAST_STATUS_MTIME=""
_COLLECT_TICK=0
_HAS_WORKING=0

# Flat list rebuilt each frame.  Each element is one of:
#   "G|<label>|<color>"                          — group header (not selectable)
#   "S|<name>|<state>|<extra>|<ssh>"             — session (selectable)
#   "W|<name>|<state>|<extra>|<ssh>|<is_last>"   — worktree child (selectable)
#   "P|<session>|<pane_id>|<agent>|<status>|<is_last>" — agent pane (selectable)
ENTRIES=()
# Per-session pane counts: session → "working:done:wait" (only for multi-agent sessions)
declare -A PANE_COUNTS=()

# Parallel arrays for selectable items.
SEL_NAMES=()     # session name (for S/W) or "session:pane_id" (for P)
SEL_TYPES=()     # "S", "W", or "P"
SEL_COUNT=0

# (Agent tracking moved to lib/collect.sh, run by sidebar-collector.sh)

# Inline wait-input state.
WAIT_INPUT_ACTIVE=0
WAIT_INPUT_TARGET=""
WAIT_INPUT_BUF=""
CLOSE_CONFIRM_ACTIVE=0
CLOSE_CONFIRM_NAME=""
CLOSE_CONFIRM_TYPE=""
CLOSE_CONFIRM_PROMPT=""

# Spinner for working sessions (cycles each render).
SPINNER_FRAMES=('⣾' '⣽' '⣻' '⢿' '⡿' '⣟' '⣯' '⣷')
SPINNER_TICK=0

# Preview cache — only re-capture when selection or data changes.
_PREVIEW_SEL=""
_PREVIEW_LINES=()
_PREVIEW_DIRTY=1

_queue_spinner_target() {
    SPINNER_ROWS+=("$1")
    SPINNER_COLS+=("$2")
    SPINNER_BGS+=("${3:-none}")
    SPINNER_STYLES+=("${4:-row}")
}

animate_spinners() {
    (( _HAS_WORKING )) || return

    local frame="${SPINNER_FRAMES[$SPINNER_TICK]}"
    local buf=""
    local i row col bg style fg_seq

    for ((i=0; i<${#SPINNER_ROWS[@]}; i++)); do
        row="${SPINNER_ROWS[$i]}"
        col="${SPINNER_COLS[$i]}"
        bg="${SPINNER_BGS[$i]}"
        style="${SPINNER_STYLES[$i]}"

        fg_seq="$YEL"
        [[ "$style" == "header" ]] && fg_seq="$BYEL"

        case "$bg" in
            sel) buf+="\033[${row};${col}H${SEL_BG}${fg_seq}${frame}${RST}" ;;
            cur) buf+="\033[${row};${col}H${CUR_BG}${fg_seq}${frame}${RST}" ;;
            *)   buf+="\033[${row};${col}H${fg_seq}${frame}${RST}" ;;
        esac
    done

    [[ -n "$buf" ]] && printf '%b' "$buf"
    SPINNER_TICK=$(( (SPINNER_TICK + 1) % ${#SPINNER_FRAMES[@]} ))
}

# ─── ANSI helpers ─────────────────────────────────────────────────
RST=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
UND=$'\033[4m'
YEL=$'\033[33m'
GRN=$'\033[32m'
MAG=$'\033[35m'
CYN=$'\033[36m'
GRY=$'\033[90m'
WHT=$'\033[97m'
BYEL=$'\033[1;33m'
BGRN=$'\033[1;32m'
BMAG=$'\033[1;35m'
BCYN=$'\033[1;36m'
# Selection highlight: subtle background
SEL_BG=$'\033[48;5;236m'   # dark gray bg
CUR_BG=$'\033[48;5;235m'   # slightly darker for current session accent
ACC_GRN=$'\033[38;5;114m'  # soft green accent for current session bar

# ─── Fuzzy match ──────────────────────────────────────────────────
# Returns 0 if all chars in $1 appear in order in $2 (case-insensitive).
_fuzzy_match() {
    local q="${1,,}" t="${2,,}"
    local qi=0 ti=0 qlen=${#q} tlen=${#t}
    (( qlen == 0 )) && return 0
    while (( qi < qlen && ti < tlen )); do
        [[ "${q:$qi:1}" == "${t:$ti:1}" ]] && ((qi++))
        ((ti++))
    done
    (( qi == qlen ))
}

# ─── Data collection (reads cache from sidebar-collector.sh) ─────
_collect_cur_client() {
    local info
    info=$(tmux display-message -p $'#{client_session}\t#{pane_id}\t#{window_index}' 2>/dev/null || true)
    IFS=$'\t' read -r CUR_SESSION CUR_PANE CUR_WINDOW_INDEX <<< "$info"
}

_sync_selected_to_current_client() {
    local next_selected
    next_selected=$(sidebar_active_selection_index "$CUR_SESSION" "$CUR_PANE" "$CUR_WINDOW_INDEX") || return 1
    [[ -n "$next_selected" ]] || return 1

    if (( next_selected != SELECTED )); then
        SELECTED="$next_selected"
        return 0
    fi

    return 1
}

collect() {
    # Read from the shared cache written by sidebar-collector.sh.
    # Only re-parse when the cache file has been updated.
    local cache_file="$STATUS_DIR/.sidebar-cache"
    local cache_mtime
    if [[ "$(uname)" == "Darwin" ]]; then
        cache_mtime=$(stat -f %m "$cache_file" 2>/dev/null || echo 0)
    else
        cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)
    fi
    if [[ "$cache_mtime" == "$_LAST_STATUS_MTIME" ]]; then
        _collect_cur_client
        return
    fi
    _LAST_STATUS_MTIME="$cache_mtime"

    ENTRIES=()
    SEL_NAMES=()
    SEL_TYPES=()
    PANE_COUNTS=()
    SESS_START=0

    if [ ! -f "$cache_file" ]; then
        _collect_cur_client
        return
    fi

    while IFS= read -r line; do
        case "${line%%:*}" in
            TS) ;;
            SESS_START) SESS_START="${line#SESS_START:}" ;;
            PC)
                local rest="${line#PC:}"
                local pcname="${rest%%:*}"
                PANE_COUNTS[$pcname]="${rest#*:}"
                ;;
            E) ENTRIES+=("${line#E:}") ;;
            R)
                # "R:entry_data\tsel_name\tsel_type"
                local rdata="${line#R:}"
                local sel_type="${rdata##*	}"
                rdata="${rdata%	*}"
                local sel_name="${rdata##*	}"
                rdata="${rdata%	*}"
                ENTRIES+=("$rdata")
                SEL_NAMES+=("$sel_name")
                SEL_TYPES+=("$sel_type")
                ;;
        esac
    done < "$cache_file"

    SEL_COUNT=${#SEL_NAMES[@]}
    (( SEL_COUNT == 0 )) && SELECTED=0
    (( SELECTED >= SEL_COUNT )) && SELECTED=$((SEL_COUNT - 1))
    (( SELECTED < SESS_START )) && SELECTED=$SESS_START

    _collect_cur_client
}



# ─── Render ───────────────────────────────────────────────────────
render() {
    local W H
    read -r H W < <(stty size 2>/dev/null || echo "24 30")
    W=${W:-30}; H=${H:-24}

    # In preview mode, session list takes left portion; preview takes right.
    local LW=$W  # list width
    local preview_col=0 preview_width=0
    if (( PREVIEW_MODE )); then
        LW=$(( W * 35 / 100 ))
        (( LW < 25 )) && LW=25
        (( LW > W - 20 )) && LW=$((W - 20))
        preview_col=$((LW + 2))  # after separator
        preview_width=$((W - LW - 2))
    fi

    # Count by state for the header (per-pane when multi-agent)
    local nw=0 nd=0 nwt=0
    for e in "${ENTRIES[@]}"; do
        [[ "$e" != S\|* && "$e" != W\|* ]] && continue
        local rest="${e#?|}"
        local sname="${rest%%|*}"; rest="${rest#*|}"
        local st="${rest%%|*}"
        local counts="${PANE_COUNTS[$sname]:-}"
        if [[ -n "$counts" ]]; then
            IFS=: read -r _pw _pd _pwt <<< "$counts"
            ((nw += _pw)); ((nd += _pd)); ((nwt += _pwt))
        else
            case "$st" in
                working) ((nw++)) ;; done) ((nd++)) ;; wait) ((nwt++)) ;;
            esac
        fi
    done
    _HAS_WORKING=$(( nw > 0 ? 1 : 0 ))

    local cur_session="$CUR_SESSION"
    local cur_pane="$CUR_PANE"
    local cur_window_index="$CUR_WINDOW_INDEX"

    local line=0
    local buf=""
    SPINNER_ROWS=()
    SPINNER_COLS=()
    SPINNER_BGS=()
    SPINNER_STYLES=()

    # ── Header / Search bar ──
    if (( CLOSE_CONFIRM_ACTIVE )); then
        buf+=" ${BOLD}x${RST} ${CLOSE_CONFIRM_PROMPT}${DIM} [Enter confirm, Esc cancel]${RST}\033[K\n"
    elif (( SEARCH_ACTIVE )); then
        buf+=" ${BOLD}/${RST}${SEARCH_QUERY}${DIM}▏${RST}\033[K\n"
    else
        buf+=" "
        (( nw > 0 ))  && buf+="${BYEL}${SPINNER_FRAMES[$SPINNER_TICK]}${nw}${RST} "
        (( nd > 0 ))  && buf+="${BGRN}✓${nd}${RST} "
        (( nwt > 0 )) && buf+="${BCYN}⏸${nwt}${RST} "
        (( nw + nd + nwt == 0 )) && buf+="${DIM}no agents${RST}"
        buf+="\033[K\n"
        (( nw > 0 )) && _queue_spinner_target 1 2 "none" "header"
    fi
    ((line++))

    local sep="${DIM}"
    local i; for ((i=0; i<LW; i++)); do sep+="─"; done
    sep+="${RST}\033[K\n"
    buf+="$sep"
    ((line++))

    # ── Build render list (with search filtering) ──
    local render_lines=()
    local render_types=()
    local render_sel_indices=()

    local first_group=1
    local sel_idx=0
    local pending_group=""  # defer group header until we know it has visible children
    local pending_blank=0
    local group_has_items=0

    for entry in "${ENTRIES[@]}"; do
        local etype="${entry%%|*}"

        if [[ "$etype" == "G" ]]; then
            # Flush pending group if it had items
            # Save this group header for later (only emit if it has visible entries)
            pending_group="$entry"
            pending_blank=$((first_group == 0 ? 1 : 0))
            first_group=0
            group_has_items=0
            continue
        fi

        # Search filter: check if this item matches
        if (( SEARCH_ACTIVE )) && [[ -n "$SEARCH_QUERY" ]]; then
            local match_name=""
            case "$etype" in
                S|W) local r="${entry#?|}"; match_name="${r%%|*}" ;;
                P|Q) local r="${entry#?|}"; match_name="${r%%|*}"; r="${r#*|}"; r="${r#*|}"; match_name+=" ${r%%|*}" ;;
                I) local r="${entry#I|}"; r="${r#*|}"; r="${r#*|}"; match_name="${r%%|*}" ;;
            esac
            if ! _fuzzy_match "$SEARCH_QUERY" "$match_name"; then
                ((sel_idx++))
                continue
            fi
        fi

        # Emit deferred group header if this is the first visible item in group
        if (( group_has_items == 0 )) && [[ -n "$pending_group" ]]; then
            if (( pending_blank )); then
                render_lines+=("")
                render_types+=("B")
                render_sel_indices+=("-1")
            fi
            local rest="${pending_group#G|}"
            local label="${rest%%|*}"
            local color="${rest#*|}"
            # Map color names from cache to ANSI codes
            case "$color" in
                green|gray) color="$DIM" ;;
                yellow) color="$BYEL" ;; cyan) color="$BCYN" ;;
                magenta) color="$BMAG" ;; *) ;;
            esac
            render_lines+=("${color} ${label}${RST}")
            render_types+=("G")
            render_sel_indices+=("-1")
            pending_group=""
            group_has_items=1
        fi

        render_lines+=("$entry")
        render_types+=("$etype")
        render_sel_indices+=("$sel_idx")
        ((sel_idx++))
    done

    local total_render=${#render_lines[@]}

    # Ensure selected item is visible (scrolling)
    local sel_render_idx=-1
    for ((i=0; i<total_render; i++)); do
        local rt="${render_types[$i]}"
        if [[ "$rt" == "S" || "$rt" == "W" || "$rt" == "P" || "$rt" == "Q" || "$rt" == "I" ]] \
            && (( ${render_sel_indices[$i]} == SELECTED )); then
            sel_render_idx=$i
            break
        fi
    done

    local avail=$((H - line - 2))  # footer takes 2 lines
    if (( sel_render_idx >= 0 )); then
        if (( sel_render_idx < SCROLL_OFFSET )); then
            SCROLL_OFFSET=$sel_render_idx
        elif (( sel_render_idx >= SCROLL_OFFSET + avail )); then
            SCROLL_OFFSET=$((sel_render_idx - avail + 1))
        fi
    fi
    (( SCROLL_OFFSET < 0 )) && SCROLL_OFFSET=0

    # ── Render visible lines ──
    # Pre-scan: find sessions whose active pane matches a P/Q child entry,
    # so the parent S/W entry can suppress ACTIVE in favour of the child.
    local -A _active_pane_in_child=()
    if [[ -n "$cur_pane" ]]; then
        for ((i=0; i<${#render_lines[@]}; i++)); do
            local entry="${render_lines[$i]}"
            local sidx="${render_sel_indices[$i]}"
            case "${entry%%|*}" in
                P|Q)
                    local _r="${entry#?|}"
                    local _s="${_r%%|*}"; _r="${_r#*|}"
                    local _p="${_r%%|*}"
                    local _sel_name="${SEL_NAMES[$sidx]:-}"
                    local _sel_type="${SEL_TYPES[$sidx]:-}"
                    local _sel_token=""
                    if (( sidx >= 0 )) && [[ "$_sel_type" == "P" ]]; then
                        _sel_token="${_sel_name#*:}"
                    fi
                    if [[ "$_sel_token" == w* ]]; then
                        [[ "$_s" == "$cur_session" && "${_sel_token#w}" == "$cur_window_index" ]] && _active_pane_in_child[$_s]=1
                    else
                        [[ "$_p" == "$cur_pane" ]] && _active_pane_in_child[$_s]=1
                    fi
                    ;;
            esac
        done
    fi

    SCREEN_SEL=()

    local viewport_end=$((H - 2))
    for ((i=SCROLL_OFFSET; i<total_render && line<viewport_end; i++)); do
        local rtype="${render_types[$i]}"
        local sidx="${render_sel_indices[$i]}"

        if [[ "$rtype" == "B" ]]; then
            buf+="\033[K\n"; ((line++)); continue
        fi
        if [[ "$rtype" == "G" ]]; then
            buf+="${render_lines[$i]}\033[K\n"; ((line++)); continue
        fi

        # Map this screen row (1-based) to selectable index for mouse clicks.
        SCREEN_SEL[$((line + 1))]=$sidx

        local entry="${render_lines[$i]}"
        local is_sel=0 is_cur=0
        (( sidx >= 0 && sidx == SELECTED )) && is_sel=1

        # Inline icon/color lookup (no subshells)
        _set_icon_color() {
            case "$1" in
                working) _ic="$YEL"; _icon="${SPINNER_FRAMES[$SPINNER_TICK]}" ;;
                done)    _ic="$GRN"; _icon="✓" ;;
                wait)    _ic="$CYN"; _icon="⏸" ;;
                parked)  _ic="$GRY"; _icon="P" ;;
                *)       _ic="$GRY"; _icon="·" ;;
            esac
        }

        # Build compact multi-status string from pane counts "w:d:wt"
        _render_counts() {
            IFS=: read -r _cw _cd _cwt <<< "$1"
            _count_str="" ; _count_vlen=0
            if (( _cw > 0 )); then
                _count_str+="${YEL}${SPINNER_FRAMES[$SPINNER_TICK]}${_cw}${RST}"
                ((_count_vlen += ${#_cw} + 1))
            fi
            if (( _cd > 0 )); then
                (( _count_vlen > 0 )) && { _count_str+=" "; ((_count_vlen++)); }
                _count_str+="${GRN}✓${_cd}${RST}"
                ((_count_vlen += ${#_cd} + 1))
            fi
            if (( _cwt > 0 )); then
                (( _count_vlen > 0 )) && { _count_str+=" "; ((_count_vlen++)); }
                _count_str+="${CYN}⏸${_cwt}${RST}"
                ((_count_vlen += ${#_cwt} + 1))
            fi
        }

        if [[ "$rtype" == "S" ]]; then
            local rest="${entry#S|}"
            local name="${rest%%|*}"; rest="${rest#*|}"
            local state="${rest%%|*}"; rest="${rest#*|}"
            local extra="${rest%%|*}"; rest="${rest#*|}"
            local ssh="$rest"
            [[ "$name" == "$cur_session" && -z "${_active_pane_in_child[$name]:-}" ]] && is_cur=1
            local _spinner_bg="none"
            (( is_sel )) && _spinner_bg="sel"
            (( ! is_sel && is_cur )) && _spinner_bg="cur"

            # Build status indicator: compact counts or single icon
            local icon_str icon_vlen
            local counts="${PANE_COUNTS[$name]:-}"
            local has_working_spinner=0
            if [[ -n "$counts" ]]; then
                _render_counts "$counts"
                icon_str="$_count_str"; icon_vlen=$_count_vlen
                IFS=: read -r _cw _cd _cwt <<< "$counts"
                (( _cw > 0 )) && has_working_spinner=1
            else
                local _icon _ic; _set_icon_color "$state"
                icon_str="${_ic}${_icon}${RST}"; icon_vlen=1
                [[ "$state" == "working" ]] && has_working_spinner=1
            fi

            local suffix=""
            [[ -n "$extra" ]] && suffix=" (${extra})"
            [[ -n "$ssh" ]] && suffix+=" [ssh]"
            local active_tag=""
            (( is_cur )) && active_tag=" ${DIM}ACTIVE${RST}"
            local tag_vlen=0
            (( is_cur )) && tag_vlen=7

            local max_n=$((LW - 5 - icon_vlen - ${#suffix} - tag_vlen))
            (( max_n < 4 )) && max_n=4
            local dname="$name"
            (( ${#dname} > max_n )) && dname="${dname:0:$((max_n-1))}…"

            local vlen=$(( ${#dname} + ${#suffix} + tag_vlen ))
            local pad

            if (( is_sel )); then
                pad=$((LW - vlen - 4 - icon_vlen))
                (( pad < 0 )) && pad=0
                (( has_working_spinner )) && _queue_spinner_target "$((line + 1))" "$((3 + vlen + pad + 1))" "$_spinner_bg"
                buf+="${SEL_BG} ${BOLD}▸ ${RST}${SEL_BG}${dname}${suffix}${active_tag}${SEL_BG}"
                buf+="$(printf '%*s' "$pad" '')${icon_str}\033[K\n"
            elif (( is_cur )); then
                pad=$((LW - vlen - 4 - icon_vlen))
                (( pad < 0 )) && pad=0
                (( has_working_spinner )) && _queue_spinner_target "$((line + 1))" "$((3 + vlen + pad + 1))" "$_spinner_bg"
                buf+="${CUR_BG} ${ACC_GRN}▌${RST}${CUR_BG} ${dname}${suffix}${active_tag}${CUR_BG}"
                buf+="$(printf '%*s' "$pad" '')${icon_str}\033[K\n"
            else
                pad=$((LW - vlen - 3 - icon_vlen))
                (( pad < 0 )) && pad=0
                (( has_working_spinner )) && _queue_spinner_target "$((line + 1))" "$((2 + vlen + pad + 1))" "$_spinner_bg"
                buf+="  ${dname}${suffix}"
                buf+="$(printf '%*s' "$pad" '')${icon_str}\033[K\n"
            fi

        elif [[ "$rtype" == "W" ]]; then
            local rest="${entry#W|}"
            local name="${rest%%|*}"; rest="${rest#*|}"
            local state="${rest%%|*}"; rest="${rest#*|}"
            local extra="${rest%%|*}"; rest="${rest#*|}"
            local ssh="${rest%%|*}"; rest="${rest#*|}"
            local is_last="$rest"
            [[ "$name" == "$cur_session" && -z "${_active_pane_in_child[$name]:-}" ]] && is_cur=1
            local _spinner_bg="none"
            (( is_sel )) && _spinner_bg="sel"
            (( ! is_sel && is_cur )) && _spinner_bg="cur"

            # Build status indicator: compact counts or single icon
            local icon_str icon_vlen
            local counts="${PANE_COUNTS[$name]:-}"
            local has_working_spinner=0
            if [[ -n "$counts" ]]; then
                _render_counts "$counts"
                icon_str="$_count_str"; icon_vlen=$_count_vlen
                IFS=: read -r _cw _cd _cwt <<< "$counts"
                (( _cw > 0 )) && has_working_spinner=1
            else
                local _icon _ic; _set_icon_color "$state"
                icon_str="${_ic}${_icon}${RST}"; icon_vlen=1
                [[ "$state" == "working" ]] && has_working_spinner=1
            fi

            local tree="├"; [[ "$is_last" == "1" ]] && tree="└"

            local suffix=""
            [[ -n "$extra" ]] && suffix=" (${extra})"
            local active_tag=""
            local tag_vlen=0
            (( is_cur )) && { active_tag=" ${DIM}ACTIVE${RST}"; tag_vlen=7; }

            local max_n=$((LW - 9 - icon_vlen - ${#suffix} - tag_vlen))
            (( max_n < 4 )) && max_n=4
            local dname="$name"
            (( ${#dname} > max_n )) && dname="${dname:0:$((max_n-1))}…"

            local vlen=$(( ${#dname} + ${#suffix} + tag_vlen ))
            local pad

            if (( is_sel )); then
                pad=$((LW - vlen - 8 - icon_vlen))
                (( pad < 0 )) && pad=0
                (( has_working_spinner )) && _queue_spinner_target "$((line + 1))" "$((7 + vlen + pad + 1))" "$_spinner_bg"
                buf+="${SEL_BG}   ${BOLD}▸${RST}${SEL_BG} ${DIM}${tree}${RST}${SEL_BG} ${dname}${suffix}${active_tag}${SEL_BG}"
                buf+="$(printf '%*s' "$pad" '')${icon_str}\033[K\n"
            elif (( is_cur )); then
                pad=$((LW - vlen - 8 - icon_vlen))
                (( pad < 0 )) && pad=0
                (( has_working_spinner )) && _queue_spinner_target "$((line + 1))" "$((7 + vlen + pad + 1))" "$_spinner_bg"
                buf+="${CUR_BG}   ${ACC_GRN}▌${RST}${CUR_BG} ${DIM}${tree}${RST}${CUR_BG} ${dname}${suffix}${active_tag}${CUR_BG}"
                buf+="$(printf '%*s' "$pad" '')${icon_str}\033[K\n"
            else
                pad=$((LW - vlen - 7 - icon_vlen))
                (( pad < 0 )) && pad=0
                (( has_working_spinner )) && _queue_spinner_target "$((line + 1))" "$((6 + vlen + pad + 1))" "$_spinner_bg"
                buf+="    ${DIM}${tree}${RST} ${dname}${suffix}"
                buf+="$(printf '%*s' "$pad" '')${icon_str}\033[K\n"
            fi

        elif [[ "$rtype" == "I" ]]; then
            # Inbox item: I|session|token|label|status
            local rest="${entry#I|}"
            local sess="${rest%%|*}"; rest="${rest#*|}"
            local token="${rest%%|*}"; rest="${rest#*|}"
            local label="${rest%%|*}"; rest="${rest#*|}"
            local istatus="$rest"
            if [[ -n "$token" ]]; then
                if [[ "$token" == w* ]]; then
                    [[ "$sess" == "$cur_session" && "${token#w}" == "$cur_window_index" ]] && is_cur=1
                else
                    [[ "$sess" == "$cur_session" && "$token" == "$cur_pane" ]] && is_cur=1
                fi
            else
                [[ "$sess" == "$cur_session" ]] && is_cur=1
            fi
            # Mirror selection from SESSIONS section using the row's actual scope token.
            local sel_name="${SEL_NAMES[$SELECTED]:-}"
            local sel_type="${SEL_TYPES[$SELECTED]:-}"
            if [[ "$sel_type" == "P" ]]; then
                local sel_sess="${sel_name%%:*}" sel_token="${sel_name#*:}"
                if [[ -n "$token" ]]; then
                    [[ "$sess" == "$sel_sess" && "$token" == "$sel_token" ]] && is_sel=1
                else
                    [[ "$sess" == "$sel_sess" ]] && is_sel=1
                fi
            else
                # Selected a session — highlight session-level inbox entry only
                [[ -z "$pane_id" && "$sess" == "$sel_name" ]] && is_sel=1
            fi

            local _icon _ic; _set_icon_color "$istatus"

            local active_tag=""
            local tag_vlen=0
            (( is_cur )) && { active_tag=" ${DIM}ACTIVE${RST}"; tag_vlen=7; }

            local max_n=$((LW - 6 - tag_vlen))
            (( max_n < 4 )) && max_n=4
            local dlabel="$label"
            (( ${#dlabel} > max_n )) && dlabel="${dlabel:0:$((max_n-1))}…"

            local vlen=$(( ${#dlabel} + tag_vlen ))
            local pad

            if (( is_sel )); then
                pad=$((LW - vlen - 5))
                (( pad < 0 )) && pad=0
                buf+="${SEL_BG} ${BOLD}▸ ${RST}${SEL_BG}${dlabel}${active_tag}${SEL_BG}"
                buf+="$(printf '%*s' "$pad" '')${_ic}${_icon}${RST}\033[K\n"
            elif (( is_cur )); then
                pad=$((LW - vlen - 5))
                (( pad < 0 )) && pad=0
                buf+="${CUR_BG} ${ACC_GRN}▌${RST}${CUR_BG} ${dlabel}${active_tag}${CUR_BG}"
                buf+="$(printf '%*s' "$pad" '')${_ic}${_icon}${RST}\033[K\n"
            else
                pad=$((LW - vlen - 4))
                (( pad < 0 )) && pad=0
                buf+="  ${dlabel}"
                buf+="$(printf '%*s' "$pad" '')${_ic}${_icon}${RST}\033[K\n"
            fi

        elif [[ "$rtype" == "P" ]]; then
            local rest="${entry#P|}"
            local sess="${rest%%|*}"; rest="${rest#*|}"
            local pane_id="${rest%%|*}"; rest="${rest#*|}"
            local agent="${rest%%|*}"; rest="${rest#*|}"
            local pstatus="${rest%%|*}"; rest="${rest#*|}"
            local is_last="$rest"
            local sel_name="${SEL_NAMES[$sidx]:-}"
            local sel_type="${SEL_TYPES[$sidx]:-}"
            if [[ "$sel_type" == "P" && "$sel_name" == *:w* ]]; then
                local sel_sess="${sel_name%%:*}" sel_token="${sel_name#*:}"
                [[ "$sess" == "$sel_sess" && "$sess" == "$cur_session" && "${sel_token#w}" == "$cur_window_index" ]] && is_cur=1
            else
                [[ "$sess" == "$cur_session" && "$pane_id" == "$cur_pane" ]] && is_cur=1
            fi

            local _icon _ic; _set_icon_color "$pstatus"
            local tree="├"; [[ "$is_last" == "1" ]] && tree="└"
            local active_tag=""
            local tag_vlen=0
            (( is_cur )) && { active_tag=" ${DIM}ACTIVE${RST}"; tag_vlen=7; }

            local max_n=$((LW - 8 - tag_vlen))
            (( max_n < 4 )) && max_n=4
            local dagent="$agent"
            (( ${#dagent} > max_n )) && dagent="${dagent:0:$((max_n-1))}…"

            local vlen=$(( ${#dagent} + tag_vlen ))
            local pad
            local _spinner_bg="none"
            (( is_sel )) && _spinner_bg="sel"
            (( ! is_sel && is_cur )) && _spinner_bg="cur"

            if (( is_sel )); then
                pad=$((LW - vlen - 8))
                (( pad < 0 )) && pad=0
                [[ "$pstatus" == "working" ]] && _queue_spinner_target "$((line + 1))" "$((6 + vlen + pad + 1))" "$_spinner_bg"
                buf+="${SEL_BG}  ${BOLD}▸${RST}${SEL_BG} ${DIM}${tree}${RST}${SEL_BG} ${DIM}${dagent}${RST}${active_tag}${SEL_BG}"
                buf+="$(printf '%*s' "$pad" '')${_ic}${_icon}${RST}\033[K\n"
            elif (( is_cur )); then
                pad=$((LW - vlen - 8))
                (( pad < 0 )) && pad=0
                [[ "$pstatus" == "working" ]] && _queue_spinner_target "$((line + 1))" "$((6 + vlen + pad + 1))" "$_spinner_bg"
                buf+="${CUR_BG}  ${ACC_GRN}▌${RST}${CUR_BG} ${DIM}${tree}${RST}${CUR_BG} ${DIM}${dagent}${RST}${active_tag}${CUR_BG}"
                buf+="$(printf '%*s' "$pad" '')${_ic}${_icon}${RST}\033[K\n"
            else
                pad=$((LW - vlen - 8))
                (( pad < 0 )) && pad=0
                [[ "$pstatus" == "working" ]] && _queue_spinner_target "$((line + 1))" "$((6 + vlen + pad + 1))" "$_spinner_bg"
                buf+="    ${DIM}${tree} ${dagent}${RST}"
                buf+="$(printf '%*s' "$pad" '')${_ic}${_icon}${RST}\033[K\n"
            fi

        elif [[ "$rtype" == "Q" ]]; then
            local rest="${entry#Q|}"
            local sess="${rest%%|*}"; rest="${rest#*|}"
            local pane_id="${rest%%|*}"; rest="${rest#*|}"
            local agent="${rest%%|*}"; rest="${rest#*|}"
            local pstatus="${rest%%|*}"; rest="${rest#*|}"
            local is_last="${rest%%|*}"; rest="${rest#*|}"
            local parent_is_last="$rest"
            [[ "$sess" == "$cur_session" && "$pane_id" == "$cur_pane" ]] && is_cur=1

            local _icon _ic; _set_icon_color "$pstatus"
            local tree="├"; [[ "$is_last" == "1" ]] && tree="└"
            local vert="│"; [[ "$parent_is_last" == "1" ]] && vert=" "
            local active_tag=""
            local tag_vlen=0
            (( is_cur )) && { active_tag=" ${DIM}ACTIVE${RST}"; tag_vlen=7; }

            local max_n=$((LW - 10 - tag_vlen))
            (( max_n < 4 )) && max_n=4
            local dagent="$agent"
            (( ${#dagent} > max_n )) && dagent="${dagent:0:$((max_n-1))}…"

            local vlen=$(( ${#dagent} + tag_vlen ))
            local pad
            local _spinner_bg="none"
            (( is_sel )) && _spinner_bg="sel"
            (( ! is_sel && is_cur )) && _spinner_bg="cur"

            if (( is_sel )); then
                pad=$((LW - vlen - 10))
                (( pad < 0 )) && pad=0
                [[ "$pstatus" == "working" ]] && _queue_spinner_target "$((line + 1))" "$((8 + vlen + pad + 1))" "$_spinner_bg"
                buf+="${SEL_BG}  ${BOLD}▸${RST}${SEL_BG} ${DIM}${vert} ${tree}${RST}${SEL_BG} ${DIM}${dagent}${RST}${active_tag}${SEL_BG}"
                buf+="$(printf '%*s' "$pad" '')${_ic}${_icon}${RST}\033[K\n"
            elif (( is_cur )); then
                pad=$((LW - vlen - 10))
                (( pad < 0 )) && pad=0
                [[ "$pstatus" == "working" ]] && _queue_spinner_target "$((line + 1))" "$((8 + vlen + pad + 1))" "$_spinner_bg"
                buf+="${CUR_BG}  ${ACC_GRN}▌${RST}${CUR_BG} ${DIM}${vert} ${tree}${RST}${CUR_BG} ${DIM}${dagent}${RST}${active_tag}${CUR_BG}"
                buf+="$(printf '%*s' "$pad" '')${_ic}${_icon}${RST}\033[K\n"
            else
                pad=$((LW - vlen - 10))
                (( pad < 0 )) && pad=0
                [[ "$pstatus" == "working" ]] && _queue_spinner_target "$((line + 1))" "$((8 + vlen + pad + 1))" "$_spinner_bg"
                buf+="    ${DIM}${vert} ${tree} ${dagent}${RST}"
                buf+="$(printf '%*s' "$pad" '')${_ic}${_icon}${RST}\033[K\n"
            fi
        fi

        ((line++))
    done

    # Fill remaining space
    while (( line < viewport_end )); do
        buf+="\033[K\n"
        ((line++))
    done

    # ── Footer ──
    buf+="$sep"
    # A wrapped footer scrolls the frame and breaks mouse row mapping.
    # Prefer shorter hints, then leave a spare column when clamping.
    local ftxt fcol
    if (( WAIT_INPUT_ACTIVE )); then
        ftxt=" Wait minutes for ${WAIT_INPUT_TARGET}: ${WAIT_INPUT_BUF}"
        fcol="$BCYN"
    elif (( SEARCH_ACTIVE )); then
        ftxt=" type to filter  ⏎ select  esc cancel"
        (( ${#ftxt} >= LW )) && ftxt=" filter  ⏎ sel  esc cancel"
        fcol="$DIM"
    else
        ftxt=" ⏎ select  / search  w wait  p park  m mode  q quit"
        (( ${#ftxt} >= LW )) && ftxt=" ⏎ sel  / find  w wait  p park  q quit"
        (( ${#ftxt} >= LW )) && ftxt=" ⏎sel /find w-wait p-park q-quit"
        fcol="$DIM"
    fi
    (( LW > 1 && ${#ftxt} >= LW )) && ftxt="${ftxt:0:$((LW - 1))}"
    buf+="${fcol}${ftxt}${RST}\033[K"

    # Flush entire frame at once (no flicker)
    printf '\033[H%b' "$buf"

    # ── Preview panel (popup mode only) ──
    if (( PREVIEW_MODE && SEL_COUNT > 0 )); then
        local sel_session="${SEL_NAMES[$SELECTED]}"
        local sel_type="${SEL_TYPES[$SELECTED]}"
        [[ "$sel_type" == "P" ]] && sel_session="${sel_session%%:*}"

        # Only re-capture pane content when selection or data changed
        local sel_key="${sel_session}:${sel_type}"
        if [[ "$sel_key" != "$_PREVIEW_SEL" ]] || (( _PREVIEW_DIRTY )); then
            _PREVIEW_SEL="$sel_key"
            _PREVIEW_DIRTY=0
            _PREVIEW_LINES=()

            local pane_target="$sel_session"
            if [[ "$sel_type" == "P" ]]; then
                local pane_id="${SEL_NAMES[$SELECTED]#*:}"
                pane_target="$pane_id"
            fi

            while IFS= read -r pline; do
                _PREVIEW_LINES+=("$pline")
            done < <(tmux capture-pane -peJ -t "$pane_target" 2>/dev/null | tail -$((H - 4)))
        fi

        # Separator + preview title
        local pbuf=""
        local row
        for ((row=1; row<=H; row++)); do
            pbuf+="\033[${row};$((LW+1))H${DIM}│${RST}"
        done
        pbuf+="\033[1;${preview_col}H ${BOLD}${sel_session}${RST}\033[K"

        # Separator line under preview title
        pbuf+="\033[2;${preview_col}H${DIM}"
        for ((i=0; i<preview_width; i++)); do pbuf+="─"; done
        pbuf+="${RST}"

        # Render cached preview lines
        local prow=3
        local pi=0
        for ((pi=0; pi<${#_PREVIEW_LINES[@]} && prow<H-1; pi++)); do
            local ptext="${_PREVIEW_LINES[$pi]}"
            if (( ${#ptext} > preview_width )); then
                ptext="${ptext:0:$preview_width}"
            fi
            pbuf+="\033[${prow};${preview_col}H${ptext}\033[K"
            ((prow++))
        done
        for (( ; prow<H-1; prow++ )); do
            pbuf+="\033[${prow};${preview_col}H\033[K"
        done

        printf '%b' "$pbuf"
    fi

    # Advance spinner
    SPINNER_TICK=$(( (SPINNER_TICK + 1) % ${#SPINNER_FRAMES[@]} ))
}

# ─── Actions ──────────────────────────────────────────────────────
action_switch() {
    (( SEL_COUNT == 0 )) && return
    local target="${SEL_NAMES[$SELECTED]}"
    local ttype="${SEL_TYPES[$SELECTED]}"
    [[ -z "$target" ]] && return

    selection_switch_client "$target" "$ttype"

    if (( PREVIEW_MODE )); then
        # Popup mode: close on select.
        exit 0
    fi
    # Sidebar mode: keep running. The new session has its own sidebar.
    NEEDS_COLLECT=1
}

dispatch_close_job() {
    local sel_name="$1"
    local sel_type="$2"
    local close_cmd=""

    printf -v close_cmd '%q ' "$CURRENT_DIR/close-target.sh" "$sel_name" "$sel_type"
    tmux run-shell -b "$close_cmd"
}

action_close() {
    (( SEL_COUNT == 0 )) && return

    local sel_name="${SEL_NAMES[$SELECTED]}"
    local sel_type="${SEL_TYPES[$SELECTED]}"
    [[ -z "$sel_name" ]] && return

    if selection_requires_confirmation "$sel_name" "$sel_type"; then
        CLOSE_CONFIRM_ACTIVE=1
        CLOSE_CONFIRM_NAME="$sel_name"
        CLOSE_CONFIRM_TYPE="$sel_type"
        CLOSE_CONFIRM_PROMPT="$(selection_close_prompt "$sel_name" "$sel_type")"
        return
    fi

    dispatch_close_job "$sel_name" "$sel_type"
    _LAST_STATUS_MTIME=""
    NEEDS_COLLECT=1
}

# Get the session name for the currently selected item (works for S, W, and P).
_selected_session() {
    local target="${SEL_NAMES[$SELECTED]}"
    local ttype="${SEL_TYPES[$SELECTED]}"
    if [[ "$ttype" == "P" ]]; then
        echo "${target%%:*}"
    else
        echo "$target"
    fi
}

# Get the state of the selected entry by scanning ENTRIES.
_selected_state() {
    local sidx=0
    for e in "${ENTRIES[@]}"; do
        case "${e%%|*}" in
            S|W)
                if (( sidx == SELECTED )); then
                    local rest="${e#?|}" ; rest="${rest#*|}"
                    echo "${rest%%|*}"
                    return
                fi
                ((sidx++))
                ;;
            P|Q)
                if (( sidx == SELECTED )); then
                    # Return the actual pane/window status, not a generic tag
                    local rest="${e#?|}" ; rest="${rest#*|}"
                    rest="${rest#*|}" ; rest="${rest#*|}" ; rest="${rest#*|}"
                    echo "${rest%%|*}"
                    return
                fi
                ((sidx++))
                ;;
            I)
                if (( sidx == SELECTED )); then
                    local rest="${e#I|}"
                    rest="${rest#*|}"
                    rest="${rest#*|}"
                    rest="${rest#*|}"
                    echo "$rest"
                    return
                fi
                ((sidx++))
                ;;
            *) ;;
        esac
    done
}

action_wait() {
    (( SEL_COUNT == 0 )) && return
    local raw_target="${SEL_NAMES[$SELECTED]}"
    local ttype="${SEL_TYPES[$SELECTED]}"
    local state
    state=$(_selected_state)

    # Toggle: if already waiting, cancel wait
    if [[ "$state" == "wait" ]]; then
        if [[ "$ttype" == "P" ]]; then
            local session="${raw_target%%:*}"
            local pane_id="${raw_target#*:}"

            if [[ "$pane_id" == w* ]]; then
                # Window-level cancel
                local win_idx="${pane_id#w}"
                while IFS= read -r wp_id; do
                    [ -z "$wp_id" ] && continue
                    rm -f "$WAIT_DIR/${session}_${wp_id}.wait"
                    local pf="$STATUS_DIR/panes/${session}_${wp_id}.status"
                    [ -f "$pf" ] && [ "$(cat "$pf")" = "wait" ] && echo "done" > "$pf"
                done < <(tmux list-panes -t "${session}:${win_idx}" -F '#{pane_id}' 2>/dev/null)
            else
                # Pane-level cancel
                rm -f "$WAIT_DIR/${session}_${pane_id}.wait"
                echo "done" > "$STATUS_DIR/panes/${session}_${pane_id}.status" 2>/dev/null
            fi
            # Clear session-level wait if no pane waits remain
            sync_session_after_child_scope_change "$session"
        else
            # Session-level cancel
            local session="$raw_target"
            rm -f "$WAIT_DIR/${session}.wait"
            rm -f "$WAIT_DIR/${session}_"*.wait 2>/dev/null
            if [ -f "$STATUS_DIR/${session}-remote.status" ]; then
                echo "done" > "$STATUS_DIR/${session}-remote.status"
            else
                echo "done" > "$STATUS_DIR/${session}.status"
            fi
            for pf in "$STATUS_DIR/panes/${session}_"*.status; do
                [ -f "$pf" ] && [ "$(cat "$pf")" = "wait" ] && echo "done" > "$pf"
            done
        fi
        _LAST_STATUS_MTIME=""
        return
    fi

    # Inline prompt: read minutes directly in the sidebar.
    # Pass the full target (session or session:pane_id) so the handler
    # knows whether to wait at session or pane level.
    WAIT_INPUT_ACTIVE=1
    if [[ "$ttype" == "P" ]]; then
        WAIT_INPUT_TARGET="$raw_target"
    else
        WAIT_INPUT_TARGET="$(_selected_session)"
    fi
    WAIT_INPUT_BUF=""
}

action_park() {
    (( SEL_COUNT == 0 )) && return
    local target="${SEL_NAMES[$SELECTED]}"
    local ttype="${SEL_TYPES[$SELECTED]}"
    bash "$CURRENT_DIR/park-target.sh" "$target" "$ttype"
    _LAST_STATUS_MTIME=""
}

# ─── Main loop ────────────────────────────────────────────────────
NEEDS_COLLECT=1
NEEDS_RENDER=1
ANIMATE_TICK=0
_LAST_LIVENESS_TS=0

while true; do
    # Exit if our pane/TTY is gone (prevents orphaned processes).
    [[ ! -t 0 ]] && exit 0

    # tmux does not reliably HUP pane processes when a pane is destroyed
    # (and a dead pty never returns EOF on macOS — reads just keep timing
    # out), so poll our own liveness: pane mode checks the pane still
    # exists, preview mode checks we haven't been orphaned to PID 1.
    printf -v _now_ts '%(%s)T' -1
    if (( _now_ts - _LAST_LIVENESS_TS >= 5 )); then
        _LAST_LIVENESS_TS=$_now_ts
        if [ -n "${SELF_PANE:-}" ]; then
            # list-panes + grep, not display-message: display-message still
            # "resolves" recently destroyed pane ids.
            tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qFx "$SELF_PANE" || exit 0
        elif [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" = "1" ]; then
            exit 0
        fi
    fi

    if (( NEEDS_COLLECT )); then
        prev_cache_mtime="$_LAST_STATUS_MTIME"
        prev_cur="${CUR_SESSION}|${CUR_PANE}|${CUR_WINDOW_INDEX}"
        collect
        cur_token="${CUR_SESSION}|${CUR_PANE}|${CUR_WINDOW_INDEX}"
        if [[ "$_LAST_STATUS_MTIME" != "$prev_cache_mtime" ]]; then
            NEEDS_RENDER=1
            _PREVIEW_DIRTY=1
        fi
        if [[ "$cur_token" != "$prev_cur" ]]; then
            _sync_selected_to_current_client || true
            NEEDS_RENDER=1
        fi
    fi
    NEEDS_COLLECT=0
    if (( RESIZED )); then
        NEEDS_RENDER=1
        _PREVIEW_DIRTY=1
        RESIZED=0
    fi
    if (( NEEDS_RENDER )); then
        render
        NEEDS_RENDER=0
        ANIMATE_TICK=0
    elif (( ANIMATE_TICK )); then
        animate_spinners
        ANIMATE_TICK=0
    fi
    (( NEEDS_COLLECT )) && _COLLECT_TICK=0

    # Refresh signals interrupt read; idle polling only covers missed signals.
    local_read_timeout=30
    (( _HAS_WORKING )) && local_read_timeout=0.25

    (( _COLLECT_TICK++ ))
    local_poll_ticks=1
    (( _HAS_WORKING )) && local_poll_ticks=4
    if (( _COLLECT_TICK >= local_poll_ticks )); then
        NEEDS_COLLECT=1
        _COLLECT_TICK=0
    fi
    (( _HAS_WORKING )) && ANIMATE_TICK=1

    if read -rsn1 -t "$local_read_timeout" key; then
        NEEDS_RENDER=1
        # Handle escape sequences (arrows, mouse) shared by both modes.
        _handle_escape() {
            local seq="" part=""
            read -rsn1 -t 0.1 seq
            if [[ "$seq" == '[' ]]; then
                # Consume the full CSI sequence, including modifier parameters.
                while read -rsn1 -t 0.1 part; do
                    seq+="$part"
                    [[ "$seq" == '[<' || "$part" == [@-~] ]] && break
                done
            elif [[ "$seq" == O ]]; then
                read -rsn1 -t 0.1 part
                seq+="$part"
            fi
            case "$seq" in
                '[A') (( SELECTED > SESS_START )) && ((SELECTED--)); return 0 ;;
                '[B') (( SELECTED < SEL_COUNT - 1 )) && ((SELECTED++)); return 0 ;;
                '[<')
                    # SGR mouse: read "button;x;yM" or "button;x;ym"
                    local mdata="" mc=""
                    while read -rsn1 -t 0.1 mc; do
                        [[ "$mc" == "M" || "$mc" == "m" ]] && break
                        mdata+="$mc"
                    done
                    if [[ "$mc" == "M" ]]; then  # press only
                        local mb mx my
                        IFS=';' read -r mb mx my <<< "$mdata"
                        if (( mb == 64 )); then
                            # Scroll up
                            (( SELECTED > SESS_START )) && ((SELECTED--))
                        elif (( mb == 65 )); then
                            # Scroll down
                            (( SELECTED < SEL_COUNT - 1 )) && ((SELECTED++))
                        elif (( mb == 0 )); then
                            # Left click — select + switch
                            local clicked="${SCREEN_SEL[$my]:-}"
                            if [[ -n "$clicked" ]] && (( clicked >= 0 && clicked < SEL_COUNT )); then
                                SELECTED=$clicked
                                action_switch
                            fi
                        fi
                    fi
                    return 0
                    ;;
                '[C')
                    # Move focus from the left sidebar to the adjacent pane.
                    tmux select-pane -t "$SELF_PANE" -R >/dev/null 2>&1
                    return 0
                    ;;
            esac

            # Swallow unknown key sequences; only bare Escape dismisses.
            [ -n "$seq" ] && return 0
            return 1  # unhandled (bare Escape)
        }

        if (( WAIT_INPUT_ACTIVE )); then
            # Wait-input mode: accept digits, Enter to confirm, Esc to cancel
            case "$key" in
                $'\x1b')
                    WAIT_INPUT_ACTIVE=0; WAIT_INPUT_BUF="" ;;
                $'\x7f'|$'\b')
                    WAIT_INPUT_BUF="${WAIT_INPUT_BUF%?}"
                    [[ -z "$WAIT_INPUT_BUF" ]] && { WAIT_INPUT_ACTIVE=0; WAIT_INPUT_BUF=""; } ;;
                '')  # Enter — confirm
                    if [[ -n "$WAIT_INPUT_BUF" ]] && [[ "$WAIT_INPUT_BUF" =~ ^[0-9]+$ ]] && (( WAIT_INPUT_BUF > 0 )); then
                        bash "$CURRENT_DIR/wait-session-handler.sh" "$WAIT_INPUT_TARGET" "$WAIT_INPUT_BUF"
                        NEEDS_COLLECT=1
                        _LAST_STATUS_MTIME=""
                    fi
                    WAIT_INPUT_ACTIVE=0; WAIT_INPUT_BUF="" ;;
                [0-9])
                    WAIT_INPUT_BUF+="$key" ;;
            esac
        elif (( CLOSE_CONFIRM_ACTIVE )); then
            case "$key" in
                $'\x1b'|q)
                    CLOSE_CONFIRM_ACTIVE=0
                    CLOSE_CONFIRM_NAME=""
                    CLOSE_CONFIRM_TYPE=""
                    CLOSE_CONFIRM_PROMPT=""
                    ;;
                '')
                    dispatch_close_job "$CLOSE_CONFIRM_NAME" "$CLOSE_CONFIRM_TYPE"
                    CLOSE_CONFIRM_ACTIVE=0
                    CLOSE_CONFIRM_NAME=""
                    CLOSE_CONFIRM_TYPE=""
                    CLOSE_CONFIRM_PROMPT=""
                    NEEDS_COLLECT=1
                    _LAST_STATUS_MTIME=""
                    ;;
            esac
        elif (( SEARCH_ACTIVE )); then
            # Search mode input handling
            case "$key" in
                $'\x1b')
                    if ! _handle_escape; then
                        # Plain Escape — cancel search
                        SEARCH_QUERY=""
                        SEARCH_ACTIVE=0
                        SELECTED=0
                    fi
                    ;;
                $'\x7f'|$'\b')  # Backspace
                    if [[ -n "$SEARCH_QUERY" ]]; then
                        SEARCH_QUERY="${SEARCH_QUERY%?}"
                        SELECTED=0
                    else
                        SEARCH_ACTIVE=0
                    fi
                    ;;
                '')  # Enter — select current match and exit search
                    SEARCH_ACTIVE=0
                    action_switch
                    ;;
                j|k)
                    # Allow navigation even in search mode via ctrl sequences
                    [[ "$key" == "j" ]] && (( SELECTED < SEL_COUNT - 1 )) && ((SELECTED++))
                    [[ "$key" == "k" ]] && (( SELECTED > SESS_START )) && ((SELECTED--))
                    ;;
                [[:print:]])
                    SEARCH_QUERY+="$key"
                    SELECTED=0
                    ;;
            esac
        else
            # Normal mode input handling
            case "$key" in
                j)  (( SELECTED < SEL_COUNT - 1 )) && ((SELECTED++)) ;;
                k)  (( SELECTED > SESS_START )) && ((SELECTED--)) ;;
                $'\x1b')
                    if ! _handle_escape; then
                        exit 0
                    fi
                    ;;
                '')  action_switch ;;
                w)   action_wait; NEEDS_COLLECT=1 ;;
                p)   action_park; NEEDS_COLLECT=1 ;;
                m)   "$CURRENT_DIR/sidebar-toggle-mode.sh" >/dev/null 2>&1
                     NEEDS_COLLECT=1
                     ;;
                x)   action_close ;;
                r)   "$CURRENT_DIR/hook-based-switcher.sh" --reset >/dev/null 2>&1
                     KNOWN_AGENTS=()
                     NEEDS_COLLECT=1
                     ;;
                /)   SEARCH_ACTIVE=1; SEARCH_QUERY="" ;;
                q)   exit 0 ;;
            esac
        fi
    else
        # Timeouts and trap interruptions return >128; anything else is
        # EOF from a dead pty — exit instead of busy-looping on it.
        read_rc=$?
        (( read_rc > 128 )) || exit 0
    fi
done
