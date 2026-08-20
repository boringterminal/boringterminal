# RFC 0001: Architecture — three libraries and a shell

Status: accepted

## Layout

```
boringterminal/
  src/
    vt/        # pure VT emulator: parser + terminal state machine. Zero I/O,
               # zero AppKit, zero Metal. The crown jewel; outlives the app.
    grid/      # screen/scrollback storage (may live inside vt/; split only
               # if the boundary proves real). See RFC 0003.
    render/    # Repository-owned Metal renderer. See RFC 0004.
    shell/     # AppKit: NSWindow, CAMetalLayer, NSTextInputClient, event
               # loop, PTY plumbing, session daemon client. See RFC 0005/0006.
    cli/       # the `term` binary speaking the control socket. See RFC 0007.
  docs/
    rfcs/        # design decisions
    references/  # implementation lore for humans and agents
  skills/        # agent skills (open SKILL.md format) routing into
                 # docs/references; .claude/skills symlinks here, other
                 # agents' discovery paths symlink likewise
  AGENTS.md      # canonical agent instructions; CLAUDE.md is a symlink
```

Language: Zig throughout, with hand-written objc bindings. No package-manager
dependencies for the core; a Unicode data library (zg) and build-time-generated
tables are the expected exceptions.

## The purity rule (load-bearing)

`vt` is a pure state machine:

- **Input:** bytes (plus explicit events: resize, focus, paste).
- **Output:** mutations to its own state + an `Action` list for the host
  (ring bell, set title, OSC 52 clipboard write, notification, DA/DSR/DECRQM
  query responses to write back to the PTY, ...).
- **Forbidden inside `vt`:** syscalls, allocator surprises, time, randomness,
  anything AppKit/Metal. The host owns the PTY fd; `vt` never sees it —
  query responses come out as actions, the host writes them.

Consequences we are buying with this rule:

- **Testable headless:** the conformance suite runs `vt` without a window.
- **Fuzzable:** feed random bytes; must never crash or hang.
- **Replayable:** a captured byte stream deterministically reproduces any bug.
  `vt` must support snapshot + replay from day one (this is the debugging
  story for "agent output corrupted my screen" bugs).
- **Frame = f(state):** the renderer reads a consistent snapshot of grid state
  and draws it. No rendering logic in `vt`, no terminal logic in `render`.

## Threading model

Keep it boring:

- One reader per session: kqueue-driven PTY reads feed that session's `vt`
  (sessions are independent; parsing parallelizes across sessions for free,
  never within one).
- Renderer runs on the main/display-link thread, reads grid snapshots under a
  brief lock (or double-buffered damage regions — decide in RFC 0004).
- Never block a PTY reader on rendering; coalesce: many PTY reads may produce
  one frame, and idle sessions cost ~zero GPU (damage-driven redraw).

## Testing strategy

- `vt`: esctest/vttest conformance (docs/references/conformance-testing.md),
  ratcheted in CI; unit tests per sequence; fuzzing; replay corpus of captured
  real-world streams (vim session, Claude Code session, htop, `cargo build`).
- `grid`: property tests for reflow (resize to random widths and back;
  content and cursor invariants hold).
- `render`: golden-image tests — render a known grid state, compare pixels.
  Determinism makes this cheap.
- `shell`: thin by design; manual test checklist for IME/keyboard
  (docs/references/macos-ime.md has the checklist).

## Rejected alternatives (recorded)

- **gpui + alacritty_terminal:** two large cross-platform dependencies moving
  at other projects' pace; discards our renderer; contradicts mac-only/minimal.
  Rejected 2026-08.
- **libghostty-vt as the emulation core:** viable fallback if own-VT stalls,
  but the VT core is where correctness lives and we want to own it.
- **Swift for the shell:** would work, but one language + hand-written objc
  keeps the build trivial and the binary small. Revisit only if
  NSTextInputClient via objc proves genuinely painful.
