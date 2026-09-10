# tmux-agent-status

Sidebar-first AI agent session manager for tmux. It gives each tmux session a persistent status sidebar, keeps a compact summary in the status line, and adds a hierarchical `fzf` target switcher for fast jumps and cleanup across agent sessions, windows, and panes.

Claude Code and Codex CLI are both integrated through hooks, so their states come from agent lifecycle events rather than fragile process polling. Custom agents can still integrate through status files or collector extensions.

[![tmux-agent-status demo screenshot](demo/full.png)](demo/full.mp4)

Demo video: [`demo/full.mp4`](demo/full.mp4)

## Features

- Persistent sidebar in every tmux session
- Hierarchical `fzf` target switcher for quick jumps and close actions
- Hook-based Claude Code and Codex tracking
- Wait and park modes for triaging work
- Compact status-line summary with finish notifications
- Works across multi-pane sessions, worktrees, and remote tmux sessions

## Supported Agents

| Agent | Integration | Status |
|-------|-------------|--------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | Hook-based via `hooks/better-hook.sh` | Stable |
| [Codex CLI](https://github.com/openai/codex) | Hook-based via `hooks/codex-hook.sh` | Stable in plugin, hooks still experimental upstream |
| [Devin CLI](https://docs.devin.ai/cli) | Hook-based via `hooks/devin-hook.sh` (local CLI only) | Stable in plugin |
| Custom (Aider, Cline, Copilot CLI, etc.) | Status files or collector extensions | Stable |

All agent sessions can run simultaneously across tmux sessions and panes, each tracked independently.

## Install

With [TPM](https://github.com/tmux-plugins/tpm):

```bash
set -g @plugin 'samleeney/tmux-agent-status'
```

Then press `prefix + I` to install.

On macOS, install a modern Bash before using the sidebar:

```bash
brew install bash
```

The plugin auto-detects Homebrew Bash at `/opt/homebrew/bin/bash` or `/usr/local/bin/bash` when macOS launches scripts with the system Bash 3.2.
If Bash is installed somewhere else, set `TMUX_AGENT_STATUS_BASH` to that path.

The collector uses `flock`, or Perl when `flock` is unavailable, to prevent
duplicate daemons. Install either one if neither is available on your system.

Use fzf 0.71 or newer to keep the popup selection on the same item when
expanding or refreshing the list. Older fzf versions retain their previous
selection behavior.

By default the plugin:

- Appends the live summary to `status-right`
- Starts the sidebar collector daemon
- Auto-creates a sidebar in existing and new tmux sessions
- Binds the popup switcher, wait, park, and next-ready actions

## Claude Code Setup

Add hooks to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.config/tmux/plugins/tmux-agent-status/hooks/better-hook.sh UserPromptSubmit"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.config/tmux/plugins/tmux-agent-status/hooks/better-hook.sh PreToolUse"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.config/tmux/plugins/tmux-agent-status/hooks/better-hook.sh Stop"
          }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.config/tmux/plugins/tmux-agent-status/hooks/better-hook.sh Notification"
          }
        ]
      }
    ]
  }
}
```

Claude Code state is tracked entirely through hooks, so the plugin gets precise working/done transitions directly from the agent. If a turn ends while a background task is still running (e.g. a `run_in_background` Bash command), the `Stop` payload's `background_tasks` array keeps the session marked `working` until a later `Stop` reports the task finished — so backgrounded work doesn't show a premature green checkmark.

## Codex CLI Setup

tmux-agent-status supports official [Codex hooks](https://developers.openai.com/codex/hooks).

Enable hooks in `~/.codex/config.toml`:

```toml
[features]
hooks = true
```

For a one-off session, you can also start Codex with `codex --enable hooks`.

To enable Codex tracking globally, add `~/.codex/hooks.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.config/tmux/plugins/tmux-agent-status/hooks/codex-hook.sh SessionStart"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.config/tmux/plugins/tmux-agent-status/hooks/codex-hook.sh UserPromptSubmit"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.config/tmux/plugins/tmux-agent-status/hooks/codex-hook.sh PreToolUse"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.config/tmux/plugins/tmux-agent-status/hooks/codex-hook.sh Stop"
          }
        ]
      }
    ]
  }
}
```

Restart Codex, then run `/hooks` in the CLI and trust the new command hooks if Codex marks them as pending review. Non-managed command hooks must be trusted before Codex will run them.

Codex state is also hook-based. The handler marks the tmux session or pane `working` on `UserPromptSubmit` and `PreToolUse`, resets it to `done` on `Stop`, and seeds resumed sessions on `SessionStart`.

For repo-local tracking while working on this plugin, put the same hook shape in `<repo>/.codex/hooks.json`. Codex loads project-local hooks once the project `.codex/` layer is trusted.

## Devin CLI Setup

This integrates the local [Devin CLI](https://docs.devin.ai/cli) (the `devin` binary that runs in your terminal), not cloud Devin sessions. The Devin CLI uses a [Claude Code-compatible hooks format](https://docs.devin.ai/cli/extensibility/hooks/overview).

Add hooks to `~/.config/devin/config.json`

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.config/tmux/plugins/tmux-agent-status/hooks/devin-hook.sh SessionStart"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.config/tmux/plugins/tmux-agent-status/hooks/devin-hook.sh UserPromptSubmit"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.config/tmux/plugins/tmux-agent-status/hooks/devin-hook.sh PreToolUse"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.config/tmux/plugins/tmux-agent-status/hooks/devin-hook.sh PostToolUse"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.config/tmux/plugins/tmux-agent-status/hooks/devin-hook.sh Stop"
          }
        ]
      }
    ]
  }
}
```

