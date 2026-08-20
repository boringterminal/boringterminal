# RFC 0010: Selection and copy

Status: shipped

## Goal

Get text *out* of the terminal: mouse selection (char/word/line), ⌘C,
selection rendering. The missing half of daily-driver usability.

## Model

- Selection state lives in the vt core alongside the grid — not because it
  is emulation (the child app never observes it) but because its endpoints
  are **pins** (RFC 0003: absolute row id + column) that only the storage
  layer can keep honest across scrolling and eviction. The purity rule
  (RFC 0001) is unaffected: selection changes nothing the app can see and
  emits no actions.
- Endpoints: `anchor` and `head`, each `{ row_id: u64, col: u16 }`,
  normalized on read. Both endpoints **inclusive** (the cell under the
  release point is selected — every terminal's behavior).
- Survival rules:
  - Scrolling/viewport movement: survives (ids are stable).
  - New output: survives until the selected rows evict; eviction clamps,
    full eviction clears.
  - **Reflow clears the selection** (v1). Content moves between rows;
    remapping a range through a rewrap is real complexity for marginal
    value — every terminal is at least flaky here. Recorded, revisit only
    on annoyance.
  - Typing clears it (input implies intent to move on); a plain click clears
    it; a drag starts a new one; alt-screen switch clears.

## Semantics

- Click count: single-click + drag = char, 2 = word, 3 = line. A single press
  without a drag clears the old selection and leaves nothing selected. The
  char selection begins only after a small pixel drag threshold so ordinary
  clicks and trackpad jitter never leave a one-cell mark. Word/line selection
  begins on the double/triple press and may then be extended by dragging.
- Word snapping: maximal run of non-whitespace cells around the click.
  (Configurable word characters are a config-file-era refinement.)
- Line selection follows **logical lines**: triple-clicking a wrapped row
  selects the whole soft-wrapped line — wrap flags exist precisely so
  this works.
- Wide pairs never split: an endpoint on a spacer extends to its head.
- Mouse reporting interplay: at the live viewport, a left-button gesture
  begun without Option goes to an application that enabled mouse tracking;
  a gesture begun with Option remains local selection through release (the
  iTerm escape-hatch convention). While inspecting primary scrollback,
  reporting is suppressed and clicks always select.

## Extraction (⌘C)

- Soft-wrapped rows join with **no newline** — copying a wrapped command
  line pastes as one line. Hard rows join with `\n`.
- Per hard line, trailing blank cells are trimmed; wide spacers and
  `wide_pad` filler are skipped.
- ⌘C only (macOS convention). Copy-on-select is a recorded maybe for the
  config file; it will not ship silently.
- Empty selection: ⌘C is a no-op (never clobbers the pasteboard).

## Rendering

- Selected cells get the theme's selection background (a tint, not
  inversion); fg unchanged. Drawn in the bg pass; cursor beats selection
  where they overlap.
- Selection renders in viewport coordinates and is visible while
  scrolled (that's half the point of selecting from scrollback).

## Shell plumbing

- `mouseDown:`/`mouseDragged:`/`mouseUp:` on the view; point→cell math
  accounts for the flipped y-axis and the viewport offset. The gesture keeps
  the raw, unclamped pointer position as well as its clamped cell.
- While a primary-screen selection drag is above or below the text area, a
  main-run-loop timer advances the viewport and selection head one row per
  tick. It stops on re-entry, release, scrollback boundary, lost button state,
  or screen switch. Alternate-screen drags never manufacture history; their
  selection is limited to the current frame.
- Edit menu gains Copy (⌘C) → responder chain → the view's `copy:`.

## Tests

Core-level (headless): snapping (word/line/wide), extraction joins and
trims, pin survival across scrolling, clamp-on-eviction, clear-on-reflow.
Mouse-event geometry is manual-checklist territory (RFC 0005 style).
