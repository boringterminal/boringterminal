# RFC 0003: Grid storage, scrollback, and reflow

Status: shipped (v1 decisions locked 2026-08; was draft)

This is the one data structure worth designing before writing code. The
iteration-0 flat grid (clip/pad on resize, no scrollback) is replaced by
this design; the shrink-then-grow content loss it exhibited is this RFC's
acceptance test.

## Requirements (unchanged from draft)

- Cells carry: a base codepoint, optional grapheme suffix reference, fg/bg and
  underline color, style flags, width (1/2), and RFC 0018's compact OSC 8
  hyperlink id.
- **Soft-wrap continuation flag per row** — a "logical line" is a maximal
  run of soft-wrapped rows; hard newlines break logical lines. Reflow =
  re-wrap logical lines to the new width. Never lose the distinction
  between "wrapped because narrow" and "user pressed enter".
- Scrollback: append-mostly, FIFO eviction, capped.
- Stable references that survive scrolling and eviction: viewport,
  (later) selection endpoints, search hits, prompt marks.
- Alt screen: separate fixed grid, no scrollback, no reflow (clip/pad —
  TUIs repaint on SIGWINCH).

## v1 decisions (locked)

**Storage: a ring buffer of uniform-width rows with absolute row ids** —
alacritty-shaped, not Ghostty-style pages. *Deviation from the draft's
"paged storage" direction, recorded:* pages buy memory locality, interned
styles, and relocatable references at the cost of an order of magnitude
more machinery. Every required invariant (wrap flags, stable pins, reflow,
eviction) is achievable with a row ring plus monotonically increasing
absolute ids; the pin interface is storage-agnostic, so a later swap to
pages (if profiling ever demands it) does not disturb callers. Build the
simple thing behind the right interface.

- `Row = { cells: []Cell, wrapped: bool }`; `wrapped` means "continues
  onto the next row". After any reflow, every stored row has the current
  width — uniformity is an invariant.
- **Absolute ids**: each row created gets the next u64 id; eviction
  advances a base id. A pin is `{ row_id, col }`; validity = `id >= base`.
  Viewport is "bottom" or a pin-like offset.
- **No style interning** in v1 (cells store colors inline, as today);
  interning is pages-era work.
- **Grapheme suffix storage** (amended 2026-08-16): cells remain plain,
  memcpy-safe values. A single-codepoint cell allocates nothing. A
  multi-codepoint cell stores an offset and length into an append-only,
  terminal-owned `u21` arena containing the suffix after the base codepoint.
  Offsets are process-local and never cross the daemon protocol. Reflow and
  row movement copy them unchanged. When arena growth reaches its adaptive
  threshold, the terminal traces the primary ring and alternate grid,
  compacts live suffixes, and rewrites offsets; this makes abandoned suffixes
  from erasure, repaint, and scrollback eviction reclaimable without putting
  reference counting on every grid memcpy. A suffix is capped so a cell holds
  at most 64 codepoints, matching the bounded-input precedent in Ghostty.
- **Scrollback cap**: 10_000 rows above the screen, a compile-time
  constant until the config file exists. Capacity concerns are recorded,
  not speculated on: revisit on real memory profiles.
- **Scrollback feeding** (amended 2026-08-16): rows enter scrollback from an
  upward scroll on the primary screen whenever the affected region starts at
  row zero and spans the full width. The bottom margin may stop above the
  screen bottom; rows below it stay fixed. This is the xterm-shaped behavior
  used by inline TUIs (Codex is the motivating fixture): they reserve a
  composer at the bottom, set a top-anchored DECSTBM region above it, and
  expect finalized output to enter terminal history. LF/IND, SU, and DL at
  row zero all follow this storage rule. Regions whose top/left margin is not
  zero, downward scrolls, and everything on the alt screen recycle rows in
  place.
- **ED 3** clears scrollback (and only scrollback).

## Wrap-flag ownership (amended after the zsh prompt-smear bug)