Run `/hooks` in the CLI to confirm the command hooks are loaded, and trust them if Devin marks them as pending review.

Devin state is hook-based. The handler marks the session or pane `working` on `UserPromptSubmit`/`PreToolUse`/`PostToolUse`, resets it to `done` on `Stop`, and seeds resumed sessions on `SessionStart`.

Without hooks, the collector still auto-detects a running `devin` process inside a pane (presence only); hooks are required for live `working`/`done` state.

## Custom Agent Integration

Integrate any AI coding tool with either of these approaches:

1. Write `working`, `done`, or `wait` to `~/.cache/tmux-agent-status/<session>.status`
2. For pane-level parking or per-pane state, write to `~/.cache/tmux-agent-status/panes/<session>_<pane>.status` and `~/.cache/tmux-agent-status/parked/<session>_<pane>.parked`
3. Extend the collector scan in [`scripts/lib/collect.sh`](scripts/lib/collect.sh) if you want automatic process-based tracking

## Usage

Default mode is sidebar-first:

- Every tmux session gets a sidebar pane automatically
- `prefix + S` opens the hierarchical `fzf` target switcher
- `prefix + o` focuses or creates the sidebar in the current window

| Key | Action |
|-----|--------|
| `prefix + S` | Open the hierarchical `fzf` target switcher |
| `prefix + o` | Focus or create the sidebar |
| `prefix + N` | Jump to the next inbox item in inbox order |
| `prefix + W` | Put the current session or pane into timed wait mode |
| `prefix + p` | Park the current session or pane for later |

The status bar shows one glyph per agent. The glyph identifies the agent,
the colour identifies its status:

| Agent | Glyph |
|-------|-------|
| Claude | `✳` |
| Codex | `⬢` |
| Devin | `◆` |
| Other | `●` |

| Status | Colour |
|--------|--------|
| working | yellow, pulsing (`✳`/`✻`, `⬢`/`⬡`, …) |
| waiting | cyan |
| ask | magenta |
| done | green |

For example two Claude agents working alongside a finished Codex agent
renders as two yellow Claude glyphs next to a green `⬢`. Each working
glyph flips frames every second, staggered by position (`✳ ✻` one second,
`✻ ✳` the next) so a row of busy agents pulses rather than blinking in
unison. Glyphs and colours are defined in
[`scripts/lib/status-summary.sh`](scripts/lib/status-summary.sh) if you want
different ones.

Parked sessions stay visible in the sidebar and switcher, but are excluded from the status-line summary.

Inside the popup switcher:

- `Enter` switches to the selected session, window, or pane
- `Tab` expands or collapses the selected session or window
- `Ctrl-X` closes the selected pane immediately
- `Ctrl-X` on a window immediately closes that window and all child panes
- `Ctrl-X` on a session immediately closes that session and all child windows and panes
- `Ctrl-P` parks or unparks the selected session, window, or pane
- `Ctrl-W` opens wait mode for the selected target, or cancels an existing wait
- `Ctrl-R` resets tracked state

Inside the sidebar:

- `x`, `p`, and `w` perform the same close, park, and wait actions without interfering with popup search input

