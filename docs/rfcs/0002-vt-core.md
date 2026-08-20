# RFC 0002: The VT core — parser and terminal state machine

Status: draft

## Shape

Two layers, strictly separated:

1. **Parser** — the DEC ANSI state machine (Paul Williams,
   https://vt100.net/emu/dec_ansi_parser). Byte-table-driven, no heap
   allocation, no knowledge of what sequences *mean*. Emits parser actions
   (`print`, `execute`, `csi_dispatch`, `osc_end`, ...) to a handler.
   Details and the full state/action inventory:
   docs/references/vt-parser-state-machine.md.
2. **Terminal** — the semantics: grid mutations, modes, charsets, tab stops,
   margins, cursor discipline. Implements the handler interface. This is where
   the years of edge cases live; the parser is a solved problem.

```zig
pub const Terminal = struct {
    pub fn init(alloc, cols, rows) Terminal
    pub fn feed(self, bytes: []const u8) void   // may push Actions
    pub fn resize(self, cols, rows) void
    pub fn drainActions(self) []Action           // host-owned effects
    // read-side for the renderer: a consistent snapshot view of the grid
};

pub const Action = union(enum) {
    bell,
    set_title: []const u8,          // OSC 0/2
    notify: Notification,           // OSC 9 / 777
    hyperlink handled in-grid,      // OSC 8 attaches to cells, not an Action
    clipboard_set: ClipboardSet,    // OSC 52
    pty_write: []const u8,          // DA1/DA2, DSR, DECRQM, DECRQCRA replies
    prompt_mark: PromptMark,        // OSC 133 A/B/C/D -> session state
    color_query_reply: ...,         // OSC 10/11 etc.
};
```

`pty_write` as an action (instead of `vt` owning the fd) is what keeps the
core pure and replayable — see RFC 0001.

## Dynamic color queries (amended 2026-08-16)

OSC 10, 11, and 12 are part of the TUI compatibility surface, not optional
theme decoration. Applications use OSC 11 in particular to choose a dark or
light presentation. Ignoring the query can therefore change an application's
layout and colors even when SGR and background-color erasure are correct.

- Accept BEL and ST terminated `OSC Ps;?`, where `Ps` is 10 (default
  foreground), 11 (default background), or 12 (cursor color).
- Reply with the same code and terminator in the xterm form
  `OSC Ps;rgb:rrrr/gggg/bbbb terminator`. Each 8-bit configured channel is
  expanded to 16 bits by duplication (`ab` becomes `abab`).
- The returned colors are the effective colors used by the renderer. They
  must come from one shared terminal/theme value; duplicating hardcoded reply
  strings beside renderer constants is forbidden.
- Query handling remains pure and replayable. The resulting bytes leave via
  `Action.pty_write`; the VT core never writes the PTY itself.
- Setting dynamic colors is a separate behavior change. Until specified, a
  non-query OSC 10/11/12 is consumed and ignored.

This follows xterm's dynamic-color query contract. The first regression
fixture is Codex choosing the same composer presentation here as it does in
Alacritty. See RFC 0013.

## Terminal identity query (amended 2026-08-16)

XTVERSION is a capability reply, not a window or shell effect. Accept both
the omitted and explicit-zero forms, `CSI > q` and `CSI > 0 q`, and reply in
xterm's 7-bit form:

```text
DCS >|boringterminal 0.5.0 ST
```

The semantic version comes from the same compile-time product constant used
for the child's `TERM_PROGRAM_VERSION`; these two identity surfaces must not
drift. The bundle's release version is kept equal to that constant. Nonzero
or multi-parameter `CSI > ... q` requests and other `CSI ... q` forms are
consumed without a reply. The response remains a pure `Action.pty_write`.

## Terminfo capability queries (amended 2026-08-16)

XTGETTCAP is accepted in xterm's 7-bit form, `DCS + q Pt ST`. `Pt` is a
semicolon-separated list of capability names encoded as two hexadecimal
digits per byte. Hexadecimal input is case-insensitive; replies use uppercase.
The parser collects at most 4096 DCS payload bytes and dispatches the completed
string through its standard hook/put/unhook boundary. An overflowed, cancelled,
or malformed DCS is consumed without a reply.

A successful request receives one xterm-form response containing the supported
name/value pairs in request order:

```text
DCS 1 + r hex-name = hex-value [ ; hex-name = hex-value ... ] ST
```

An empty request, malformed hex, or first unsupported name receives
`DCS 0 + r ST`. An unsupported name after one or more supported names ends
processing and returns the successful prefix, matching xterm's documented
list semantics. No terminal database or filesystem access occurs in `vt`.

The initial table is deliberately truthful rather than a copy of every entry
in `xterm-256color`: `TN=xterm-256color`, `Co/colors=256`, `RGB=8`, and only
the special-key strings that Boring Terminal actually emits (arrows,
Home/End, Page Up/Down, forward Delete, Backspace, and their termcap aliases),
plus the implemented mouse introducer. The input encoder and XTGETTCAP share
these constants so advertised strings cannot drift from emitted input. General
output capabilities and unimplemented function keys are not claimed.

The response remains a pure `Action.pty_write`. XTSETTCAP is consumed and
ignored: applications cannot mutate Boring Terminal's identity or input
contract through an escape sequence.

## Status-string queries (amended 2026-08-19)

DECRQSS is accepted in its 7-bit VT420/xterm form, `DCS $ q Pt ST`, with no
parameters before `$q`. The existing parser-owned 4096-byte DCS cap applies:
an overflowed or cancelled string is consumed without dispatch. A recognized
setting receives `DCS 1 $ r Ps ST`, where `Ps` is the complete current CSI
setting without its introducer. An unrecognized or currently unsupported
setting receives `DCS 0 $ r ST`. A malformed DCS envelope is consumed without
a reply.

The initial truthful surface is:

- `m` (SGR): report a leading reset (`0`) followed by every active rendition
  that Boring Terminal stores, in stable order: intensity, italic, underline,
  reverse, invisible, strike, foreground, background, and underline color.
  Palette colors use the ordinary 30–37/90–97 and 40–47/100–107 forms where
  available, otherwise the implemented indexed or RGB extended-color form.
- `r` (DECSTBM): report the authoritative one-based top and bottom margins.

Requests such as DECSCUSR, DECSLRM, and DECSCA remain invalid until Boring
Terminal implements and retains their corresponding setting. DECRQSS must not
fabricate state merely because xterm recognizes a request name. Replies are
built in a fixed 160-byte buffer before one bounded `Action.pty_write`; the VT
core performs no I/O. Whole-stream and byte-split tests cover success, failure,
and recovery, and the SGR/DECSTBM esctest cases join the ratchet.

## Focus reporting (amended 2026-08-16)

DEC private mode 1004 is reset by default, set/reset by DECSET/DECRST, reset
by RIS, and reported honestly through DECRQM. While it is set, a real logical
focus transition produces xterm's three-byte reports: `CSI I` when the
session gains focus and `CSI O` when it loses focus. Enabling the mode does
not synthesize an immediate report, and repeated notification of the same
focus state produces no duplicate bytes.

The host defines a session as focused only when it is selected in a key
Boring Terminal window. A selected-session change in a key window therefore
reports loss to the old session and gain to the new one; window resign/key,
viewer detach, and reattach map to the corresponding real transitions. The
daemon consults mode 1004 under the session's VT lock and queues reports
through its bounded terminal-event path. AppKit never inspects or implements
the escape-sequence semantics itself.

## Mouse tracking and encoding (amended 2026-08-19)

Mouse tracking and mouse encoding are independent state. DECSET 1000, 1002,
and 1003 select mutually exclusive normal, button-motion, and any-motion
tracking respectively; resetting the active selector disables tracking.
DECSET/DECRST 1006 and 1016 select mutually exclusive SGR cell and SGR pixel
coordinate formats; legacy X10 is the reset state. All five modes default
reset, reset under RIS, and report their actual state through DECRQM. Setting
one tracking mode makes the other two report reset. Resetting an inactive
tracking or coordinate-format selector does not disable the active selector.

The host passes semantic events with both a zero-based cell and a zero-based
pane-local backing-pixel position, plus button and Shift/Option/Control
modifiers, into the daemon. Backing pixels are the same physical pixel space
reported through XTWINOPS and the PTY winsize, not AppKit points. The daemon
consults the authoritative modes under the VT lock and encodes:

- press/release in 1000, 1002, and 1003;
- motion with a held button in 1002 and 1003, and motion without a held
  button only in 1003;
- vertical and horizontal wheel steps as buttons 4–7, with no release.

Button codes are 0/1/2 for left/middle/right, plus 4/8/16 for
Shift/Meta(macOS Option)/Control; motion adds 32 and wheel adds 64. Legacy
output is `CSI M Cb Cx Cy`, with each value offset by 32, release reported as
button 3, and events outside its 223×223 zero-based range dropped. SGR output
is `CSI < Cb ; Cx ; Cy M`, using `m` only for button release and unbounded
decimal one-based cell coordinates. These are xterm's
1000/1002/1003/1006 contracts. SGR-pixels uses the same response shape and
button/release rules, substituting unbounded decimal one-based physical pixel
coordinates. The content area's top-left backing pixel is therefore `1;1`.
Pixel motion is not cell-deduplicated.

Mode 1005 is deliberately unsupported because its UTF-8 byte encoding is
obsolete and ambiguous. Mode 1015 is deliberately unsupported because xterm
itself documents the urxvt form as not recommended and inferior to 1006.
Both are consumed and reported permanently reset (`4`): they are known
coordinate-format selectors whose obsolete encodings this terminal will not
enable.

No mouse event is sent while the primary viewport is inspecting scrollback.
The event is queued as ordinary bounded viewer input so its order relative to
keys and paste is preserved. The pure encoder performs no I/O.

## Mode reports (amended 2026-08-19)

`CSI Pm $ p` and `CSI ? Pm $ p` receive ANSI and DEC DECRPM replies with the
same private marker as the request. Every mutable SM/RM or DECSET/DECRST mode
Boring Terminal implements reports set (`1`) or reset (`2`) from authoritative
state. A deliberately fixed-reset mode reports permanently reset (`4`). A
one-shot control such as private 1048 and every unknown mode report not
recognized (`0`); the terminal does not invent mutable state for behavior it
does not implement. This inventory includes the three mutually exclusive
mouse tracking selectors and the two mutually exclusive SGR coordinate
formats. Mode queries never mutate terminal state.

## Kitty keyboard protocol (amended 2026-08-16)

The implementation target is the published Kitty keyboard protocol as
retrieved on 2026-08-16. Protocol state is terminal state, not AppKit state.
The primary and alternate screens therefore own independent fixed-depth
stacks of progressive-enhancement flags. `CSI > flags u` pushes a new current
value (`flags` defaults to zero), `CSI < count u` pops (`count` defaults to
one), and `CSI = flags ; mode u` replaces, unions, or subtracts flags for
`mode` 1, 2, or 3. A full stack evicts its oldest value; a pop that exhausts
the stack resets the active screen to zero. RIS resets both stacks.

`CSI ? u` replies with `CSI ? flags u` for the active screen. A phased
implementation masks requested bits to the enhancements it actually encodes
and reports that effective value. It never echoes an unsupported bit merely
to pass capability detection: applications are explicitly allowed to set,
query, and adapt to a supported subset.

Phase 1 implements flags 1 (disambiguate escape codes) and 2 (report event
types) completely for the native control lane. Plain committed text continues
through `NSTextInputClient` as UTF-8. Escape, modified ASCII control keys,
modified Enter/Tab/Backspace, navigation/editing keys, and F1–F12 use the
protocol's canonical CSI forms when disambiguation applies. Repeats use event
type 2 and releases use type 3 when requested; releases for Enter, Tab, and
Backspace remain suppressed unless the later report-all flag is active. The
legacy encoder remains the default and gains the standard modifier forms used
by the same key table.

Flags 4 (alternate keys), 8 (all keys as escape codes), and 16 (associated
text) are masked off in phase 1. They land together with the event/text
correlation needed to preserve dead keys, composed input, and IME commits;
claiming them before that boundary exists would make the query response false.
The daemon receives semantic key events and consults the authoritative active
screen under the VT lock before encoding, so a mode-setting output sequence
cannot race a stale viewer snapshot. Encoded key bytes use the bounded ordinary
input queue and retain ordering with paste and mouse input.

### Phase 2 keyboard amendment (2026-08-19)

Phase 2 implements and reports flags 4, 8, and 16 through RFC 0013's bounded
semantic key/text transaction. The pure encoder accepts the logical unshifted
scalar, optional shifted and physical PC-101 base-layout alternates, complete
modifier/action state, and correlated AppKit committed text. Report-all also
covers recovery and standalone modifier keys; associated text is emitted as
Unicode scalar values only for non-control text on press/repeat. Pure text with
no key identity remains UTF-8 when associated-text encoding cannot represent
it, so composition, dictation, and Services input are never silently discarded.
The per-screen flag stacks and daemon-under-lock ordering above are unchanged.

## UTF-8 strategy

Run a UTF-8 decoder in front of the state machine; the parser operates on
codepoints in ground state and raw bytes inside sequences. Malformed input
never crashes: invalid bytes print U+FFFD and resync (matches modern xterm /
Ghostty behavior). C1 controls (0x80–0x9F): honor in their escape forms
(`ESC [` = CSI etc.); raw 8-bit C1 bytes are treated as UTF-8 continuation
noise, not controls — we are a UTF-8-only terminal, like every modern one.

## Grapheme mode (amended 2026-08-16)

DEC private mode 2027 selects the cursor-width model. It defaults reset, may
be set/reset with DECSET/DECRST, and is reported by DECRQM.

- Reset (legacy): printable codepoints advance by their pinned zg wcwidth.
  Zero-width suffixes are retained on the preceding content cell, but a later
  non-zero-width codepoint begins another display cell even when UAX #29 would
  join it. This preserves the column model assumed by programs that did not
  negotiate grapheme support.
- Set (full Unicode): printing is segmented as UAX #29 extended grapheme
  clusters using zg. A cluster advances once by its cluster width; a suffix
  may change a previously printed cluster between one and two columns.

The same cell representation stores suffix codepoints in both modes. “Storage
supports graphemes” therefore does not mean silently changing the cursor model
for an application that left mode 2027 reset. A leading zero-width codepoint,
or a zero-width codepoint whose preceding cell has no text, is consumed and
ignored. A cell retains at most 64 total codepoints; further suffixes in the
same cluster are consumed and ignored to bound hostile input.

## Implementation order for sequences

Work from what real software emits, not from the spec's table of contents:

1. **Teletype**: C0 (BS HT LF CR BEL), CUU/CUD/CUF/CUB, CUP, ED, EL, SGR
   (colors incl. 256/truecolor, bold/italic/underline/reverse).
2. **TUI minimum**: DECSET/DECRST for alt screen (1049), cursor keys (1),
   bracketed paste (2004), mouse modes (1000/1002/1006 SGR), autowrap (7),
   cursor visibility (25); scroll regions DECSTBM; IL/DL/ICH/DCH/ECH;
   DA1/DA2, DSR 5/6; tab stops (HTS/TBC/CBT); DECSC/DECRC; RIS/DECSTR.
3. **DECRQCRA early** (rectangle checksum, CSI ... * y): esctest verifies
   screen contents through it — implementing it unlocks the whole automated
   conformance suite. Do this before milestone 2, not after.
4. **The agent surface**: OSC 0/2, 8, 9/777, 52, 133; XTVERSION; DECRQM
   reporting for every mode we claim.
5. **Modern keyboard**: kitty keyboard protocol (progressive enhancement,
   CSI u) — TUIs and agents increasingly negotiate it; legacy encoding
   remains the default. See docs/references/escape-sequences.md.
6. **Tail on demand**: rectangle ops, DECSLRM left/right margins, XTWINOPS
   (report-only; never resize the window from the PTY), etc. Driven by
   conformance failures and real apps misbehaving, not completionism.

### Host pixel geometry amendment (2026-08-16)

XTWINOPS reports 14 and 16 are host geometry, not font guesses. The pure VT
stores only the latest host-supplied text-grid pixel width and height; it still
performs no AppKit, PTY, or renderer I/O. Report 14 returns that exact extent,
and report 16 returns its integer per-cell dimensions. If no host geometry has
been supplied, both queries are consumed without a fabricated reply. The host
updates pixel geometry even when rows and columns are unchanged.

The supported-sequence cheat sheet with per-sequence links lives in
docs/references/escape-sequences.md and is the working checklist.

### OSC 7 host-action amendment (2026-08-19)

OSC 7 working-directory reports leave the pure core as bounded, owned URI
actions. URI parsing, local-host validation, percent decoding, filesystem
checks, session metadata, and cwd inheritance are host policy in RFC 0020. An
empty payload remains observable so the host can clear a prior report; an
oversized payload is consumed and ignored.

### OSC 22 pointer-shape amendment (2026-08-20)

OSC 22 changes the native pointer over terminal content. The pure terminal
owns the requested shape so it survives viewer replacement and split-pane
focus changes; AppKit policy remains outside `src/vt/`.

The first interoperable set is deliberately small and exact:

- `text` and xterm's `xterm` select the text I-beam;
- `default` and `left_ptr` select the arrow;
- `pointer`, `hand`, and `hand2` select the pointing hand;
- `crosshair` and `cross` select the crosshair.

An empty or unknown value resets to `text`, matching xterm's fallback to its
default `xterm` pointer rather than retaining stale application state. RIS
also resets to `text`; DECSTR does not. Accepted changes increment the
terminal state generation; the daemon's ordinary output invalidation therefore
publishes a new snapshot even though the sequence paints no cells.

Attach dialect 18 carries the four-state value in the two formerly reserved
snapshot-mode bits. Public v13/v10 snapshots encode those bits as zero, which
decodes honestly as the historical text default. A future expansion to the
full CSS cursor-name set requires another explicit dialect; unimplemented
names are consumed and never printed.

Native cursor precedence is local and deterministic: Command-hover over an
OSC 8 hyperlink temporarily wins with the pointing hand, otherwise the OSC
22 state of the pane beneath the pointer wins. Releasing Command restores the
pane's requested shape rather than forcing an arrow. A refreshed snapshot may
update the cursor while the pointer is stationary.

## Correctness discipline

- Every sequence lands with a unit test; every esctest failure fixed adds the
  test that would have caught it.
- `TERM=xterm-256color`. We implement what that terminfo entry advertises;
  a custom terminfo entry is a later decision, not a v1 one.
- Unknown sequences are *consumed and ignored*, never printed. Log them
  (debug builds) — the log is the to-do list.
- Wide chars, graphemes, VS16, and mode 2027 policy:
  docs/references/unicode-width.md. Decision there, enforced here.

## Open questions

- Scrollback interaction with alt screen (alt screen has none — confirm no
  exceptions worth supporting).
