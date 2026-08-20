---
title: Install
description: Download the app, open an unnotarized build, or build from source.
---

## Download

Grab the [latest release](https://github.com/boringterminal/boringterminal/releases/latest)
from GitHub. It is a universal build (Apple silicon and Intel) for
**macOS 13 and later**.

Drag `Boring Terminal.app` into `/Applications`.

## First launch

Releases are ad-hoc signed and not yet notarized, so Gatekeeper refuses a
plain double-click the first time. Any one of these paths works; macOS
remembers the decision and subsequent launches are normal.

**macOS 13 and 14:** Control-click **Boring Terminal** in Finder, choose
**Open**, then confirm in the dialog.

**macOS 15 and later:** the Control-click shortcut no longer exists for
unnotarized apps. Double-click the app once and dismiss the warning, then
open **System Settings › Privacy & Security**, scroll to the Security
section, and click **Open Anyway**.

**From a terminal**, on any version: clear the quarantine flag, then launch
normally.

```sh
xattr -dr com.apple.quarantine "/Applications/Boring Terminal.app"
```

## Build from source

You need [Zig](https://ziglang.org) 0.16.0 and the macOS SDK (installed with
Xcode or the Command Line Tools).

```sh
git clone https://github.com/boringterminal/boringterminal
cd boringterminal
zig build run
```

Run the tests the same way:

```sh
zig build test      # unit tests
zig build esctest   # VT conformance suite
```

The VT core is checked against the independent esctest2 terminal conformance
suite on every change.