A row's `wrapped` flag asserts "my last cell flows into the next row".
Two invalidation rules keep it truthful under in-place repaints (zsh's
SIGWINCH `\r` + clear + reprint cycle is the canonical stressor):

1. Any operation that rewrites the row's **end** clears its own flag:
   EL 0 (any column) and EL 2, DCH/ICH (they shift the tail), ECH
   reaching the last column, and printing into the last column (the flag
   is re-set only by an actual wrap event).
2. Fully clearing a row **also clears the previous row's flag** — a
   cleared row cannot be anyone's continuation, and leaving the claim
   dangling is how ghost repaints weld into mega-lines under reflow.

## Reflow rules (the acceptance tests)

- Rewrap logical lines; the cursor stays on its logical character, not its
  (row, col).
- Trailing blank cells on rows do not become real spaces when lines rejoin —
  **except at or before the cursor's character offset, which never trims**:
  shells track the cursor relative to their own prompt geometry (trailing
  prompt spaces included), and trimming under the cursor shifts it a
  row/col off, making every relative repaint land wrong (the ghost-prompt
  bug at minimum width).
- **Shrink-then-grow round-trips content exactly** (property test: random
  width sequences ending at the original width ⇒ identical grid).
- Wide chars never split across a wrap; a wide char that would straddle
  the boundary moves whole to the next row (its old cell blanks, row marks
  wrapped).
- A grapheme head and its wide spacer are the same reflow atom. Copy and dump
  paths emit the base plus its stored suffix exactly once and never emit the
  spacer. A presentation-driven one-to-two-column change at the right edge
  moves the entire cluster to the next row under autowrap rather than splitting
  it; a two-to-one change removes its spacer and repairs the cursor position.
- Kitty's U+10EEEE image placeholder is ordinary one-cell text with its
  diacritics in the existing grapheme suffix and its image/placement identity
  in foreground/underline color. Reflow, scrolling, copying, erasure, and
  selection therefore move or remove it exactly like other text; no parallel
  image-position side table may become authoritative for placeholder cells.
- Alt screen never reflows.
- Height changes are bottom-anchored (prompt stays put): shrinking first
  drops blank rows below the cursor, then pushes top rows into scrollback;
  growing pulls scrollback rows back into view at the top.

## Viewport

- Offset in rows above the live bottom; 0 = live. Clamped to scrollback
  length; eviction drags it along.
- Output does **not** yank the view to the bottom; keyboard input does
  ("scroll on input", the behavior every terminal user expects).
- The cursor is only drawn at offset 0.
- Scroll wheel: primary screen scrolls the viewport; alt screen translates
  wheel ticks to arrow keys (the xterm "alternate scroll" convention —
  mode 1007 negotiation can arrive later, the default behavior is what
  users expect in less/vim now).

## Search

RFC 0016 owns the search interaction, matching policy, daemon protocol, and
cross-session result surface. This storage owns its underlying invariants:
logical-line traversal follows soft-wrap flags, grapheme extraction omits wide
spacers, and result ranges use pins that survive scroll/reflow and invalidate
on eviction. Search never stores styling in cells or makes the viewer own a
second scrollback copy.

## Prior art (consult, don't copy)

- Alacritty `alacritty_terminal/src/grid/resize.rs` — the most readable
  reflow implementation anywhere; this design is deliberately shaped so
  that reference applies.
- Alacritty `alacritty_terminal/src/grid/mod.rs` (`scroll_up`) and Ghostty
  `src/terminal/Terminal.zig` (`scrolling_region.top == 0`) — both admit
  history for a top-anchored partial-height region and restore the fixed
  rows below it. These are the oracles for the 2026-08-16 amendment.
- Codex `codex-rs/tui/src/insert_history.rs` — the motivating application:
  its inline UI reserves a bottom composer and prints finalized output
  through a top-anchored scroll region.
- Ghostty `src/terminal/PageList.zig` — the pages design we deferred;
  read it again before ever deciding to migrate.
