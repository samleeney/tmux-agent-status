#!/usr/bin/env bash

# Shared data collection logic for the sidebar.
# Sourced by sidebar-collector.sh (daemon) and optionally sidebar.sh (fallback).
#
# Requires the caller to:
#   - source lib/session-status.sh (for STATUS_DIR, PARKED_DIR, WAIT_DIR)
#   - declare global: ENTRIES, SEL_NAMES, SEL_TYPES, PANE_COUNTS (associative),
#     KNOWN_AGENTS (associative), LIVE_PANES (associative), PID_PPID (associative),
#     SESS_START, _COLLECT_TICK, _LAST_STATUS_MTIME
#
# Populates: ENTRIES[], SEL_NAMES[], SEL_TYPES[], PANE_COUNTS[], SESS_START,
#            SUMMARY_WORKING, SUMMARY_WAITING, SUMMARY_DONE, SUMMARY_TOTAL,
#            SUMMARY_HAS_WORKING, SUMMARY_AGENTS[]
# Persists across calls: LIVE_PANES[]
# Sets _COLLECT_CHANGED=1 when data was rebuilt, 0 when skipped (no changes).

[[ -n "${_COLLECT_LIB_LOADED:-}" ]] && return 0
_COLLECT_LIB_LOADED=1

# shellcheck source=completion-inbox.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/completion-inbox.sh"

# ─── PID ancestry helpers ─────────────────────────────────────────

_build_pid_map() {
    PID_PPID=()
    while read -r p pp; do
        [ -z "$p" ] && continue
        PID_PPID[$p]="$pp"
    done < <(ps -eo pid=,ppid= 2>/dev/null)
}

# Walk up the process tree from $1 looking for any PID in the
# space-separated set $2.  Returns 0 and prints the matching pane PID.
find_ancestor_pane() {
    local pid="$1"
    local pane_pid_set=" $2 "
    local depth=0
    while (( pid > 1 && depth < 30 )); do
        if [[ "$pane_pid_set" == *" $pid "* ]]; then
            echo "$pid"
            return 0
        fi
        pid="${PID_PPID[$pid]:-}"
        [ -z "$pid" ] && return 1
        ((depth++))
    done
    return 1
}

# ─── State priority ───────────────────────────────────────────────
_state_pri() {
    case "$1" in
        working) echo 5 ;; wait)    echo 4 ;; ask)     echo 3 ;;
        done)    echo 2 ;; parked)  echo 1 ;; *)       echo 0 ;;
    esac
}

# ─── Sidebar mode (tree | agents) ─────────────────────────────────
# Set by sidebar-toggle-mode.sh. In agents mode the SESSIONS section
# only includes sessions/worktrees that have at least one agent pane,
# and every agent pane is expanded (even when a session has just one).
_sidebar_mode() {
    local mode_file="$STATUS_DIR/.sidebar-mode"
    local mode=""
    [ -f "$mode_file" ] && mode=$(<"$mode_file")
    case "$mode" in
        agents) echo agents ;;
        *)      echo tree ;;
    esac
}

