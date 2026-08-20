# Supported escape sequences — the working checklist

Working inventory for RFC 0002. Status: ☐ todo / ☑ done / ✖ deliberately
unsupported (consumed + ignored). Keep this file updated as sequences land —
it is the implementation dashboard. Authority for each entry: ctlseqs
(https://invisible-island.net/xterm/ctlseqs/ctlseqs.html) unless noted.

## C0

☑ BEL (0x07 → bell action) · BS · HT · LF · VT · FF (as LF) · CR · SO/SI
(GL shift between G0/G1)

## ESC

☑ `ESC 7`/`ESC 8` DECSC/DECRC (save/restore cursor+attrs+origin+wrap+charsets)
☑ `ESC D` IND · `ESC E` NEL · `ESC M` RI (reverse index; scrolls at top margin)
☑ `ESC H` HTS
☑ `ESC c` RIS (full reset)
☑ `ESC =`/`ESC >` DECKPAM/DECKPNM (stored; keypad encoding not yet used)
☑ `ESC # 8` DECALN
☑ Charset designation `ESC ( 0` etc.: *only* DEC Special Graphics
  (`ESC ( 0` line-drawing → Unicode box chars); all other G0–G3 designations
  consumed+ignored. Legacy NRCS is dead; line-drawing is not (ncurses uses it).

## CSI — cursor & editing

☑ CUU/CUD/CUF/CUB (A B C D) · CNL/CPL (E F) · CHA (G) · CUP/HVP (H f) ·
VPA (d) · CHT/CBT (I Z) · HPA (`)
☑ ED (J: 0/1/2; 3 = clear scrollback only, esctest-verified) · EL (K)
☑ ICH (@) · DCH (P) · ECH (X) · IL (L) · DL (M) · SU (S) · SD (T)
☑ REP (b — repeat last graphic char; fish emits it)
☑ DECSTBM (r — top/bottom margins; homes cursor)
☑ TBC (g)
☑ DECSTR (! p — soft reset; DECAWM-on choice pending lookup, see terminal.zig TODO)
☑ DECSCUSR (SP q — consumed; block-only rendering in iteration 0)
☑ DECRQCRA (* y) — xterm-334 checksum behavior used by esctest
☑ XTWINOPS (t): report-only subset (14/16 host-backed pixel+cell size reports,
  18 grid size);
  ✖ never act on move/resize/iconify requests

## CSI — reports

☑ DA1 (`CSI c` → `CSI ? 6 c`, plain VT102 for now) · DA2 (`CSI > c`)
☑ DSR 5 (status ok) · DSR 6 CPR (origin-mode-aware)
☑ DECRQM (`CSI Pm $ p` / `CSI ? Pm $ p`) — ANSI and DEC requests preserve
  their marker; every stored mode reports authoritative set/reset state,
  deliberately fixed modes report permanent state, and one-shot/unknown modes
  report unrecognized
☑ XTVERSION (`CSI > q` / `CSI > 0 q` →
  `DCS > | boringterminal 0.4.0 ST`)

## SGR (CSI m)

☑ 0 reset · 1 bold · 2 dim · 3 italic · 4 underline (+ 4:0..4:5 styles:
straight/double/curly/dotted/dashed) · 5 blink (render as-is or steady —
decide; store regardless) · 7 reverse · 8 invisible · 9 strikethrough ·
21..29 resets · 30–37/40–47 · 90–97/100–107 bright · 38/48 (both `;` and `:`
forms, 2=RGB 5=indexed) · 39/49 defaults · 58/59 underline color

## DEC private modes (DECSET/DECRST, `CSI ? Pm h/l`)

☑ 1 DECCKM cursor keys · 6 DECOM origin mode · 7 DECAWM autowrap (real
pending-wrap) · 25 DECTCEM (12 blink consumed)
☑ 1049 alt screen (+ 47/1047/1048 legacy forms) · ☑ 2004 bracketed paste
  (semantic viewer request; daemon-authoritative framing, control filtering,
  and atomic queue admission per RFC 0005) ·
☑ 1004 focus reporting (`CSI I`/`CSI O` on real selected+key-window
  transitions; DECRQM reports the mode)
☑ Mouse: independent 1000/1002/1003 tracking plus legacy/1006 SGR encoding;
  press/release, held/any motion, and vertical/horizontal wheel reports
  (✖ 1005 UTF-8 encoding — obsolete and ambiguous; ✖ 1015 urxvt encoding —
  xterm documents it as not recommended and inferior to 1006;
  ☑ 1016 SGR-pixels (pane-local physical backing pixels; xterm-compatible
  one-based SGR reports and mutually exclusive format selection))
☑ 2026 synchronized output (BSU/ESU hold the last frame until ESU; repeated
  BSU re-arms a one-second watchdog; resize releases the hold)
☑ 2027 grapheme clustering (zg UAX #29 segmentation, bounded suffix storage,
  presentation-driven width changes; see unicode-width.md)
✖ 47/1047 without save-cursor nuances beyond compat aliasing · ✖ DECCOLM
  (mode 3, 80/132 col) — consume, ignore, exclude in esctest with reason

## OSC

☑ 0/1/2 title (→ Action.set_title)
☐ 4 palette set/query · ☑ 10/11/12 fg/bg/cursor color query (`?` form;
  replies preserve BEL/ST and report the renderer's effective colors) ·
  ☐ 10/11/12 setters
☑ 7 cwd report (bounded URI action; daemon validates local `file://` URLs,
  feeds session metadata and new-session inheritance; RFC 0020)
☑ 8 semantic hyperlinks (printable bounded URI + `id=` identity; retained
  with cells; Command-hover/Command-click in the native viewer; RFC 0018)
◐ 22 pointer shape (daemon-retained `text`/`default`/`pointer`/`crosshair`
  plus xterm aliases; empty/unknown reset to text; full CSS cursor-name set is
  a future explicit dialect, RFC 0002)
☑ 9 notification (iTerm2 style; `9;4;...` progress is not notification) ·
☑ 777 notify (urxvt/foot style;
  `777;notify;title;body`)
☐ 52 clipboard (write allowed; read behind config opt-in — security)
☑ 133 semantic prompt A/B/C/D (+ `D;exit_code`) → PromptMark actions;
  the attention engine (RFC 0006) is built on this
✖ 1337 (iTerm2 proprietary multiplex) — ignore
✖ 50 (font) — ignore

## DCS

☑ DECRQSS (`DCS $ q ... ST`; bounded truthful SGR and DECSTBM reports;
  unsupported settings receive the standard invalid reply) · ☑ XTGETTCAP
  (`DCS + q ... ST`; bounded hex-name parser and truthful
  identity/color/supported-input table; shared key constants) ·
  ✖ XTSETTCAP (terminal identity/input mutation) · ✖ sixel (RFC 0000 cut list)

## APC

◐ Kitty graphics (`APC G ... ST`; spec pinned 2026-08-19) — phase 1 covers
  bounded APC parsing, direct RGB/RGBA query and transfer, zlib/base64 chunks,
  cursor placement with `C=1`, ids, `d=A/I`, scrolling/clearing, bounded
  daemon resources, version-4 snapshots, and a Metal RGBA texture pass.
  Phase 2a covers POSIX shared-memory (`t=s`) RGB/RGBA transport, bounded
  `S`/`O` ranges, and unlink-after-read ownership. Phase 2b makes snapshots
  descriptor-only with generation-keyed viewer/Metal caches. Phase 2c covers
  regular and safely cleaned-up temporary-file (`t=f/t`) transport. Phase 2d
  covers PNG (`f=100`) over every medium, including optional outer zlib.
  Phase 2e covers retained-resource puts, image numbers, named and anonymous
  placements, source rectangles, pixel offsets, cell scaling/aspect ratio,
  cursor movement, all deletion selectors, and the three z-order strata.
  Phase 2f covers `U=1` virtual prototypes, U+10EEEE grid placeholders, the
  pinned 297-entry row/column diacritic mapping and inheritance rules,
  foreground/underline-color image and placement ids, aspect-preserving
  cell-derived Metal quads, and virtual-specific deletion semantics. The
  captured terminal-browser v0.5.4 stream is the first gate. Phase 2g covers
  relative placement graphs (`P/Q/H/V`), virtual parents, cascade lifetime,
  eight-edge depth, and transient usage hints (`N`). Phase 3 covers frame
  loading/editing (`a=f`), animation control (`a=a`), frame composition
  (`a=c`), frame deletion (`d=f/F`), daemon-owned monotonic scheduling, and
  generation-safe viewer staging. Full published-protocol compliance remains
  the target; Kitty source is GPLv3 and must not be ported.

## Keyboard encoding (output side of `vt`)

☑ (partial) Legacy encodings: arrows/home/end per DECCKM, pgup/pgdn,
  insert/forward-delete, F1–F12, standard functional-key modifiers, ⌃ combos.
  ☐ Option-as-ESC-prefix configuration (macOS: only when config maps
  option→meta; otherwise ⌥ composes text — per-side configurable like iTerm)
☑ Kitty keyboard protocol (spec pinned 2026-08-19:
  https://sw.kovidgoyal.net/kitty/keyboard-protocol/): progressive
  enhancement query/set/push/pop with bounded per-screen (main/alt) stacks.
  Phase 1 implements flags 1 (disambiguate) and 2 (event types). Phase 2 adds
  flags 4 (shifted/base-layout alternates), 8 (all keys, including modifier
  transitions), and 16 (associated Unicode text), plus the macOS-applicable
  F1–F20 and distinct numeric-keypad table, through one bounded native key/text
  transaction encoded by the authoritative daemon. Modern TUIs
  negotiate this; agents benefit (proper shift+enter, ctrl+enter
  disambiguation).

## Rules for this file

- A sequence is ☑ only with tests.
- Adding a ✖ requires a reason inline.
- Meeting an unlisted sequence in the wild: look it up (prior-art.md lookup
  ritual), add it here with a status, then decide.
