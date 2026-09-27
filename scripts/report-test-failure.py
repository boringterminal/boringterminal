#!/usr/bin/env python3
"""Expose a bounded Zig test failure excerpt in the workflow check annotation."""
from pathlib import Path
import sys

path = Path(sys.argv[1])
if path.exists():
    lines = path.read_text(errors="replace").splitlines()
    # Link commands can span thousands of characters and hide the actual error.
    excerpt = "\n".join(line for line in lines[:160] if len(line) < 1000)[:12000]
    escaped = excerpt.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print("::error title=Unit and integration test diagnostics::" + escaped)
