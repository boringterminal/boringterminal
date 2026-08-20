---
name: conformance
description: Use when running or wiring up terminal conformance/regression testing — esctest, vttest, vtebench, the replay corpus, fuzzing, or the CI ratchet — and when an esctest failure needs triage. Also use before claiming any VT milestone is "done".
---

# Conformance testing workflow

Full background: `docs/references/conformance-testing.md`. This skill is the
operational half.

## Ground rules

- Progress is measured by the **ratchet**: a checked-in pass-list of esctest
  tests we pass. CI fails on regression AND on passing tests missing from
  the list. Never delete from the pass-list to make CI green — a regression
  is a bug to fix now.
- Excluding an esctest case requires an inline reason in the exclusion list
  (e.g. "assumes 8-bit C1 input; we are UTF-8-only per RFC 0002"). An
  exclusion without a reason is itself a bug.
- **esctest cannot verify anything until DECRQCRA is implemented** (it
  checks screen contents via rectangle checksums). If DECRQCRA isn't done
  yet, that is the current task — nothing else in esctest matters before it.
  Match xterm's checksum variant; esctest has flags for known variants —
  read its README/--help rather than guessing flag names.

## Sources

- esctest: iTerm2 repo `tests/esctest` (https://gitlab.com/gnachman/iterm2);
  Thomas Dickey maintains a fork — vendor whichever runs cleanest under
  `tests/vendor/esctest/`.
- vttest: `brew install vttest` (interactive; milestone-gate checklist, not
  CI).
- vtebench: https://github.com/alacritty/vtebench (throughput regression
  only; we do not chase benchmark numbers — RFC 0000).

## Triaging an esctest failure

1. Re-run just that test with maximum logging; capture the byte stream it
   sent and the checksum/position it expected.
2. Reduce to a byte fixture; run through `tools/vtdiff` to see our grid.
3. Determine expected behavior via the lookup ritual (see the vt-impl skill /
   docs/references/prior-art.md) — ctlseqs → terminalguide → Ghostty tests →
   empirical xterm.
4. Verdict is one of exactly three:
   a. **Our bug** → fix in `vt`, add the unit test that would have caught
      it, add fixture to `tests/corpus/`, add test to the pass-list.
   b. **Deliberate deviation** → exclusion list with written reason.
   c. **esctest assumes an xterm quirk we don't claim** → same as (b), but
      double-check terminalguide first; "esctest is wrong" is rare.
5. Never verdict (b)/(c) just because the fix is hard.

## Replay corpus

`tests/corpus/`: captured real-world sessions (vim, htop, Claude Code run,
cargo build, big rg dump). A corpus test asserts the final grid snapshot +
action log byte-for-byte. Capture recipes are in
docs/references/conformance-testing.md. When any interesting bug is fixed,
its minimal fixture joins the corpus — the corpus only grows.

## Fuzzing invariants

Random bytes + random chunk splits + interleaved resizes must never violate:
no crash, no hang, cursor in bounds, wide-char head/tail pairing intact,
wrap flags consistent, parser reachable back to ground via CAN. A fuzz crash
reproduces deterministically from its byte input (vt is pure — RFC 0001);
minimize it and add it to the corpus like any fixture.
