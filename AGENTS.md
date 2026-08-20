# Boring Terminal

A macOS-only, Metal-only terminal: a session switchboard for agents. Zig +
hand-written objc; own VT emulator and Metal renderer. Mac-native input,
vertical session sidebar, attention routing via standard escape sequences,
session daemon, control socket. Nothing else.

**Start here: `docs/rfcs/0000-vision.md`** — the one-line test there governs
scope. Architecture and the purity rule: `docs/rfcs/0001-architecture.md`.

## Docs map

- `docs/rfcs/` — design decisions (see its README for the index and status
  conventions). Implementation that contradicts an accepted RFC is a bug in
  one of them; fix in the same change.
- `docs/references/` — implementation lore: parser spec, conformance
  workflow, prior-art map with licensing rules, escape-sequence checklist
  (the working dashboard), unicode-width policy, IME field notes, PTY notes.

## Skills

Canonical location: `skills/` (agent-agnostic SKILL.md format; `.claude/skills`
is a symlink to it — add equivalent symlinks for other agents' discovery paths
rather than copying). If your harness doesn't auto-load skills, read the
relevant SKILL.md before starting matching work:

- **skills/vt-impl** — before touching parser/sequences/grid semantics, or
  when terminal output renders wrong.
- **skills/conformance** — for esctest/vttest/corpus/fuzz work or triaging
  test failures.
- **skills/unstuck** — when blocked; maps every subsystem to its prior art
  and oracle.
- **skills/release-boring-terminal** — for version bumps, release preparation,
  tag publication, GitHub Actions monitoring, or release audits.
- **skills/rotate-daemon-compat** — before rotating, deleting, or auditing the
  retained public daemon-protocol compatibility capsules and skew fixtures.

## Hard rules

- Spec before code: any non-trivial behavior change (presentation/timing
  semantics, new subsystem behavior, protocol surface) lands with a new RFC
  or an amendment to the owning RFC — written first, not retrofitted.
- If the local, ignored `LOOP.md` exists, keep it current as the handoff
  dashboard (state, next, blockers). Update it at session end and after
  milestone-sized commits, but never commit it.

- `src/vt/` is pure: no I/O, no time, no AppKit/Metal; effects leave via
  the Action list. Every bug in it must reproduce from a byte stream.
- Never resolve terminal-behavior questions by intuition — use the lookup
  ritual in `docs/references/prior-art.md`.
- Never port code from kitty (GPLv3). Ghostty/Alacritty/WezTerm/xterm: yes,
  with attribution.
- The esctest ratchet only grows; exclusions require written reasons.
- Unknown escape sequences are consumed and ignored, never printed.
- `docs/references/escape-sequences.md` statuses stay current with the code.
