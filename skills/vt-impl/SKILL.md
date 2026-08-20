---
name: vt-impl
description: Use when implementing or debugging anything in the VT core — escape sequences, parser states, grid/cursor semantics, modes, OSC handling, wide chars, wrap behavior, or when terminal output renders wrong (misaligned TUI, cursor drift, garbage on screen). Routes to the specs, oracles, and reference implementations; enforces the no-guessing rule.
---

# VT implementation discipline

You are working on Boring Terminal's VT core. The cardinal rule: **never resolve a
behavior question by intuition — the answer exists; find it.** Every
sequence's correct behavior is documented, implemented by a reference
terminal, or empirically observable.

## Before writing code

1. Read the relevant RFC first: `docs/rfcs/0002-vt-core.md` (parser/semantics),
   `docs/rfcs/0003-grid-scrollback.md` (grid/storage/reflow). If your change
   contradicts an RFC, stop and update the RFC in the same change or flag it.
2. Check `docs/references/escape-sequences.md` — the working checklist. Is
   this sequence listed? What's its status? A ✖ has a reason; don't
   implement it without revisiting the reason.

## The lookup ritual (in order — from docs/references/prior-art.md)

1. **ctlseqs** (https://invisible-island.net/xterm/ctlseqs/ctlseqs.html) —
   what the sequence is, xterm's behavior.
2. **terminalguide.namepad.de** — do terminals disagree; what do apps expect.
3. **Ghostty source** (`~/Projects/reference/ghostty/src/terminal/`) —
   `Terminal.zig` inline tests are an edge-case encyclopedia; grep the
   sequence mnemonic. Zig, same idioms as ours. MIT — porting logic with
   attribution is allowed.
4. **Alacritty** (`~/Projects/reference/alacritty/alacritty_terminal/src/`) —
   `git blame` weird special cases; blame messages link issues explaining why.
5. **Empirical**: run the exact bytes in Ghostty/xterm and observe; use
   `tools/vtdiff` (byte file → our grid as text) to compare.

If reference checkouts are missing, clone them (commands in
docs/references/prior-art.md). **Never port code from kitty — GPLv3.** Its
protocol *docs* are fair game as specs.

## Parser vs. semantics

Parser questions (state transitions, param collection, string termination,
cancellation) → `docs/references/vt-parser-state-machine.md`; the spec is
https://vt100.net/emu/dec_ansi_parser and deviations from it are listed
there. If our parser disagrees with both alacritty/vte and Ghostty's
Parser.zig on an input, we are wrong.

Semantics minefields with dedicated lore:
- **Pending wrap** (last-column autowrap state): most-botched behavior in
  new terminals — see the pending-wrap section of
  `docs/references/conformance-testing.md`; test against xterm.
- **Width/graphemes/emoji/VS16**: policy is fixed in
  `docs/references/unicode-width.md` — implement the policy, don't relitigate
  it. Never call libc wcwidth.
- **Margins/origin mode/DECOM**: CPR reports are origin-relative; cursor
  clamping differs inside/outside margins. vttest menu 1/2 is the oracle.

## Definition of done for a sequence

- Unit test lands with it (chunk-split variant too: the sequence fed one
  byte per `feed()` call must behave identically).
- `docs/references/escape-sequences.md` status updated.
- If it's a mode: DECRQM reports it honestly.
- If esctest covers it: test moves onto the ratchet pass-list
  (see /conformance skill).
- Purity holds: no I/O in `vt`; effects leave via the Action list only
  (`docs/rfcs/0001-architecture.md`).

## When output "looks corrupted"

1. Capture the byte stream (script(1) / tee — recipes in
   docs/references/conformance-testing.md) and reduce it to a minimal
   fixture with vtdiff.
2. Replay in Ghostty: if Ghostty shows the same "corruption", the app is
   wrong or the behavior is correct — not our bug.
3. The minimal fixture goes into `tests/corpus/` regardless of verdict.
