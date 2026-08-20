# RFC 0008: Iteration 0 — glass teletype

Status: accepted

## Goal

A real window running your shell, end to end: PTY → own VT parser → grid →
Metal renderer. Exit criteria:

1. `zig build run` opens a window with a zsh login-shell prompt.
2. Typing echoes; `ls -la` (colors), `clear`, resize, and a TUI (htop/vim)
   are usable — not perfect, usable.
3. OSC 0/2 sets the window title; BEL beeps (the product thesis, proven in
   iteration 0).
4. `zig build test` runs the vt/pty suite green; every landed sequence has a
   test; the chunk-split rule (byte-at-a-time == one-shot) is enforced
   suite-wide.
5. `zig build vtdiff` builds the byte-stream → grid-text debug tool
   (RFC-mandated debugging story: bugs reproduce from bytes).

## Scope — in

**Parser** (full Williams machine, RFC 0002 / vt-parser-state-machine.md):
all 14 states, comptime-built transition table, anywhere rules (CAN/SUB/ESC),
`;`+`:` params (capped 32), OSC capped 64 KiB, DCS parsed-and-discarded,
UTF-8 decoded in front (invalid → U+FFFD).

**Semantics** (RFC 0002 stages 1–2, subset):
- C0: BEL BS HT LF VT FF CR (SO/SI consumed)
- ESC: DECSC/DECRC, IND NEL RI, HTS, RIS, DECALN, DECKPAM/DECKPNM (stored),
  charset designation with DEC Special Graphics translation (`ESC ( 0`)
- CSI: CUU CUD CUF CUB CNL CPL CHA CUP HVP VPA ED EL ICH DCH ECH IL DL
  SU SD REP CHT CBT TBC DECSTBM DECSTR, DA1 (`CSI ? 6 c`), DSR 5/6 (CPR
  origin-aware), SGR (bold dim italic underline reverse hidden strike;
  16/256/truecolor via `;` and `:` forms; 39/49; 21–29 resets)
- Modes (DECSET/DECRST): 1 DECCKM, 6 DECOM, 7 DECAWM (real pending-wrap
  semantics from day one), 25 DECTCEM, 47/1047/1048/1049 alt screen,
  2004 bracketed paste. Mouse modes consumed-and-stored, not reported.
- OSC: 0/1/2 title action; everything else consumed.
- Tab stops every 8, HTS/TBC.

**Grid**: primary + alt screens, flat cell array. Cell = codepoint, flags
(bold/dim/italic/underline/reverse/hidden/strike/wide/wide-spacer), fg/bg
(default | indexed | rgb). Wide chars via range-based width stub (CJK,
Hangul, fullwidth, emoji blocks — placeholder until unicode-width.md policy
lands). Resize clips/pads (no reflow). **No scrollback** — milestone 3.

**Actions** (purity per RFC 0001): bell, set_title, pty_write (DA/DSR
replies). Host drains after each feed.

**PTY**: openpty + login_tty + user's login shell; TERM=xterm-256color,
COLORTERM=truecolor, TERM_PROGRAM=boringterminal. Blocking-read thread feeds the
locked terminal, marks dirty, pokes the main queue (dispatch_async_f).
Resize → TIOCSWINSZ. Child EOF → "[exited]" in title, window stays.

**Renderer** (RFC 0004, minimal): repository-owned
objc/metal/atlas/rasterization code, trimmed for the cell-grid path. SF Mono via
`monospacedSystemFontOfSize:weight:`; glyphs by codepoint→UTF-16→
`CTFontGetGlyphsForCharacters`, per-codepoint fallback font via
`CTFontCreateForString`, gray-only atlas. Three draws per frame: bg quads →
glyph quads → decoration quads (underline/strike/cursor handled across
passes; block cursor = quad, glyph over it in bg color). Whole-frame
redraw on dirty flag; no per-row damage yet. One shared instance buffer,
`waitUntilCompleted` per frame (single in-flight — simple over fast,
measured later).

**Shell**: bare-binary NSApplication (Regular activation policy), one
window, CAMetalLayer-backed NSView. Keyboard: ⌘ shortcuts first (⌘Q, ⌘W,
⌘V paste — bracketed-paste aware), specials by keyCode (arrows
DECCKM-aware, Home/End/PgUp/PgDn/Del/Tab/Esc/Return, Backspace→0x7F,
⌃-letter → control byte), everything else through `interpretKeyEvents:` →
NSTextInputClient (full method set stubbed honestly, `insertText:` real —
dead keys work; IME composes invisibly: committed text arrives, pre-edit
isn't rendered yet). Live resize snaps grid + winsize together.

## Scope — out (deliberate, with the iteration that owns it)

- Scrollback, search, selection/copy, reflow → milestone 3
- OSC 133/8/9/52, sidebar, sessions, daemon, control socket → milestone 4–5
- Marked-text rendering, kitty keyboard protocol, mouse reporting,
  DECRQM/DECRQCRA/esctest harness, focus reporting → milestone 2
- Color emoji (gray-atlas silhouettes for now), ligatures (never),
  combining marks (dropped; width stub documents it)
- Config file (hardcoded dark theme + SF Mono 13), multiple windows

DECRQCRA/esctest deferral is accepted consciously: iteration 0's suite is
our own; the conformance ratchet is the *first* task of iteration 1.

## Layout

```
build.zig
src/main.zig          # NSApplication bootstrap, wiring
src/vt.zig            # module root (parser, terminal, utf8, color)
src/vt/{parser,terminal,utf8,color}.zig
src/shell/{pty,window,input}.zig
src/render/{objc,metal,font,atlas,renderer,shaders}.zig   # objc/metal/atlas
src/tools/vtdiff.zig
```

Tests live as `test` blocks in vt/pty files; `zig build test` builds a
headless module (no AppKit dependency in the test root). Every terminal
semantic test runs through a helper that feeds the byte stream twice —
whole and byte-at-a-time — and asserts identical snapshots (grid text dump
+ cursor + actions).

## Known debts recorded

- Input latency tied to dispatch coalescing + `waitUntilCompleted`;
  measure before optimizing (RFC 0004 stance).
- The original giant-paste blocking write was retired by RFC 0012's bounded,
  nonblocking daemon input queue.
- Width stub diverges from unicode-width.md policy; replace, don't extend.
