#!/usr/bin/env python3
"""Run an app built with -Drecovery-ui-smoke=true in a disposable HOME.

The app clicks real native controls and captures its own views. This driver
simulates abrupt daemon loss using only the peer of the fixture's Unix socket.
Screenshots and logs remain in the printed temporary directory for review.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument("--app", default="zig-out/Boring Terminal.app/Contents/MacOS/boringterminal")
parser.add_argument("--capacity", action="store_true", help="Exercise 1,024 saved sessions plus the fresh shell")
args = parser.parse_args()
home = Path(tempfile.mkdtemp(prefix="bt-gui-", dir="/tmp"))
support = home / "Library/Application Support/boringterminal"
support.mkdir(parents=True, mode=0o700)
checkpoint = support / "recovery.json"
checkpoint.write_text(json.dumps({
    "format_version": 1, "revision": 1, "owner_epoch": 42,
    "pending_generation": 0,
    "current": {
        "entries": [
            {"id": 101, "title": "Project shell", "cwd": str(home)},
            {"id": 102, "title": "Missing folder", "cwd": str(home / "missing")},
            {"id": 103, "title": "Background tab", "cwd": str(home)},
        ],
        "items": [{"left": 101, "right": 102, "focus_right": True, "zoomed": True}, {"left": 103}],
        "selected": 102,
    }, "pending": {},
}))
checkpoint.chmod(0o600)
if args.capacity:
    state = json.loads(checkpoint.read_text())
    state["current"] = {
        "entries": [{"id": i + 1, "title": "Old agent title", "cwd": str(home)} for i in range(1024)],
        "items": [{"left": i + 1} for i in range(1024)],
        "selected": 1,
    }
    checkpoint.write_text(json.dumps(state))
env = os.environ.copy()
env.update(HOME=str(home), ZDOTDIR=str(home), TMPDIR=str(home))
if args.capacity:
    env["BT_UI_CAPACITY"] = "1"
peers = set()


def fixture_peer():
    with socket.socket(socket.AF_UNIX) as connection:
        connection.connect(str(support / "daemon.sock"))
        # Darwin SOL_LOCAL / LOCAL_PEERPID; never search processes by name.
        pid = struct.unpack("i", connection.getsockopt(0, 2, 4))[0]
        if pid <= 1:
            raise RuntimeError("Invalid fixture peer")
        peers.add(pid)
        return pid


print(f"Recovery UI artifacts: {home}", flush=True)
with (home / "viewer.log").open("wb") as log:
    process = subprocess.Popen([str(Path(args.app).resolve())], cwd=home, env=env,
                               stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    killed = False
    try:
        deadline = time.monotonic() + 75
        while process.poll() is None and time.monotonic() < deadline:
            try:
                pid = fixture_peer()
                if not killed and (home / "ready-for-daemon-loss").exists():
                    state = json.loads(checkpoint.read_text())
                    if len(state["current"]["entries"]) == 4:
                        os.kill(pid, signal.SIGKILL)
                        killed = True
            except (OSError, ValueError):
                pass  # startup/reconnect can leave a temporarily stale socket
            time.sleep(0.1)
        if process.poll() is None:
            raise RuntimeError("Native UI smoke timed out")
        if process.returncode != 0 or not (home / "smoke-success").exists():
            raise RuntimeError(f"Native smoke failed ({process.returncode}): {(home / 'viewer.log').read_text()}")
        print((home / "smoke-success").read_text(), end="")
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        try:
            # Only the currently connected fixture peer is signalled, avoiding
            # PID reuse from a daemon already killed earlier in the test.
            os.kill(fixture_peer(), signal.SIGKILL)
        except OSError:
            pass
