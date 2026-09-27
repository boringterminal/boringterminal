#!/usr/bin/env python3
"""Fail if the daemon's repository import closure reaches viewer/test codecs.

Conservative: scan imports inside test blocks too. External Unicode modules
are explicitly named below and checked against build.zig's daemon module.
This is a source dependency gate, not a stripped-symbol heuristic.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
external = {"DisplayWidth", "Graphemes", "CaselessMatch"}
build = (root / "build.zig").read_text()
configured = set(re.findall(r'daemon_mod\.addImport\("([^"]+)"', build))
if configured != external:
    raise SystemExit(f"Review changed daemon module imports: {configured}")

pending = [root / "src/daemon_main.zig"]
visited = set()
while pending:
    path = pending.pop().resolve()
    if path in visited:
        continue
    visited.add(path)
    relative = path.relative_to(root).as_posix()
    if "/daemon_protocol/" in relative or "/test_support/" in relative or relative.endswith("daemon_client.zig"):
        raise SystemExit(f"Daemon reaches viewer/test codec: {relative}")
    source = path.read_text()
    # Reject dynamic import expressions rather than silently missing an edge.
    imports = re.findall(r'@import\(\s*"([^"\\]+)"\s*\)', source)
    if len(imports) != len(re.findall(r'@import\s*\(', source)):
        raise SystemExit(f"Review nonliteral import in {relative}")
    for name in imports:
        if name in {"std", "builtin", "root"} | external:
            continue
        if not name.endswith(".zig"):
            raise SystemExit(f"Review unrecognized module {name} in {relative}")
        pending.append(path.parent / name)
print(f"Daemon import closure: {len(visited)} repository files; no viewer/test codecs")
