# The DEC ANSI parser state machine

The canonical spec: **Paul Flo Williams, "A parser for DEC's ANSI-compatible
video terminals"** — https://vt100.net/emu/dec_ansi_parser — reverse-engineered
from real VT500 hardware. Implement *that*, byte-table-driven. Do not invent a
parser; every hand-rolled `if (byte == 0x1b)` parser eventually mishandles
cancellation or interleaved C0, and this machine is proven.

## States (14)

`ground`, `escape`, `escape_intermediate`, `csi_entry`, `csi_param`,
`csi_intermediate`, `csi_ignore`, `dcs_entry`, `dcs_param`,
`dcs_intermediate`, `dcs_passthrough`, `dcs_ignore`, `osc_string`,
`sos_pm_apc_string`.

## Actions (parser → handler)

- `print` — display a character (ground)
- `execute` — C0 control (BEL, BS, HT, LF, CR, ...) — note: C0 executes even
  *mid-sequence* in most states; this is the classic hand-rolled-parser bug
- `clear` — reset collected params/intermediates (on entry to csi_entry etc.)
- `collect` — stash intermediate byte (0x20–0x2F) or private marker (`?`, `>`)
- `param` — accumulate numeric params (`;` separated; `:` sub-params for
  SGR 4:x / 38:2:...:r:g:b — the original machine predates sub-params; add
  them, Ghostty/xterm-style)
- `esc_dispatch`, `csi_dispatch` — sequence complete, act on it
- `hook` / `put` / `unhook` — DCS start / payload byte / end
- `osc_start` / `osc_put` / `osc_end` — OSC accumulation

## The rules that make it robust

1. **Anywhere transitions**: `0x1B` (ESC) from any state → `escape`;
   `0x18`/`0x1A` (CAN/SUB) → `ground` (abort current sequence); `0x9C` (ST)
   terminates strings. These transitions are why malformed/truncated
   sequences can never wedge the parser.
2. **String terminators**: OSC ends at ST (`ESC \`) *or* BEL (xterm
   compat — everything in the wild uses BEL). DCS/SOS/PM/APC end at ST only.
3. **`csi_ignore`** exists so malformed CSI is *swallowed*, not printed.
   Unknown-but-well-formed sequences dispatch and get ignored by the handler
   (and logged). Garbage on screen is always a parser bug, never acceptable.
4. **Params**: cap count (16 is xterm-compatible) and value (65535); missing
   param = 0 = "default" per-sequence. Overflow clamps, never wraps.
5. **OSC/DCS payloads**: cap length — OSC is capped at 64 KiB and DCS at
   4096 bytes. A cap prevents a malicious stream from OOMing the terminal;
   an overflowed string is consumed through its terminator but not dispatched.

## Our deviations from the 1997 machine (deliberate, standard)

- **UTF-8 in front**: decode before the machine; codepoints print in ground;
  bytes inside sequences stay bytes. Invalid UTF-8 → U+FFFD + resync.
- **No raw 8-bit C1** (0x80–0x9F as controls) — they collide with UTF-8.
  Escape-form C1 (`ESC [`, `ESC ]`, `ESC P`, `ESC \`) only.
- **Sub-parameters** (`:`) as noted above.

## Testing the parser specifically

- Table-driven unit tests: (state, byte) → (state', actions) straight from
  the vt100.net tables.
- Fuzz: random bytes must never crash, hang, or leave the machine
  unreachable from `ground` via CAN.
- Interleaving test: split every test sequence at every byte boundary across
  two `feed()` calls — state must carry across chunk boundaries perfectly
  (PTY reads split sequences constantly; this is a real-world bug class).

## Reference implementations

- Alacritty's `vte` crate (https://github.com/alacritty/vte) — the same
  machine in Rust, table-generated; small enough to read in one sitting.
- Ghostty `src/terminal/Parser.zig` — the same machine in Zig; closest
  idiom match for us.

If our parser disagrees with both vte and Ghostty on an input, we are wrong.
