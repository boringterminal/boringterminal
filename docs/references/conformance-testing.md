# Conformance testing

The correctness strategy: oracles already exist. We never argue about
behavior from memory — we check the suite, the spec, or a reference terminal.

## esctest — the automated workhorse

- Origin: George Nachman (iTerm2); Thomas Dickey maintains the living
  fork, esctest2 (https://github.com/ThomasDickey/esctest2) — vendored
  under `tests/vendor/esctest2/`. The harness is `zig build esctest`,
  which runs esctest with its tty on a PTY bridged to our headless vt
  (`src/tools/esctest_host.zig`): bytes esctest writes go into the
  parser, vt's pty_write actions (DECRQCRA reports etc.) go back.
- Python; drives the terminal through a PTY, then **verifies screen contents
  via DECRQCRA (rectangle checksum, `CSI Pid ; Pp ; Pt ; Pl ; Pb ; Pr * y`)**.
- ⚠️ **Consequence: implement DECRQCRA early** (RFC 0002 sequencing). Until
  the terminal answers checksum queries, esctest cannot verify anything.
  DECRQCRA itself is small: checksum a rectangle of the grid, reply via DCS.
  Match xterm's checksum algorithm (esctest has flags for known variants —
  read its README/args rather than guessing).
- Run it headless against `vt` + a PTY harness — no window needed (RFC 0001
  purity pays off here). CI runs a curated pass-list: start with the tests we
  pass, **ratchet**: a fixed test joins the list forever; CI fails on any
  regression *or* on passing tests missing from the list (so the list stays
  honest and progress is visible in diffs).
- Expect some esctest cases to encode xterm quirks we deliberately don't
  match (e.g. anything assuming 8-bit C1 input). Maintain an exclusion list
  *with a reason per entry* — an exclusion without a written reason is a bug.
- The fixed ratchet includes the DECRQSS SGR and DECSTBM cases. Other DECRQSS
  names remain outside it until their underlying terminal setting exists;
  returning the standard invalid response is the truthful product behavior.

## vttest — the interactive classic

- Thomas Dickey, https://invisible-island.net/vttest/ (`brew install vttest`).
- Menu-driven, eyeball-verified. Use for: cursor movement (menu 1), screen
  features (menu 2), origin/margins, wrap behavior — the subtle DECAWM
  last-column ("pending wrap") semantics that automated suites cover thinly.
- Not CI; a milestone gate. Record a checklist run at milestone 2 and 3.

## Pending wrap deserves its own paragraph

The last-column autowrap state ("cursor visually at col N but logically
pending-wrap") is the single most commonly botched behavior in new
terminals. Which operations clear pending-wrap (CR, cursor movement, ...)
and which don't is lore; when in doubt test xterm empirically and read
Ghostty's `Terminal.zig` tests, which encode it exhaustively.

## Empirical oracle: diff against a reference terminal

When a spec is ambiguous, ask xterm (the behavioral gold standard) or
Ghostty:

```sh
# capture what a real app emits (replay corpus material):
script -r /tmp/session.rec   # macOS script(1) records with timing
# or: tee raw bytes through: socat - EXEC:'zsh',pty,setsid,ctty | tee raw.bin

# then feed identical bytes to xterm/ghostty and to our vt harness,
# and compare final screen text (their DECRQCRA / our snapshot).
```

Build a tiny `tools/vtdiff` early: takes a byte file, runs it through our
`vt` and prints the grid as text — diffable against expected fixtures. Every
esctest failure investigated becomes a byte-file fixture in-repo.

## Replay corpus

`tests/corpus/`: captured real sessions — vim editing, htop, Claude Code
doing a long task, `cargo build` with colors, a giant `rg` dump, fish with
right-prompt. Regression = corpus replay produces identical final grid
snapshot + action log. Cheap to run, catches semantic regressions the unit
tests don't anticipate.

## Kitty keyboard corpus

The keyboard protocol has a dedicated source-independent corpus at
`tests/kitty-keyboard/`; its case schema and provenance rules are documented
in that directory's README. Run its exact pass ratchet with
`zig build kitty-keyboard-conformance`; `zig build test`, CI, and release
validation also depend on it. The hermetic runner exercises Boring Terminal's
production negotiation, native normalizer, encoder, current codec,
attach-dialect, and raw-PTY paths and does not install or execute Kitty. The
optional opaque GUI oracle remains a manual release tool.

## Performance oracle

- **vtebench** (https://github.com/alacritty/vtebench) — terminal throughput
  benchmarks (huge outputs, scrolling, dense SGR). Run against milestone 2+
  for regressions; we don't chase leaderboard numbers (RFC 0000), we prevent
  cliffs.
- Latency: measure keypress→pixel (Typometer methodology) before believing
  or attempting any latency optimization.

## Fuzzing

`zig` fuzz target over `vt.feed()`: random bytes + random chunk splits +
random interleaved resizes. Invariants: no crash, no hang, cursor always in
bounds, grid invariants hold (wide-char head/tail pairing, wrap flags
consistent). Run continuously in CI (short budget) and longer locally.
