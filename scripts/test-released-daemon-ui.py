#!/usr/bin/env python3
"""Replace a tagged app bundle while its daemon owns a live shell.

Requires a current app built with -Drecovery-ui-smoke=true and an unmodified
tagged app. Uses only disposable HOME/bundle paths; keeps logs for inspection.
"""
import argparse
import os
from pathlib import Path
import shutil
import signal
import socket
import struct
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('--old-app', required=True)
parser.add_argument('--dialect', type=int, choices=(18, 19), required=True)
parser.add_argument('--new-app', default='zig-out/recovery-ui-smoke/Boring Terminal.app')
args = parser.parse_args()
home = Path(tempfile.mkdtemp(prefix='bt-gui-skew-', dir='/tmp'))
bundle = home / 'Boring Terminal.app'
support = home / 'Library/Application Support/boringterminal'
address = str(support / 'daemon.sock')
env = dict(os.environ, HOME=str(home), ZDOTDIR=str(home), TMPDIR=str(home), SHELL='/bin/sh')
print(f'Released-daemon UI artifacts: {home}', flush=True)
processes = []


def wait_for(condition, seconds=45):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.05)
    raise TimeoutError('fixture condition timed out')


def peer():
    with socket.socket(socket.AF_UNIX) as connection:
        connection.connect(address)
        return struct.unpack('i', connection.getsockopt(0, 2, 4))[0]


def receive(connection, length):
    result = b''
    while len(result) < length:
        chunk = connection.recv(length - len(result))
        if not chunk:
            raise EOFError('daemon disconnected')
        result += chunk
    return result


def request(connection, tag, payload):
    connection.sendall(struct.pack('<4sHHI', b'BTD1', args.dialect, tag, len(payload)) + payload)
    magic, version, reply, size = struct.unpack('<4sHHI', receive(connection, 12))
    assert magic == b'BTD1' and version == args.dialect
    data = receive(connection, size)
    assert reply != 65, data
    return reply, data


def launch_viewer(expected, log):
    process = subprocess.Popen([str(bundle / 'Contents/MacOS/boringterminal')],
                               env=dict(env, BT_UI_SKEW_EXPECTED=str(expected)),
                               stdout=log, stderr=log)
    processes.append(process)
    return process


try:
    shutil.copytree(args.old_app, bundle)
    with (home / 'daemon.log').open('wb') as log:
        daemon = subprocess.Popen([str(bundle / 'Contents/MacOS/boringterminald')],
                                  env=env, stdout=log, stderr=log)
        processes.append(daemon)
    wait_for(lambda: Path(address).exists())
    assert peer() == daemon.pid
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5)
        connection.connect(address)
        reply, data = request(connection, 2, struct.pack('<HHB', 80, 24, 0))
        assert reply == 67
        session_id = struct.unpack('<Q', data[:8])[0]
        command = b'printf "%s" $$ > "$HOME/child-before.pid"; printf "LEGACY_PERSISTED_%s\\n" OUTPUT\n'
        assert request(connection, 4, struct.pack('<QI', session_id, len(command)) + command)[0] == 64
    wait_for(lambda: (home / 'child-before.pid').exists() and (home / 'child-before.pid').stat().st_size > 0)
    child_pid = int((home / 'child-before.pid').read_text())
    os.kill(child_pid, 0)
    # The running old executable survives replacement of its bundle path.
    bundle.rename(home / 'Previous.app')
    shutil.copytree(args.new_app, bundle)
    with (home / 'viewer-legacy.log').open('wb') as log:
        viewer = launch_viewer(args.dialect, log)
        wait_for(lambda: (home / 'skew-live-success').exists() or viewer.poll() is not None)
        assert (home / 'skew-live-success').exists(), 'see viewer-legacy.log'
        assert peer() == daemon.pid, 'live old daemon was replaced'
        assert int((home / 'child-after.pid').read_text()) == child_pid
        os.kill(child_pid, 0)
        (home / 'allow-close').touch()
        assert viewer.wait(timeout=15) == 0
    wait_for(lambda: daemon.poll() is not None)
    with (home / 'viewer-current.log').open('wb') as log:
        viewer = launch_viewer(20, log)
        assert viewer.wait(timeout=45) == 0
    assert (home / 'skew-current-success').exists()
    assert peer() != daemon.pid
    print(f'dialect {args.dialect}: same daemon/child PID, retained output, new input, pending menu, idle upgrade to 20: passed', flush=True)
finally:
    for process in reversed(processes):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    try:
        os.kill(peer(), signal.SIGKILL)
    except OSError:
        pass