# ─── Main collection ──────────────────────────────────────────────
collect_data() {
    expire_wait_timers >/dev/null
    completion_ack_active

    local SIDEBAR_MODE
    SIDEBAR_MODE=$(_sidebar_mode)

    # Quick change detection: skip full rebuild if nothing changed.
    (( ++_COLLECT_TICK >= 10 )) && { _COLLECT_TICK=0; _LAST_STATUS_MTIME=""; }
    local cur_mtime
    if [[ "$(uname)" == "Darwin" ]]; then
        cur_mtime=$(stat -f %m "$STATUS_DIR" "$PARKED_DIR" "$WAIT_DIR" "$PANE_DIR" "$REFRESH_FILE" 2>/dev/null)
    else
        cur_mtime=$(stat -c %Y "$STATUS_DIR" "$PARKED_DIR" "$WAIT_DIR" "$PANE_DIR" "$REFRESH_FILE" 2>/dev/null)
    fi
    # Creation and acknowledgement can happen in the same second. Immutable
    # event filenames detect those changes even on filesystems with coarse mtimes.
    if [ -n "${COMPLETION_DIR:-}" ]; then
        local completion_files=("$COMPLETION_DIR/"*.unread)
        cur_mtime+="|${completion_files[*]}"
    fi
    if [[ "$cur_mtime" == "$_LAST_STATUS_MTIME" ]]; then
        _COLLECT_CHANGED=0
        return
    fi
    _LAST_STATUS_MTIME="$cur_mtime"
    _COLLECT_CHANGED=1

    ENTRIES=()
    SEL_NAMES=()
    SEL_TYPES=()
    SUMMARY_WORKING=0
    SUMMARY_WAITING=0
    SUMMARY_DONE=0
    SUMMARY_TOTAL=0
    SUMMARY_HAS_WORKING=0
    SUMMARY_AGENTS=()

    local now
    printf -v now '%(%s)T' -1

    # ── 1+2. Session + pane data (single tmux call) ────────────
    declare -A sess_state sess_extra sess_ssh sess_seen
    declare -A sess_cwd
    declare -A pane_to_session   # pane_pid → session
    declare -A pane_to_id        # pane_pid → pane_id (e.g. %5)
    declare -A pane_to_window    # pane_id → window_index
    declare -A window_names      # session:window_index → window_name
    local all_pane_pids=""

    local _tab=$'\t'
    while IFS=$'\t' read -r sname pane_id pcwd ppid win_idx win_name; do
        [ -z "$sname" ] && continue

        [[ -z "${sess_cwd[$sname]:-}" ]] && sess_cwd[$sname]="$pcwd"
        pane_to_session[$ppid]="$sname"
        pane_to_id[$ppid]="$pane_id"
        pane_to_window[$pane_id]="$win_idx"
        window_names["${sname}:${win_idx}"]="$win_name"
        all_pane_pids+="$ppid "

        [[ -n "${sess_seen[$sname]:-}" ]] && continue
        sess_seen[$sname]=1

        local state="noagent" extra="" is_ssh="" status=""

        if session_is_fully_parked "$sname"; then
            status="parked"
        elif [ -f "$STATUS_DIR/${sname}-remote.status" ]; then
            status=$(<"$STATUS_DIR/${sname}-remote.status")
            is_ssh="ssh"
        fi
        if [ -f "$STATUS_DIR/${sname}.status" ]; then
            status=$(<"$STATUS_DIR/${sname}.status")
        fi
        if [ "$status" = "parked" ] && ! session_is_fully_parked "$sname"; then
            status=""
        fi
        if [ "$status" = "wait" ] && [ ! -f "$WAIT_DIR/${sname}.wait" ]; then
            status=""
        fi
        [ -n "$status" ] && state="$status"

        if [ "$state" = "wait" ]; then
            local wf="$WAIT_DIR/${sname}.wait"
            if [ -f "$wf" ]; then
                local expiry
                expiry=$(<"$wf")
                if [ -n "$expiry" ] && (( expiry > now )); then
                    extra="$(( (expiry - now + 59) / 60 ))m"
                else
                    state="done"
                fi
            fi
        fi
        rm -f "$STATUS_DIR/${sname}.unread" "$STATUS_DIR/${sname}-remote.unread" 2>/dev/null

        sess_state[$sname]="$state"
        sess_extra[$sname]="$extra"
        sess_ssh[$sname]="$is_ssh"
    done < <(tmux list-panes -a -F "#{session_name}${_tab}#{pane_id}${_tab}#{pane_current_path}${_tab}#{pane_pid}${_tab}#{window_index}${_tab}#{window_name}" 2>/dev/null)

    # ── 3. Worktree detection ────────────────────────────────────
    declare -A worktree_parent worktree_children

    declare -A root_to_session
    for sname in "${!sess_cwd[@]}"; do
        local cwd="${sess_cwd[$sname]}"
        if [[ "$cwd" != */.claude/worktrees/* ]]; then
            root_to_session[$cwd]="$sname"
        fi
    done

    for sname in "${!sess_cwd[@]}"; do
        local cwd="${sess_cwd[$sname]}"
        if [[ "$cwd" == */.claude/worktrees/* ]]; then
            local repo_root="${cwd%%/.claude/worktrees/*}"
            local parent="${root_to_session[$repo_root]:-}"
            if [ -n "$parent" ] && [ "$parent" != "$sname" ]; then
                worktree_parent[$sname]="$parent"
                worktree_children[$parent]+="$sname "
            fi
        fi
    done

    # ── 4. Multi-agent pane detection ────────────────────────────
    LIVE_PANES=()
    for ppid in $all_pane_pids; do
        local pid="${pane_to_id[$ppid]:-}"
        [ -n "$pid" ] && LIVE_PANES[$pid]=1
    done

    # Rebuild known agents each cycle from current detections plus persisted
    # hook-written pane markers. This avoids stale in-memory agent identities
    # when a pane stops running Claude/Codex but stays open.
    KNOWN_AGENTS=()

    local pane_dir="$STATUS_DIR/panes"
    local agent_file=""
    for agent_file in "$pane_dir/"*.agent; do
        [ -f "$agent_file" ] || continue
        local bname pid_id owner agent_name
        bname=$(basename "$agent_file" .agent)
        pid_id="${bname##*_}"
        owner="${bname%_${pid_id}}"
        [ -n "${LIVE_PANES[$pid_id]:-}" ] || continue
        agent_name=$(<"$agent_file")
        [ -n "$agent_name" ] || continue
        KNOWN_AGENTS["${owner}:${pid_id}"]="$agent_name"
    done

    # Find agent processes — scan ps globally, walk UP to find owning pane.
    # (ps instead of pgrep: macOS pgrep cannot print the command line, which
    # we need to tell claude/codex/devin apart.)
    local agent_lines
    agent_lines=$(scan_agent_processes)
    if [[ -n "$agent_lines" ]]; then
        _build_pid_map
        while read -r agent_name apid acmd; do
            [ -z "$apid" ] && continue

            local pane_pid
            pane_pid=$(find_ancestor_pane "$apid" "$all_pane_pids") || continue
            local owner="${pane_to_session[$pane_pid]:-}"
            [ -z "$owner" ] && continue
            local pid_id="${pane_to_id[$pane_pid]:-}"

            # Hook-written .agent names are authoritative; process detection
            # fills gaps and never downgrades a specific name to "agent".
            local akey="${owner}:${pid_id}"
            local known="${KNOWN_AGENTS[$akey]:-}"
            if [ -z "$known" ] || { [ "$known" = "agent" ] && [ "$agent_name" != "agent" ]; }; then
                KNOWN_AGENTS[$akey]="$agent_name"
            fi
        done <<< "$agent_lines"
    fi

    # Build sess_agents from KNOWN_AGENTS + per-pane status files.
    declare -A sess_agents
    for key in "${!KNOWN_AGENTS[@]}"; do
        local owner="${key%%:*}"
        local pid_id="${key#*:}"
        local agent_name="${KNOWN_AGENTS[$key]}"
        local pane_status=""
        local pane_file="$pane_dir/${owner}_${pid_id}.status"
        if [ -f "$pane_file" ]; then
            pane_status=$(<"$pane_file")
        fi
        # Check per-pane parked/wait overrides
        [ -f "$PARKED_DIR/${owner}_${pid_id}.parked" ] && pane_status="parked"
        local pwf="$WAIT_DIR/${owner}_${pid_id}.wait"
        if [ -f "$pwf" ]; then
            local exp=$(<"$pwf")
            if [ -n "$exp" ] && (( exp > now )); then
                pane_status="wait"
            fi
        fi
        [ -z "$pane_status" ] && pane_status="${sess_state[$owner]:-done}"
        sess_agents[$owner]+="${pid_id}:${agent_name}:${pane_status} "
    done

    # ── 5. Re-derive session state from per-pane statuses ──────
    for sname in "${!sess_agents[@]}"; do
        local cur_st="${sess_state[$sname]}"
        [[ "$cur_st" == "wait" || "$cur_st" == "parked" ]] && continue
        local best_pri=-1 best_st="$cur_st"
        best_pri=$(_state_pri "$best_st" 2>/dev/null || echo 0)
        for ap in ${sess_agents[$sname]}; do
            local rest="${ap#*:}"; rest="${rest#*:}"
            local ps="${rest%%:*}"
            local pp
            pp=$(_state_pri "$ps" 2>/dev/null || echo 0)
            if (( pp > best_pri )); then
                best_pri=$pp; best_st="$ps"
            fi
        done
        sess_state[$sname]="$best_st"
    done

    # ── 5a. Shared status-line summary counts ────────────────────
    for sname in "${!sess_state[@]}"; do
        case "${sess_state[$sname]}" in
            working)
                ((SUMMARY_WORKING++))
                ((SUMMARY_TOTAL++))
                SUMMARY_HAS_WORKING=1
                ;;
            wait)
                ((SUMMARY_WAITING++))
                ((SUMMARY_TOTAL++))
                ;;
            done|ask)
                ((SUMMARY_DONE++))
                ((SUMMARY_TOTAL++))
                ;;
            *)
                ;;
        esac
    done

    # ── 5a'. Per-agent status-line list ─────────────────────────
    # One "name:status" spec per agent, ordered by session name then pane
    # id so glyph positions in the status bar stay stable across refreshes.
    # Sessions with detected agent panes contribute one spec per pane;
    # sessions tracked only at session level (e.g. SSH remotes) contribute
    # a single generic spec.
    SUMMARY_AGENTS=()
    while IFS= read -r sname; do
        [ -z "$sname" ] && continue
        local sstate="${sess_state[$sname]}"
        case "$sstate" in
            working|wait|done|ask) ;;
            *) continue ;;
        esac

        if [ -z "${sess_agents[$sname]:-}" ]; then
            SUMMARY_AGENTS+=("agent:${sstate}")
            continue
        fi

        local ap
        while IFS= read -r ap; do
            [ -z "$ap" ] && continue
            local aname="${ap#*:}"
            aname="${aname%%:*}"
            local astatus="${ap#*:}"
            astatus="${astatus#*:}"
            # A session-wide wait snoozes every agent in it. Parked panes
            # stay hidden (matching collect_status_agents in status-line.sh).
            if [ "$sstate" = "wait" ] && [ "$astatus" != "parked" ]; then
                astatus="wait"
            fi
            case "$astatus" in
                working|wait|done|ask)
                    SUMMARY_AGENTS+=("${aname}:${astatus}")
                    ;;
            esac
        done < <(printf '%s\n' ${sess_agents[$sname]} | sort)
    done < <(printf '%s\n' "${!sess_state[@]}" | sort)

    # ── 5b. Compute per-session pane counts ─────────────────────
    PANE_COUNTS=()
    for sname in "${!sess_agents[@]}"; do
        local agents="${sess_agents[$sname]}"
        local pw=0 pd=0 pwt=0 count=0
        local seen=""
        for ap in $agents; do
            local pid="${ap%%:*}"
            [[ " $seen " == *" $pid "* ]] && continue
            seen+="$pid "
            local rest="${ap#*:}"; local ps="${rest#*:}"
            case "$ps" in
                working) ((pw++)) ;; done|ask) ((pd++)) ;; wait) ((pwt++)) ;;
            esac
            ((count++))
        done
        (( count > 1 )) && PANE_COUNTS[$sname]="${pw}:${pd}:${pwt}"
    done

    # ── 6. Collapse single-worktree parents ────────────────────
    for parent in "${!worktree_children[@]}"; do
        local children=(${worktree_children[$parent]})
        if (( ${#children[@]} < 2 )); then
            for child in "${children[@]}"; do
                unset "worktree_parent[$child]"
            done
            unset "worktree_children[$parent]"
        fi
    done

    # ── 7. Compute effective state (bubble-up) ─────────────────
    declare -A eff_state
    for sname in "${!sess_state[@]}"; do
        eff_state[$sname]="${sess_state[$sname]}"
    done
    for parent in "${!worktree_children[@]}"; do
        local best="${eff_state[$parent]}"
        local best_pri
        best_pri=$(_state_pri "$best")
        for child in ${worktree_children[$parent]}; do
            local cp
            cp=$(_state_pri "${sess_state[$child]}")
            if (( cp > best_pri )); then
                best_pri=$cp
                best="${sess_state[$child]}"
            fi
        done
        eff_state[$parent]="$best"
    done

    local all_sessions=()
    for sname in "${!sess_state[@]}"; do
        all_sessions+=("$sname")
    done
    if (( ${#all_sessions[@]} > 0 )); then
        IFS=$'\n' all_sessions=($(sort <<< "${all_sessions[*]}")); unset IFS
    fi

    # ── 8. Build ENTRIES ─────────────────────────────────────────

    _get_agent_arr() {
        local session="$1"
        local agents="${sess_agents[$session]:-}"
        _agent_result=()
        [ -z "$agents" ] && return
        local seen=""
        for ap in $agents; do
            local pid="${ap%%:*}"
            [[ " $seen " == *" $pid "* ]] && continue
            seen+="$pid "
            _agent_result+=("$ap")
        done
    }

    _emit_agents() {
        local sname="$1"
        _get_agent_arr "$sname"
        local agents=("${_agent_result[@]}")
        # Tree mode collapses single-agent sessions to just the session row.
        # Agents mode expands every agent pane, even when there is only one.
        if [[ "$SIDEBAR_MODE" != "agents" ]]; then
            (( ${#agents[@]} <= 1 )) && return
        else
            (( ${#agents[@]} == 0 )) && return
        fi

        local -A win_agents=() win_seen=()
        local -a win_order=()
        for ap in "${agents[@]}"; do
            local pid="${ap%%:*}"
            local wi="${pane_to_window[$pid]:-0}"
            [[ -z "${win_seen[$wi]:-}" ]] && { win_order+=("$wi"); win_seen[$wi]=1; }
            win_agents[$wi]+="$ap "
        done

        if (( ${#win_order[@]} == 1 )); then
            local ai=0 total=${#agents[@]}
            for ap in "${agents[@]}"; do
                ((ai++))
                local pid="${ap%%:*}" r="${ap#*:}"
                local agent="${r%%:*}" st="${r#*:}"
                ENTRIES+=("P|${sname}|${pid}|${agent}|${st}|$((ai==total))")
                SEL_NAMES+=("${sname}:${pid}")
                SEL_TYPES+=("P")
            done
        else
            local nw=${#win_order[@]} wi=0
            for widx in "${win_order[@]}"; do
                ((wi++))
                local wname="${window_names[${sname}:${widx}]:-window-$widx}"
                local w_last=$((wi==nw))
                local pc=0
                for _ in ${win_agents[$widx]}; do ((pc++)); done

                if (( pc == 1 )); then
                    local ap="${win_agents[$widx]%% *}"
                    local pid="${ap%%:*}" r="${ap#*:}"
                    local st="${r#*:}"
                    ENTRIES+=("P|${sname}|${pid}|${wname}|${st}|${w_last}")
                    SEL_NAMES+=("${sname}:w${widx}")
                    SEL_TYPES+=("P")
                else
                    local best_pri=-1 best_st="noagent"
                    for wap in ${win_agents[$widx]}; do
                        local ws="${wap#*:}"; ws="${ws#*:}"
                        local wp; wp=$(_state_pri "$ws" 2>/dev/null || echo 0)
                        (( wp > best_pri )) && { best_pri=$wp; best_st="$ws"; }
                    done
                    ENTRIES+=("P|${sname}|w${widx}|${wname}|${best_st}|${w_last}")
                    SEL_NAMES+=("${sname}:w${widx}")
                    SEL_TYPES+=("P")
                    local ai=0
                    for wap in ${win_agents[$widx]}; do
                        ((ai++))
                        local pid="${wap%%:*}" r="${wap#*:}"
                        local agent="${r%%:*}" st="${r#*:}"
                        ENTRIES+=("Q|${sname}|${pid}|${agent}|${st}|$((ai==pc))|${w_last}")
                        SEL_NAMES+=("${sname}:${pid}")
                        SEL_TYPES+=("P")
                    done
                fi
            done
        fi
    }

    _emit_session() {
        local entry="$1" sname="$2"
        ENTRIES+=("$entry")
        SEL_NAMES+=("$sname")
        SEL_TYPES+=("S")

        local wt_list="${worktree_children[$sname]:-}"
        local wt_names=()
        for wt in $wt_list; do
            # In agents mode, hide worktree children that have no agents.
            if [[ "$SIDEBAR_MODE" == "agents" ]] && [[ -z "${sess_agents[$wt]:-}" ]]; then
                continue
            fi
            wt_names+=("$wt")
        done
        local wi=0
        for wt in "${wt_names[@]}"; do
            ((wi++))
            local is_last=$((wi==${#wt_names[@]}))
            ENTRIES+=("W|${wt}|${sess_state[$wt]}|${sess_extra[$wt]}|${sess_ssh[$wt]}|${is_last}")
            SEL_NAMES+=("$wt")
            SEL_TYPES+=("W")
            _emit_agents "$wt"
        done

        _emit_agents "$sname"
    }

    # Unread completions have their own history, independent of live status.
    # They remain visible in agents mode too, where the live INBOX is hidden.
    RECENT_COUNT=0
    local completed_at completed_pane completed_session completed_window completed_index completed_agent completed_name
    while IFS=$'\t' read -r completed_at completed_pane completed_session completed_window completed_index completed_agent completed_name; do
        [ -n "$completed_pane" ] || continue
        (( RECENT_COUNT == 0 )) && ENTRIES+=("G|RECENTLY READY|green")
        ENTRIES+=("I|${completed_session}|${completed_pane}|${completed_session} › ${completed_name} .${completed_index} (${completed_agent})|done")
        SEL_NAMES+=("${completed_session}:${completed_pane}")
        SEL_TYPES+=("P")
        RECENT_COUNT=$((RECENT_COUNT + 1))
    done < <(completion_inbox_rows)

    # ── INBOX ────────────────────────────────────────────────────
    if [[ "$SIDEBAR_MODE" != "agents" ]]; then
        local inbox=()
        for sname in "${all_sessions[@]}"; do
            session_is_fully_parked "$sname" && continue
            if [[ -n "${sess_agents[$sname]:-}" ]]; then
                _get_agent_arr "$sname"
                local arr=("${_agent_result[@]}")
                if (( ${#arr[@]} <= 1 )); then
                    local ap="${arr[0]:-}"
                    local pst="${ap#*:}"; pst="${pst#*:}"
                    [[ "$pst" == "done" || "$pst" == "ask" ]] && inbox+=("I|${sname}||${sname}|done")
                    continue
                fi

                local -A _ib_win=()
                for ap in "${arr[@]}"; do
                    local pid="${ap%%:*}"
                    local wi="${pane_to_window[$pid]:-0}"
                    _ib_win[$wi]+="$ap "
                done

                if (( ${#_ib_win[@]} == 1 )); then
                    local only_wi=""
                    for only_wi in "${!_ib_win[@]}"; do
                        break
                    done

                    local ai=0
                    local pid=""
                    while IFS= read -r pid; do
                        [ -n "$pid" ] || continue

                        local ap=""
                        local candidate=""
                        for candidate in ${_ib_win[$only_wi]}; do
                            [ "${candidate%%:*}" = "$pid" ] || continue
                            ap="$candidate"
                            break
                        done
                        [ -n "$ap" ] || continue

                        ((ai++))
                        local r="${ap#*:}"
                        local aname="${r%%:*}"
                        local pst="${r#*:}"
                        [[ "$pst" == "done" || "$pst" == "ask" ]] && inbox+=("I|${sname}|${pid}|${sname} › ${aname} #${ai}|done")
                    done < <(tmux list-panes -t "${sname}:${only_wi}" -F "#{pane_id}" 2>/dev/null)
                else
                    local wi=""
                    while IFS= read -r wi; do
                        [ -n "${_ib_win[$wi]:-}" ] || continue

                        local wname="${window_names[${sname}:${wi}]:-window-$wi}"
                        local any_done=0
                        local wap=""
                        for wap in ${_ib_win[$wi]}; do
                            local ws="${wap#*:}"
                            ws="${ws#*:}"
                            [[ "$ws" == "done" || "$ws" == "ask" ]] && any_done=1
                        done
                        (( any_done )) && inbox+=("I|${sname}|w${wi}|${sname} › ${wname}|done")
                    done < <(tmux list-windows -t "$sname" -F "#{window_index}" 2>/dev/null)
                fi

                continue
            fi

            [[ -n "${worktree_parent[$sname]:-}" ]] && continue
            local st="${eff_state[$sname]}"
            [[ "$st" == "done" || "$st" == "ask" ]] && inbox+=("I|${sname}||${sname}|done")
        done

        if (( ${#inbox[@]} > 0 )); then
            ENTRIES+=("G|INBOX|green")
            for entry in "${inbox[@]}"; do
                ENTRIES+=("$entry")
                local r="${entry#I|}"
                local sname="${r%%|*}"; r="${r#*|}"
                local token="${r%%|*}"
                if [[ -n "$token" ]]; then
                    SEL_NAMES+=("${sname}:${token}")
                    SEL_TYPES+=("P")
                else
                    SEL_NAMES+=("$sname")
                    SEL_TYPES+=("S")
                fi
            done
        fi
    fi

    # ── SESSIONS ─────────────────────────────────────────────────
    local sorted_sessions=()
    for sname in "${all_sessions[@]}"; do
        [[ -n "${worktree_parent[$sname]:-}" ]] && continue
        # In agents mode, only list sessions that have at least one
        # agent pane (after collapsing single-worktree-parents above,
        # a parent inherits its worktree children through eff_state but
        # not through sess_agents — so also keep it if any of its
        # worktree children carry agents).
        if [[ "$SIDEBAR_MODE" == "agents" ]]; then
            local _has_agents=0
            [[ -n "${sess_agents[$sname]:-}" ]] && _has_agents=1
            if (( ! _has_agents )); then
                for _wt in ${worktree_children[$sname]:-}; do
                    [[ -n "${sess_agents[$_wt]:-}" ]] && { _has_agents=1; break; }
                done
            fi
            (( _has_agents )) || continue
        fi
        sorted_sessions+=("$sname")
    done

    SESS_START=${#SEL_NAMES[@]}
    if (( ${#sorted_sessions[@]} > 0 )); then
        ENTRIES+=("G|SESSIONS|gray")
        for sname in "${sorted_sessions[@]}"; do
            local st="${eff_state[$sname]}"
            local ex="${sess_extra[$sname]}"
            local ss="${sess_ssh[$sname]}"
            local entry="S|${sname}|${st}|${ex}|${ss}"
            _emit_session "$entry" "$sname"
        done
    fi

    # ── 9. Clean up dead sessions ────────────────────────────────
    for sf in "$STATUS_DIR"/*.status; do
        [ -f "$sf" ] || continue
        local sname
        sname=$(basename "$sf" .status)
        [[ "$sname" == *-remote ]] && continue
        [[ -n "${sess_seen[$sname]:-}" ]] && continue
        rm -f "$sf" "$STATUS_DIR/${sname}-remote.status"
        rm -f "$PARKED_DIR/${sname}.parked" "$PARKED_DIR/${sname}_"*.parked
        rm -f "$WAIT_DIR/${sname}.wait" "$WAIT_DIR/${sname}_"*.wait
        rm -f "$STATUS_DIR/panes/${sname}_"*.status "$STATUS_DIR/panes/${sname}_"*.agent
    done

    # Clean up pane metadata for dead panes.
    for psf in "$STATUS_DIR/panes/"*.status; do
        [ -f "$psf" ] || continue
        local bname pid_id
        bname=$(basename "$psf" .status)
        pid_id="${bname##*_}"
        [[ -z "${LIVE_PANES[$pid_id]:-}" ]] && rm -f "$psf"
    done
    for paf in "$STATUS_DIR/panes/"*.agent; do
        [ -f "$paf" ] || continue
        local bname pid_id
        bname=$(basename "$paf" .agent)
        pid_id="${bname##*_}"
        [[ -z "${LIVE_PANES[$pid_id]:-}" ]] && rm -f "$paf"
    done
}
