# tmux-agent

tmux-agent turns tmux into a shared attention queue for Claude Code and the
Codex CLI. When either agent pauses for input or approval, it marks the pane as
waiting, surfaces the wait in the tmux status bar, and adds it to a single queue
ordered by when attention was requested. Press `prefix + g` to jump to the
oldest waiting agent; focusing the pane or submitting a prompt clears the wait.
When the agent queue is empty, the same binding visits windows with bell alerts.

Setup installs the lifecycle hooks for one or both tools and configures the live
tmux server without requiring changes to `tmux.conf`. It can also replace the
older tmux-claude and tmux-codex integrations while preserving pending waits.

## Features

- **Shared status:** shows `[Claude waiting]`, `[Codex waiting]`, or a combined
  count such as `[Agents waiting: Claude 2, Codex 1]`.
- **One jump binding:** `prefix + g` switches to the oldest waiting Claude or
  Codex pane, interleaved by the time each agent started waiting. Once the queue
  is empty, it visits remaining windows with bell alerts.
- **Bell on wait:** tmux can highlight the window immediately when bell
  monitoring is enabled.
- **Auto-clear on activity:** submitting a prompt or focusing a pane clears its
  applicable waiting state.
- **Safe migration:** setup replaces tmux-claude and tmux-codex hook entries,
  collapses their tmux configuration, and preserves outstanding waits.
- **Safe outside tmux:** hooks silently skip tmux work when no pane is present.

## Requirements

- Claude Code with hooks support
- Codex CLI with lifecycle hooks
- tmux 3.x+
- Python 3, used to merge JSON hook configuration safely

## Install

Make the scripts available and register both tools:

```sh
git clone <repo-url> ~/src/tmux-agent
~/src/tmux-agent/bin/tmux-agent-setup
```

Setup updates `~/.claude/settings.json` and `~/.codex/hooks.json` without
replacing unrelated settings or hooks. It is idempotent and can be rerun after
moving the checkout so absolute hook paths point to the new location. The
`~/.claude` and `~/.codex` directories must already exist. Setup deliberately
does not create these top-level directories, so it cannot replace or obstruct
symlinks managed by a dotfiles or agent-configuration repository.

Codex requires explicit trust for non-managed command hooks. After setup, start
a new Codex session, run `/hooks`, review the tmux-agent entries, and trust them.

To register only one tool, pass its name:

```sh
tmux-agent-setup claude
tmux-agent-setup codex
```

### Migrating from tmux-claude and tmux-codex

Run `tmux-agent-setup`. It removes legacy tmux-claude/tmux-codex handlers from
the two hook files, replaces their live status segments and keybindings with the
shared integration, and copies pending wait files into the combined queue while
preserving their timestamps. Once the new hooks work, the old checkouts are no
longer needed.

## Uninstall

```sh
~/src/tmux-agent/bin/tmux-agent-teardown
```

Teardown surgically removes tmux-agent and legacy tmux-claude/tmux-codex hook
handlers while preserving unrelated configuration. It also removes the shared
live tmux integration and temporary state. Pass `claude` or `codex` to remove
only that product's hooks and wait files while leaving the shared tmux layer in
place for the other product.

## How it works

Hooks write state under `/tmp/tmux-agent-<uid>/` using filenames such as
`%12.claude.waiting` and `%7.codex.waiting`. Separate files allow both products
to have a waiting state associated with the same pane. Their modification times
form one queue for `prefix + g`.

Window bell highlights are separate from this queue: submitting a prompt clears
an agent's wait but tmux keeps the window's bell alert until the window is visited.
Other programs can also ring bells. After exhausting recorded agent waits,
`prefix + g` visits bell-highlighted windows in the current session's window
order and displays `Window bell (no agent wait recorded)`. A bell identifies a
window, so this fallback leaves that window's selected pane unchanged.

| Event | Claude Code | Codex |
|---|---|---|
| Turn stops | Mark waiting | Mark waiting |
| Approval needed | Mark waiting | Mark waiting |
| User question/notification | Mark waiting | — |
| Prompt submitted | Clear Claude wait | Clear Codex wait |
| Session ends | Clear Claude wait | — |
| tmux pane/window focus | Clear all waits for the pane | Clear all waits for the pane |

Codex currently has no `SessionEnd` lifecycle hook. A wait left behind after a
session exits is cleared when its pane receives focus or garbage-collected after
24 hours.

The Codex integration follows the official [Codex hooks documentation](https://developers.openai.com/codex/hooks).

## Scripts

| Script | Purpose |
|---|---|
| `tmux-agent-setup` | Register one or both products and configure tmux |
| `tmux-agent-teardown` | Remove one or both products and shared state |
| `tmux-agent-hooks` | Surgically merge/remove JSON hook entries |
| `tmux-agent-ensure-tmux` | Idempotently install the shared tmux layer |
| `tmux-agent-notify` | Mark a product/pane waiting and ring its bell |
| `tmux-agent-resume` | Clear one product's wait on prompt submission |
| `tmux-agent-cleanup` | Clear one product's wait on session end |
| `tmux-agent-focus` | Clear every wait associated with a focused pane |
| `tmux-agent-status` | Render product-specific or combined status text |
| `tmux-agent-jump` | Jump to the oldest live pane in the shared queue |

## Deleted working directories

The notify, resume, and cleanup scripts fall back to `/` if their inherited
working directory has been deleted. They use `TMUX_PANE` and the state directory,
so they do not need the project checkout. Valid working directories are retained
so relative `TMUX_AGENT_STATE_DIR` overrides continue to work.

This recovery only applies once the script starts. Codex launches command hooks
in the session's working directory. If that path no longer exists, the launcher
can fail with `No such file or directory (os error 2)` before executing any hook
code; adding `cd /` to the hook command cannot fix that. Resume the session from
an existing directory. A complete fix requires a fallback in Codex's hook
launcher. Shells may also print a startup `getcwd` warning before the script can
recover an inherited deleted directory.

## Development

Run the self-contained test suite:

```sh
./tests/test.sh
./tests/test-jump.sh
```
