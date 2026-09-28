#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=${TMPDIR:-/tmp}/tmux-agent-test-$$
trap '/bin/rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/home/.claude" "$TMP/home/.codex" "$TMP/state" \
    "$TMP/claude-state" "$TMP/codex-state" "$TMP/fake-bin" "$TMP/pycache"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    haystack=$1
    needle=$2
    printf '%s' "$haystack" | grep -F "$needle" >/dev/null ||
        fail "expected '$needle' in '$haystack'"
}

assert_file() {
    [ -f "$1" ] || fail "expected file: $1"
}

assert_no_file() {
    [ ! -e "$1" ] || fail "expected no file: $1"
}

assert_no_path() {
    [ ! -e "$1" ] && [ ! -L "$1" ] || fail "expected no path: $1"
}

for script in "$ROOT"/bin/*; do
    [ "$(basename "$script")" = tmux-agent-hooks ] && continue
    sh -n "$script" || fail "invalid shell syntax: $script"
done
PYTHONPYCACHEPREFIX="$TMP/pycache" python3 -m py_compile "$ROOT/bin/tmux-agent-hooks"

cat >"$TMP/home/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "Stop": [{"hooks": [
      {"type": "command", "command": "keep-claude"},
      {"type": "command", "command": "tmux-claude-notify"}
    ]}]
  },
  "claudeSetting": true
}
JSON

cat >"$TMP/home/.codex/hooks.json" <<'JSON'
{
  "hooks": {
    "Stop": [{"hooks": [
      {"type": "command", "command": "keep-codex"},
      {"type": "command", "command": "/old/tmux-codex-notify"}
    ]}]
  },
  "codexSetting": true
}
JSON

"$ROOT/bin/tmux-agent-hooks" install claude "$TMP/home/.claude/settings.json" "$ROOT/bin"
"$ROOT/bin/tmux-agent-hooks" install codex "$TMP/home/.codex/hooks.json" "$ROOT/bin"
# Reinstalling must replace, not duplicate, our entries.
"$ROOT/bin/tmux-agent-hooks" install claude "$TMP/home/.claude/settings.json" "$ROOT/bin"
"$ROOT/bin/tmux-agent-hooks" install codex "$TMP/home/.codex/hooks.json" "$ROOT/bin"

python3 - "$TMP/home/.claude/settings.json" "$TMP/home/.codex/hooks.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as source:
    claude = json.load(source)
with open(sys.argv[2]) as source:
    codex = json.load(source)

def commands(data):
    return [
        handler["command"]
        for groups in data["hooks"].values()
        for group in groups
        for handler in group["hooks"]
    ]

claude_commands = commands(claude)
codex_commands = commands(codex)
assert claude["claudeSetting"] is True
assert codex["codexSetting"] is True
assert claude_commands.count("keep-claude") == 1
assert codex_commands.count("keep-codex") == 1
assert sum("tmux-agent-notify claude" in value for value in claude_commands) == 4
assert sum("tmux-agent-resume claude" in value for value in claude_commands) == 1
assert sum("tmux-agent-cleanup claude" in value for value in claude_commands) == 1
assert sum("tmux-agent-notify codex" in value for value in codex_commands) == 2
assert sum("tmux-agent-resume codex" in value for value in codex_commands) == 1
assert all("tmux-claude-" not in value for value in claude_commands)
assert all("tmux-codex-" not in value for value in codex_commands)
PY

cat >"$TMP/fake-bin/tmux" <<'SH'
#!/bin/sh
echo "$*" >>"$TMUX_LOG"
case "$1 $2 $3" in
    "show-option -gv status-right") printf '#(/old/tmux-claude-status) #(/old/tmux-codex-status) host' ;;
    "show-option -gv status-right-length") printf '40' ;;
    "show-hooks -g ") printf 'after-select-pane[3] run-shell /old/tmux-claude-focus\nafter-select-window[4] run-shell /old/tmux-codex-focus\n' ;;
    "display-message -p -t") printf '/dev/null' ;;
    "display-message -p #{pane_id}") printf '%%current' ;;
    "list-panes -a -F") printf '%%9 work:2\n%%10 other:3\n' ;;
esac
exit 0
SH
chmod +x "$TMP/fake-bin/tmux"

export HOME="$TMP/home"
export CODEX_HOME="$TMP/home/.codex"
export PATH="$TMP/fake-bin:/usr/bin:/bin"
export TMUX_LOG="$TMP/tmux.log"
export TMUX_AGENT_STATE_DIR="$TMP/state"
export TMUX_CLAUDE_STATE_DIR="$TMP/claude-state"
export TMUX_CODEX_STATE_DIR="$TMP/codex-state"

# Start hooks in an actually unlinked directory, not just with a stale PWD.
# Probe their child processes so successful exit codes cannot hide cwd errors.
python3 - "$ROOT" "$TMP" <<'PY'
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

root, tmp = map(Path, sys.argv[1:])
probes = tmp / "cwd-probes"
probes.mkdir()
for command in ("cat", "rm", "tmux"):
    probe = probes / command
    probe.write_text(
        '#!/bin/sh\n'
        '/bin/pwd -P >/dev/null 2>&1 || { echo "INVALID CHILD CWD" >&2; exit 1; }\n'
        f'exec {shlex.quote(shutil.which(command))} "$@"\n'
    )
    probe.chmod(0o755)

env = dict(os.environ, PATH=f"{probes}:{os.environ['PATH']}", TMUX_PANE="%deleted")
for agent in ("claude", "codex"):
    for action in ("notify", "resume", "cleanup"):
        gone = tmp / "deleted-cwd"
        gone.mkdir()
        state = tmp / "state" / f"%deleted.{agent}.waiting"
        other = tmp / "state" / f"%deleted.other.waiting"
        if action != "notify":
            state.touch()
        other.touch()

        def delete_cwd():
            os.chdir(gone)
            os.rmdir(gone)

        result = subprocess.run(
            [str(root / "bin" / f"tmux-agent-{action}"), agent],
            input="{}", text=True, capture_output=True,
            env=dict(env, PWD=str(gone)), preexec_fn=delete_cwd,
        )
        assert result.returncode == 0, result
        assert "INVALID CHILD CWD" not in result.stderr, result.stderr
        assert result.stdout == ("{}\n" if action == "notify" and agent == "codex" else ""), result
        assert state.exists() == (action == "notify"), (action, state)
        assert other.exists()
        state.unlink(missing_ok=True)
        other.unlink()

# A stale PWD variable alone must not redirect a valid relative state path.
relative = tmp / "relative-state"
relative.mkdir()
for action in ("notify", "resume", "cleanup"):
    state = relative / "%deleted.codex.waiting"
    if action != "notify":
        state.touch()
    result = subprocess.run(
        [str(root / "bin" / f"tmux-agent-{action}"), "codex"],
        input="{}", text=True, capture_output=True, cwd=tmp,
        env=dict(env, PWD="/nonexistent-tmux-agent-cwd", TMUX_AGENT_STATE_DIR="relative-state"),
    )
    assert result.returncode == 0, result
    assert state.exists() == (action == "notify"), action
    state.unlink(missing_ok=True)
PY

# Setup must not create harness-owned config directories. In particular, a
# stray ~/.claude directory would block a config manager from restoring its
# symlink. Preflight all selected products before changing either one.
mkdir -p "$TMP/missing-home/.codex"
cat >"$TMP/missing-home/.codex/hooks.json" <<'JSON'
{"keep": true}
JSON
if HOME="$TMP/missing-home" CODEX_HOME="$TMP/missing-home/.codex" \
    "$ROOT/bin/tmux-agent-setup" all >"$TMP/missing.out" 2>&1; then
    fail "setup succeeded without a Claude config directory"
fi
assert_no_path "$TMP/missing-home/.claude"
assert_contains "$(cat "$TMP/missing.out")" "Claude config directory does not exist"
assert_contains "$(cat "$TMP/missing-home/.codex/hooks.json")" '"keep": true'

mkdir -p "$TMP/missing-codex-home/.claude"
if HOME="$TMP/missing-codex-home" CODEX_HOME="$TMP/missing-codex-home/.codex" \
    "$ROOT/bin/tmux-agent-setup" codex >"$TMP/missing-codex.out" 2>&1; then
    fail "setup succeeded without a Codex config directory"
fi
assert_no_path "$TMP/missing-codex-home/.codex"
assert_contains "$(cat "$TMP/missing-codex.out")" "Codex config directory does not exist"

if "$ROOT/bin/tmux-agent-hooks" install claude \
    "$TMP/helper-missing/.claude/settings.json" "$ROOT/bin" \
    >"$TMP/helper-missing.out" 2>&1; then
    fail "hook merger created a missing config directory"
fi
assert_no_path "$TMP/helper-missing"
assert_contains "$(cat "$TMP/helper-missing.out")" "config directory does not exist"

mkdir -p "$TMP/linked-home" "$TMP/managed-claude"
cat >"$TMP/managed-claude/settings.json" <<'JSON'
{"managed": true}
JSON
ln -s "$TMP/managed-claude" "$TMP/linked-home/.claude"
HOME="$TMP/linked-home" \
    TMUX_AGENT_STATE_DIR="$TMP/linked-state" \
    TMUX_CLAUDE_STATE_DIR="$TMP/linked-claude-state" \
    "$ROOT/bin/tmux-agent-setup" claude >/dev/null
[ -L "$TMP/linked-home/.claude" ] || fail "setup replaced managed Claude symlink"
assert_contains "$(cat "$TMP/managed-claude/settings.json")" '"managed": true'
assert_contains "$(cat "$TMP/managed-claude/settings.json")" "tmux-agent-notify claude"

export TMUX_PANE='%9'
claude_output=$(printf '{"hook_event_name":"Stop"}' | "$ROOT/bin/tmux-agent-notify" claude)
[ -z "$claude_output" ] || fail "Claude notify produced output: $claude_output"
assert_file "$TMP/state/%9.claude.waiting"

export TMUX_PANE='%10'
codex_output=$(printf '{"hook_event_name":"Stop"}' | "$ROOT/bin/tmux-agent-notify" codex)
[ "$codex_output" = '{}' ] || fail "Codex Stop hook did not return JSON"
assert_file "$TMP/state/%10.codex.waiting"

tmux_log=$(cat "$TMP/tmux.log")
assert_contains "$tmux_log" "bind-key g"
assert_contains "$tmux_log" "unbind-key G"
assert_contains "$tmux_log" "tmux-agent-status) host"
assert_contains "$tmux_log" "set-hook -gu after-select-pane[3]"
assert_contains "$tmux_log" "set-hook -gu after-select-window[4]"

status=$("$ROOT/bin/tmux-agent-status")
assert_contains "$status" "[Agents waiting: Claude 1, Codex 1]"

rm -f "$TMP/state/%10.codex.waiting"
status=$("$ROOT/bin/tmux-agent-status")
assert_contains "$status" "[Claude waiting]"
touch "$TMP/state/%10.codex.waiting"

# Product-specific resume leaves the other product's state in the same pane.
touch "$TMP/state/%10.claude.waiting"
printf '{}' | "$ROOT/bin/tmux-agent-resume" codex
assert_no_file "$TMP/state/%10.codex.waiting"
assert_file "$TMP/state/%10.claude.waiting"

# Focusing a pane acknowledges every agent wait associated with it.
touch "$TMP/state/%10.codex.waiting"
"$ROOT/bin/tmux-agent-focus" '%10'
assert_no_file "$TMP/state/%10.claude.waiting"
assert_no_file "$TMP/state/%10.codex.waiting"

# The shared queue selects the oldest wait regardless of product.
rm -f "$TMP/state"/*.waiting
touch -t 202601010102 "$TMP/state/%9.codex.waiting"
touch -t 202601010101 "$TMP/state/%10.claude.waiting"
: >"$TMP/tmux.log"
"$ROOT/bin/tmux-agent-jump"
jump_log=$(cat "$TMP/tmux.log")
assert_contains "$jump_log" "select-pane -t %10"
assert_contains "$jump_log" "Claude session waiting"

# Dead panes are discarded and do not hide a later live wait.
rm -f "$TMP/state"/*.waiting
touch -t 202601010100 "$TMP/state/%dead.claude.waiting"
touch -t 202601010101 "$TMP/state/%9.codex.waiting"
: >"$TMP/tmux.log"
"$ROOT/bin/tmux-agent-jump"
assert_no_file "$TMP/state/%dead.claude.waiting"
assert_contains "$(cat "$TMP/tmux.log")" "select-pane -t %9"

# Setup migrates legacy waits with product tags and removes legacy hook names.
rm -f "$TMP/state"/*.waiting
touch -t 202601010101 "$TMP/claude-state/%3.waiting"
touch -t 202601010102 "$TMP/codex-state/%4.waiting"
"$ROOT/bin/tmux-agent-setup" all >/dev/null
assert_file "$TMP/state/%3.claude.waiting"
assert_file "$TMP/state/%4.codex.waiting"
assert_no_file "$TMP/claude-state/%3.waiting"
assert_no_file "$TMP/codex-state/%4.waiting"

# Cleanup is product-specific, and teardown preserves unrelated JSON entries.
export TMUX_PANE='%3'
"$ROOT/bin/tmux-agent-cleanup" claude
assert_no_file "$TMP/state/%3.claude.waiting"
"$ROOT/bin/tmux-agent-teardown" all >/dev/null
assert_no_file "$TMP/state"

python3 - "$TMP/home/.claude/settings.json" "$TMP/home/.codex/hooks.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as source:
    claude = json.load(source)
with open(sys.argv[2]) as source:
    codex = json.load(source)

def commands(data):
    return [
        handler["command"]
        for groups in data["hooks"].values()
        for group in groups
        for handler in group["hooks"]
    ]

assert commands(claude) == ["keep-claude"]
assert commands(codex) == ["keep-codex"]
assert claude["claudeSetting"] is True
assert codex["codexSetting"] is True
PY

assert_contains "$(cat "$TMP/tmux.log")" "unbind-key g"
echo "All tests passed"
