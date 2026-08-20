# RFCs

Design documents for Boring Terminal. One RFC per subsystem or decision. RFCs are living
documents until their subsystem ships, then they freeze into a record of why
things are the way they are.

## Status values

- **draft** — direction agreed, details open
- **accepted** — implement against this
- **shipped** — implemented; edit only to correct the record
- **superseded** — points to its replacement

## Index

| RFC | Title | Status |
|-----|-------|--------|
| [0000](0000-vision.md) | Vision and product principles | accepted |
| [0001](0001-architecture.md) | Architecture: three libraries and a shell | accepted |
| [0002](0002-vt-core.md) | The VT core: parser and terminal state machine | draft |
| [0003](0003-grid-scrollback.md) | Grid storage, scrollback, and reflow | shipped |
| [0004](0004-renderer.md) | Metal renderer | draft |
| [0005](0005-macos-shell.md) | macOS shell: window, input, IME, PTY | draft |
| [0006](0006-sessions-attention.md) | Sessions, attention routing, and the daemon | accepted |
| [0007](0007-control-socket.md) | Control socket and CLI | draft |
| [0008](0008-iteration-0.md) | Iteration 0 — glass teletype | shipped |
| [0009](0009-live-resize.md) | Live resize — real-time re-layout | shipped |
| [0010](0010-selection.md) | Selection and copy | shipped |
| [0011](0011-macos-app-bundle.md) | macOS application bundle and identity | accepted |
| [0012](0012-daemon-attach-protocol.md) | Daemon ownership and viewer attach protocol | shipped |
| [0013](0013-terminal-fidelity.md) | Terminal fidelity and agent graphics | draft |
| [0014](0014-paired-sessions.md) | Paired sessions: a bounded two-up view | accepted |
| [0015](0015-shared-graphics-transport.md) | Shared graphics transport across the daemon boundary | accepted |
| [0016](0016-search.md) | Terminal and cross-session search | accepted |
| [0017](0017-native-search-bar.md) | Reusable native search bar | accepted |
| [0018](0018-osc8-hyperlinks.md) | OSC 8 semantic hyperlinks | shipped |
| [0019](0019-daemon-upgrades.md) | Daemon upgrades without stranded sessions | accepted |
| [0020](0020-osc7-working-directory.md) | OSC 7 working-directory reports | accepted |
| [0021](0021-website.md) | Website and documentation site | accepted |
| [0022](0022-transient-graphics-materialization.md) | Transient graphics materialization | draft |
| [0023](0023-frame-pipelined-graphics-uploads.md) | Frame-pipelined graphics uploads | accepted |

## Conventions

- Record rejected alternatives and *why* — the rationale is the point.
- When implementation contradicts an RFC, fix one of them in the same change.
- New sizable decisions get a new RFC, not a silent edit to an accepted one.
