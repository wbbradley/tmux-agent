# Changelog

## Unreleased

### Added

- Codex lifecycle hook registration alongside Claude Code
- Shared, product-tagged waiting state for both tools
- Combined status text with per-product counts
- One `prefix + g` queue interleaved by wait time
- Automatic migration from tmux-claude and tmux-codex configuration and state
- Self-contained integration tests

### Changed

- Renamed the project and scripts from tmux-claude to tmux-agent
- Jump to remaining bell-highlighted windows when the agent waiting queue is empty

## [0.1.3] - 2026-05-24

### Fixed

- Restored user-level Claude Code hook registration to `settings.json`.
- Delivered waiting bells to the pane tty so tmux receives them from hooks.

### Changed

- Configured any running tmux server without requiring an attached client.

## [0.1.2] - 2026-04-21

### Changed

- Prepended the status segment and made live configuration self-healing.

## [0.1.1] - 2026-04-09

### Changed

- Cleared the current pane before advancing to the next waiting pane.

## [0.1.0] - 2026-04-08

### Added

- Initial tmux integration for Claude Code waiting-state notifications.
