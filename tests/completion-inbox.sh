#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_DIR
python3 - <<'PY'
import os
import fcntl
import pathlib
import pty
import shutil
import shlex
import subprocess
import struct
import tempfile
import threading
import termios
import time

repo = pathlib.Path(os.environ['REPO_DIR'])
real_tmux = shutil.which('tmux')
with tempfile.TemporaryDirectory(prefix='completion-inbox-test-') as tmp:
    root = pathlib.Path(tmp)
    socket = str(root / 'tmux.sock')
    home = root / 'home'
    home.mkdir()
    env = dict(os.environ, HOME=str(home), TERM='xterm-256color')
    env.pop('TMUX', None)
    env.pop('TMUX_PANE', None)
    client = None
    master = slave = None

    def tmux(*args):
        return subprocess.check_output([real_tmux, '-S', socket, *args], env=env, text=True).strip()

    def script(path, *args, pane=None, payload='{}', extra=None):
        e = dict(env, TMUX_PANE=pane or first)
        e.update(extra or {})
        return subprocess.check_output(['bash', str(repo / path), *args], env=e, text=True, input=payload)

    def helper(code, extra=None):
        e = dict(env, STATUS_DIR=str(status), REPO_DIR=str(repo))
        e.update(extra or {})
        return subprocess.check_output(['bash', '-euc', 'source "$REPO_DIR/scripts/lib/completion-inbox.sh"; ' + code], env=e, text=True)

    def rows():
        return [line.split('\t') for line in helper('completion_inbox_rows').splitlines()]

    def complete(pane, hook='codex-hook.sh'):
        script('hooks/' + hook, 'UserPromptSubmit', pane=pane)
        script('hooks/' + hook, 'Stop', pane=pane)

    def record_files():
        return list(status.glob('completions/*/*.unread'))

    def focus(pane):
        tmux('select-pane', '-t', pane)
        script('scripts/sidebar-signal.sh', 'refresh')

    try:
        tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'alpha', '-x', '100', '-y', '35', 'sleep 180')
        first = tmux('display-message', '-p', '-t', 'alpha', '#{pane_id}')
        second = tmux('split-window', '-d', '-t', first, '-P', '-F', '#{pane_id}', 'sleep 180')
        third = tmux('split-window', '-d', '-t', first, '-P', '-F', '#{pane_id}', 'sleep 180')
        server = tmux('display-message', '-p', '#{pid}')
        env['TMUX'] = f'{socket},{server},0'
        status = home / '.cache/tmux-agent-status'
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 35, 100, 0, 0))
        client_env = dict(env)
        client_env.pop('TMUX', None)
        client = subprocess.Popen([real_tmux, '-S', socket, 'attach-session', '-t', 'alpha'],
                                  stdin=slave, stdout=slave, stderr=slave, env=client_env)
        def drain():
            try:
                while os.read(master, 65536):
                    pass
            except OSError:
                pass
        threading.Thread(target=drain, daemon=True).start()
        for _ in range(100):
            if tmux('list-clients', '-F', '#{pane_id}') == first:
                break
            time.sleep(.02)
        else:
            raise AssertionError('isolated tmux client did not attach')

        # Startup and completions observed in the active pane are already read.
        script('hooks/codex-hook.sh', 'SessionStart', pane=second)
        assert not rows()
        complete(first)
        assert not rows()

        # Each supported agent records a real transition, never an idle reminder
        # or repeated Stop. Marking read leaves live status intact.
        for hook in ('better-hook.sh', 'codex-hook.sh', 'devin-hook.sh'):
            complete(second, hook)
            assert [r[1] for r in rows()] == [second], (hook, rows())
            before = record_files()
            script('hooks/' + hook, 'Stop', pane=second)
            assert record_files() == before
            script('scripts/hook-based-switcher.sh', '--mark-read', f'alpha:{second}', 'C')
            assert not rows()
            assert (status / 'panes' / f'alpha_{second}.status').read_text().strip() == 'done'
            script('hooks/' + hook, 'Stop', pane=second)
            assert not rows(), 'duplicate Stop must not recreate a read entry'

        script('hooks/better-hook.sh', 'UserPromptSubmit', pane=second)
        script('hooks/better-hook.sh', 'Stop', pane=second,
               payload='{"background_tasks":[{"status":"running"}]}')
        assert not rows(), 'background work is not a completion'
        script('hooks/better-hook.sh', 'Stop', pane=second)
        assert len(rows()) == 1

        # State may change again without erasing unread history. Repeated new
        # completions coalesce to one entry per pane.
        script('hooks/better-hook.sh', 'UserPromptSubmit', pane=second)
        assert len(rows()) == 1
        script('hooks/better-hook.sh', 'Stop', pane=second)
        assert len(record_files()) == 1
        complete(third)
        assert len(rows()) == 2

        # Fresh collector processes and either popup view preserve history.
        for _ in range(2):
            script('scripts/sidebar-collector.sh', '--once')
            assert 'G|RECENTLY READY|' in (status / '.sidebar-cache').read_text()
            assert len(rows()) == 2
        for mode in ('--rows-tree', '--rows-agents'):
            output = script('scripts/hook-based-switcher.sh', mode)
            assert f'C\talpha:{second}\t' in output
            assert f'C\talpha:{third}\t' in output
        (status / '.sidebar-mode').write_text('agents')
        script('scripts/sidebar-collector.sh', '--once')
        assert 'G|RECENTLY READY|' in (status / '.sidebar-cache').read_text()

        # Deferral hides, but does not acknowledge, either pane or session scope.
        parked = status / 'parked' / f'alpha_{second}.parked'
        parked.touch()
        assert [r[1] for r in rows()] == [third]
        assert len(record_files()) == 2
        parked.unlink()
        waiting = status / 'wait' / 'alpha.wait'
        waiting.write_text(str(int(time.time()) + 1000))
        assert not rows() and len(record_files()) == 2
        waiting.unlink()
        assert len(rows()) == 2

        # Next-ready prioritizes unread work. Other focus changes acknowledge
        # only the visited pane, using an actual attached tmux client.
        next_pane = rows()[0][1]
        script('scripts/next-done-project.sh')
        assert tmux('list-clients', '-F', '#{pane_id}') == next_pane
        assert len(rows()) == 1
        focus(rows()[0][1])
        assert not rows()
        focus(first)

        # The plugin's actual focus hook acknowledges ordinary tmux navigation;
        # no explicit call from the switcher or collector is required.
        complete(second)
        signal = 'env HOME=' + shlex.quote(str(home)) + ' bash ' + shlex.quote(str(repo / 'scripts/sidebar-signal.sh')) + ' refresh'
        tmux('set-hook', '-g', 'after-select-pane', 'run-shell -b ' + shlex.quote(signal))
        tmux('select-pane', '-t', second)
        for _ in range(100):
            if not record_files():
                break
            time.sleep(.02)
        else:
            raise AssertionError('tmux focus hook did not acknowledge completion')
        tmux('set-hook', '-gu', 'after-select-pane')
        focus(first)

        # Explicit window/session acknowledgement includes all child panes,
        # including non-current windows, but never changes their live states.
        other_window = tmux('new-window', '-d', '-t', 'alpha', '-P', '-F', '#{pane_id}', 'sleep 180')
        complete(second)
        complete(other_window)
        window_index = tmux('display-message', '-p', '-t', second, '#{window_index}')
        script('scripts/hook-based-switcher.sh', '--mark-read', f'alpha:w{window_index}', 'P')
        assert [r[1] for r in rows()] == [other_window]
        script('scripts/hook-based-switcher.sh', '--mark-read', 'alpha', 'S')
        assert not rows()
        assert (status / 'panes' / f'alpha_{other_window}.status').read_text().strip() == 'done'
        tmux('kill-window', '-t', other_window)

        # A pane in another window/session is attributed to its own session.
        remote = tmux('new-session', '-d', '-s', 'beta', '-P', '-F', '#{pane_id}', 'sleep 180')
        complete(remote)
        assert rows()[0][2] == 'beta'
        tmux('rename-session', '-t', 'beta', 'renamed')
        assert rows()[0][2] == 'renamed'
        helper('source "$REPO_DIR/scripts/lib/selection-targets.sh"; selection_switch_client "renamed:$TARGET" C', {'TARGET': remote})
        assert not rows(), 'selecting a completion must acknowledge its actual pane'
        tmux('switch-client', '-t', 'alpha')
        focus(first)

        tmux('set-option', '-g', '@agent-completion-inbox', 'off')
        complete(second)
        assert not rows() and not record_files()
        tmux('set-option', '-g', '@agent-completion-inbox', 'on')
        complete(second)
        assert len(rows()) == 1
        assert not helper('completion_inbox_rows', {'TMUX': f'{socket},999999999,0'}).strip()
        assert len(rows()) == 1, 'another server must not consume these records'

        # An acknowledgement snapshot must not delete an event arriving while
        # focus is queried. Override just that query to force the interleaving.
        helper('''
completion_inbox_init
record=("$COMPLETION_DIR/$TARGET."*.unread)
tmux() {
    if [ "$1" = list-clients ]; then
        cat "${record[0]}" > "$COMPLETION_DIR/$TARGET.later.unread"
        printf '%s\\n' "$TARGET"
    else
        command tmux "$@"
    fi
}
completion_ack_active
[ -f "$COMPLETION_DIR/$TARGET.later.unread" ]
''', {'TARGET': second})
        assert len(rows()) == 1

        # Reused pane identifiers/processes and closed panes cannot retain
        # jump targets pointing to unrelated work.
        f = record_files()[0]
        fields = f.read_text().split('\t')
        fields[1] = '999999999'
        f.write_text('\t'.join(fields))
        assert not rows() and not record_files()
        complete(second)
        tmux('kill-pane', '-t', second)
        assert not rows() and not record_files()

        # The persistent sidebar actually renders the section, lets keyboard
        # navigation reach it, and acknowledges its selected row without a jump.
        complete(third)
        script('scripts/sidebar-collector.sh', '--once')
        launch = 'env HOME=' + shlex.quote(str(home)) + ' bash ' + shlex.quote(str(repo / 'scripts/sidebar.sh'))
        sidebar = tmux('split-window', '-h', '-b', '-f', '-l', '45', '-t', first, '-P', '-F', '#{pane_id}', launch)
        for _ in range(150):
            if 'RECENTLY READY' in tmux('capture-pane', '-p', '-t', sidebar):
                break
            time.sleep(.02)
        else:
            raise AssertionError('sidebar did not render unread completions: ' + repr(tmux('capture-pane', '-p', '-t', sidebar)) + '\ncache: ' + (status / '.sidebar-cache').read_text())
        tmux('send-keys', '-t', sidebar, *(['k'] * 12), 'a')
        for _ in range(100):
            if not record_files():
                break
            time.sleep(.02)
        else:
            raise AssertionError('sidebar keyboard acknowledgement failed')
        assert (status / 'panes' / f'alpha_{third}.status').read_text().strip() == 'done'
        print('Persistent completion inbox lifecycle, UI, focus and race checks passed')
    finally:
        subprocess.run([real_tmux, '-S', socket, 'kill-server'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if client:
            client.wait(timeout=5)
        for fd in (master, slave):
            if fd is not None:
                os.close(fd)
PY