`prefix + N` follows the same top-to-bottom order as the `INBOX` section. The inbox is ordered by session name, then by tmux window order within each session.

Parking, waiting, and closing always apply to the selected scope only:

- selecting a session row affects the whole session
- selecting a window row affects only that window
- selecting a pane row affects only that pane

In multi-window sessions, sidebar and inbox rows labeled with a window name operate on that window, not just the first pane inside it.

## Configuration

```tmux
set -g @agent-status-key "S"
set -g @agent-sidebar-key "o"
set -g @agent-next-done-key "N"
set -g @agent-wait-key "W"
set -g @agent-park-key "p"

set -g @agent-switcher-style "both"        # popup | sidebar | both
set -g @agent-status-display-method "popup" # popup | window
set -g @agent-sidebar-width "42"

# Switcher view (prefix + S). "tree" is the hierarchical
# session/window/pane list (default). "agents" is a flat list of every
# agent pane sorted by status. Toggle mid-session with ctrl-f.
set -g @agent-switcher-default-mode "tree"  # tree | agents

# Collector poll rate. The daemon wakes every @agent-tick-seconds to animate
# the spinner and re-collects every @agent-ticks-per-collect wakeups.
# Lower values are more responsive but cost noticeably more CPU.
set -g @agent-tick-seconds "1"
set -g @agent-ticks-per-collect "5"
```

Polling options are read when the collector starts. The tick interval must be
a positive number of seconds; the collection count must be an integer from
1 to 999999999. Invalid values produce a warning and use the defaults.

`@agent-switcher-style "both"` is the default. It keeps the persistent sidebar and leaves `prefix + S` as the lightweight popup switcher.

The switcher popup has two views. **Tree** (default) is the hierarchical session/window/pane list; tab expands/collapses. **Agents** is a flat list of every agent pane (any status) sorted by priority — `ask`, `done`, `working`, `wait`, `parked` — with a live preview pane and 2-second refresh. Press `ctrl-f` inside the popup to toggle between views.

The sidebar has the same two views, toggled with `m` from inside the sidebar pane (alongside `w`/`p`/`x` for wait/park/close). In **tree** mode the SESSIONS section lists every session and collapses single-agent sessions to one row; the INBOX section surfaces `done`/`ask` work. In **agents** mode the SESSIONS section is filtered to sessions/worktrees that contain agent panes and every agent pane is expanded; INBOX is suppressed because it would duplicate the same rows.

## Notification Sounds

Play a sound when an agent finishes:

```tmux
set -g @agent-notification-sound "chime"
```

Options: `chime` (default), `bell`, `fanfare`, `frog`, `speech`, `none`.

## Multi-Agent Deploy

Launch parallel AI coding sessions with isolated git worktrees:

```bash
bash ~/.config/tmux/plugins/tmux-agent-status/scripts/deploy-sessions.sh manifest.json
```

Each session gets a `deploy/<name>` branch, and the plugin tracks the spawned sessions automatically.

## SSH Remote Sessions

Monitor AI agents on remote machines:

```bash
./setup-server.sh <session-name> <ssh-host>
```

Works with cloud VMs, GPU boxes, and any SSH-accessible tmux host.

## How It Works

```text
┌──────────────┐    hooks     ┌──────────────────────────┐
│ Claude Code  ├─────────────►│ ~/.cache/tmux-agent-     │
└──────────────┘              │ status/                  │
                              │ <session>.status         │
┌──────────────┐    hooks     │ panes/*.status           │
│ Codex CLI    ├─────────────►│ wait/*.wait              │
└──────────────┘              │ parked/*.parked          │
                              └─────────────┬────────────┘
┌──────────────┐ status files               │
│ Custom agent ├────────────────────────────┘
└──────────────┘
                                            ▼
                              ┌──────────────────────────┐
                              │ sidebar-collector.sh     │
                              │ writes shared cache and  │
                              │ status summary           │
                              └─────────────┬────────────┘
                                            │
                         ┌──────────────────┼──────────────────┐
                         ▼                  ▼                  ▼
                 ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
                 │ sidebar pane │   │ status line  │   │ fzf switcher │
                 └──────────────┘   └──────────────┘   └──────────────┘
```

- Claude Code support is hook-based
- Codex CLI support is hook-based
- Custom agents can be file-based or process-detected
- The sidebar is the main live view; the `fzf` switcher is the quick jump and close tool

## License

MIT
