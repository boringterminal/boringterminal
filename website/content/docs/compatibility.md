---
title: Compatibility
description: The protocol surface: what the emulator supports, what it declines, and what is next.
---

Boring Terminal ships its own VT emulator, checked against the independent
esctest2 conformance suite in CI (102 tests passing; every exclusion has a
written reason). Sessions run with `TERM=xterm-256color` and truecolor.

This page is the honest summary. If it isn't listed as supported, assume it
isn't; unknown sequences are consumed and ignored, never printed.

## Supported

**Core VT.** The full cursor/editing CSI set, scroll regions, tab stops,
alt screen (1049 and friends), origin/autowrap modes, `ED 3` scrollback clear,
DEC Special Graphics line drawing, DECSTR/RIS resets.

**Styling.** Full SGR: truecolor and indexed color in both `;` and `:` forms,
underline styles 4:0–4:5 with underline color (58/59), bold/faint/italic/
inverse/strikethrough.

**Keyboard.** The **Kitty keyboard protocol**, all five progressive-enhancement
flags, with per-screen push/pop stacks, plus standard xterm encodings,
bracketed paste (2004), and focus reporting (1004).

**Graphics.** The **Kitty graphics protocol**: direct, shared-memory, and file
transports; PNG and zlib; placements including Unicode placeholders; z-order;
deletion; animation. This is how images and video render inline.

**Mouse.** Click (1000), drag (1002), and motion (1003) tracking with SGR
(1006) and SGR-pixels (1016) encodings, including horizontal scroll.

**OSC.** Titles (0/2), working directory (7), hyperlinks (8), notifications
(9 and 777), semantic prompts (133 with exit codes), color queries (10/11/12).

**Queries.** Truthful DA1/DA2, DSR, DECRQM, DECRQSS, XTGETTCAP, XTVERSION,
and the report-only XTWINOPS subset. Synchronized output (2026) and grapheme
clustering (2027) are supported and reported honestly.

## Not yet

- **OSC 52** clipboard access
- **OSC 4** palette and OSC 10/11/12 color **setters** (queries work)
- Option-as-Meta (⌥ composes text today)
- Cursor shapes other than block (DECSCUSR is parsed and ignored)

## Never

Declined deliberately; see the [philosophy](/docs/philosophy/):

- **Sixel** and iTerm2 inline images: Kitty graphics is the one media
  protocol
- Legacy mouse encodings 1005/1015 (SGR has superseded them)
- 132-column mode (DECCOLM), NRCS character sets
- Window resize/move/iconify requests via XTWINOPS: apps don't get to move
  your windows
