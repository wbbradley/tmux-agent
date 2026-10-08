#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/tmux-agent-jump-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/bin" "$TMP/state"
REAL_TMUX=$(command -v tmux || true)

cat >"$TMP/bin/tmux" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$TMUX_LOG"
case "$1" in
    display-message) [ "${2:-}" != -p ] || printf '%%current\n' ;;
    list-panes) printf '%%9 work:2\n' ;;
    list-windows) printf '%s\n' "${TEST_WINDOWS:-}" ;;
esac
exit 0
SH
chmod +x "$TMP/bin/tmux"

export PATH="$TMP/bin:$PATH"
export TMUX_LOG="$TMP/tmux.log"
export TMUX_AGENT_STATE_DIR="$TMP/state"
# tmux session IDs contain a literal dollar sign.
# shellcheck disable=SC2016
export TEST_WINDOWS='$0:@1 0
$0:@2 1
$0:@3 1'

python3 - "$ROOT" "$TMP" <<'PY'
import os
from pathlib import Path
import subprocess
import sys

root, tmp = map(Path, sys.argv[1:])
state, log = tmp / 'state', tmp / 'tmux.log'

def jump(windows=None):
    log.write_text('')
    env = dict(os.environ)
    if windows is not None:
        env['TEST_WINDOWS'] = windows
    subprocess.run([str(root / 'bin/tmux-agent-jump')], env=env, check=True)
    return log.read_text()

# An empty queue still visits the first highlighted tab using stable IDs.
output = jump()
assert 'select-window -t $0:@2\n' in output, output
assert 'Window bell (no agent wait recorded)' in output, output
assert 'select-pane' not in output, output

# Recorded waits take priority over bells.
wait = state / '%9.codex.waiting'
wait.touch()
output = jump()
assert 'select-pane -t %9\n' in output, output
assert 'Codex session waiting' in output, output
assert 'list-windows' not in output, output
wait.unlink()

# Dead entries are removed before trying the bell fallback.
dead = state / '%dead.claude.waiting'
dead.touch()
output = jump()
assert not dead.exists()
assert 'select-window -t $0:@2\n' in output, output

# Acknowledging the current pane can empty the queue without hiding bells.
current = state / '%current.claude.waiting'
current.touch()
output = jump()
assert not current.exists()
assert 'select-window -t $0:@2\n' in output, output

# Activity flags and ordinary windows are not bell alerts.
output = jump('$0:@1 0\n$0:@2 0')
assert 'No agent sessions waiting or window bells' in output, output
assert 'select-window' not in output, output
output = jump('')
assert 'No agent sessions waiting or window bells' in output, output
PY

# Check the original mismatch and alert acknowledgement against a real server.
if [ -n "$REAL_TMUX" ]; then
    python3 - "$ROOT" "$TMP" "$REAL_TMUX" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import time

root, tmp = map(Path, sys.argv[1:3])
binary = sys.argv[3]
socket = str(tmp / 'socket')

def tmux(*args):
    return subprocess.check_output([binary, '-S', socket, *args], text=True).strip()

try:
    tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'test', 'sleep 120')
    tmux('new-window', '-d', '-t', 'test', 'sleep 120')
    target = tmux('display-message', '-p', '-t', 'test:1', '#{pane_id}')
    current = tmux('display-message', '-p', '-t', 'test:0', '#{pane_id}')
    env = dict(os.environ, PATH=str(Path(binary).parent) + ':' + os.environ['PATH'],
               TMUX=socket + ',0,0', TMUX_PANE=target,
               TMUX_AGENT_STATE_DIR=str(tmp / 'real-state'))
    subprocess.run([str(root / 'bin/tmux-agent-notify'), 'codex'], input='{}',
                   text=True, capture_output=True, check=True, env=env)
    for _ in range(100):
        if tmux('display-message', '-p', '-t', 'test:1', '#{window_bell_flag}') == '1':
            break
        time.sleep(.02)
    else:
        raise AssertionError('notification did not set the bell flag')
    subprocess.run([str(root / 'bin/tmux-agent-resume'), 'codex'], input='{}',
                   text=True, check=True, env=env)
    assert not list((tmp / 'real-state').glob('*.waiting'))
    assert tmux('display-message', '-p', '-t', 'test:1', '#{window_bell_flag}') == '1'

    subprocess.run([str(root / 'bin/tmux-agent-jump')], check=True,
                   env=dict(env, TMUX_PANE=current))
    assert tmux('display-message', '-p', '-t', 'test', '#{window_index}') == '1'
    assert tmux('display-message', '-p', '-t', 'test:1', '#{window_bell_flag}') == '0'
finally:
    subprocess.run([binary, '-S', socket, 'kill-server'], capture_output=True)
PY
fi

echo "Jump tests passed"
