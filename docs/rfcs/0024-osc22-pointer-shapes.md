# RFC 0024: Complete OSC 22 pointer shapes

Status: accepted

## Problem

Boring Terminal's first OSC 22 implementation recognizes only text, arrow,
pointing-hand, and crosshair pointers. Pixel-oriented terminal applications
need the rest of the ordinary pointer vocabulary: direct manipulation,
resizing, drag-and-drop intent, unavailable actions, and vertical text.

Terminal Kanban exposes the immediate gap. It emits `OSC 22;grabbing` while a
card is dragged, but Boring Terminal treats the unknown name as `text`, leaving
an I-beam over the moving card. Fixing only that one name would spend another
snapshot dialect while leaving every resize and drag-and-drop application to
repeat the same compatibility work.

## Decision

Boring Terminal accepts the complete 34-name CSS pointer vocabulary used by
modern terminal prior art:

```text
default       context-menu  help          pointer       progress
wait          cell          crosshair     text          vertical-text
alias         copy          move          no-drop       not-allowed
grab          grabbing      all-scroll    col-resize    row-resize
n-resize      e-resize      s-resize      w-resize      ne-resize
nw-resize     se-resize     sw-resize     ew-resize     ns-resize
nesw-resize   nwse-resize   zoom-in       zoom-out
```

It also accepts the interoperable xterm/Xcursor aliases already emitted by
terminal applications:

| Canonical shape | Aliases |
| --- | --- |
| `default` | `left_ptr` |
| `help` | `question_arrow` |
| `pointer` | `hand`, `hand2` |
| `progress` | `left_ptr_watch` |
| `wait` | `watch` |
| `crosshair` | `cross` |
| `text` | `xterm` |
| `alias` | `dnd-link` |
| `copy` | `dnd-copy` |
| `move` | `dnd-move` |
| `no-drop` | `dnd-no-drop` |
| `not-allowed` | `crossed_circle` |
| `grab` | `hand1` |
| `all-scroll` | `fleur` |
| `n-resize` | `top_side` |
| `e-resize` | `right_side` |
| `s-resize` | `bottom_side` |
| `w-resize` | `left_side` |
| `ne-resize` | `top_right_corner` |
| `nw-resize` | `top_left_corner` |
| `se-resize` | `bottom_right_corner` |
| `sw-resize` | `bottom_left_corner` |

Names are case-sensitive. An empty or unknown value resets to `text`; it never
preserves stale state and never prints. RIS resets to `text`, while DECSTR does
not. The existing `cross` to `crosshair` mapping is retained for compatibility.

The pure VT core owns the shape. A successful change increments the terminal
state generation, and the daemon publishes it in the next snapshot. AppKit
maps canonical state to the closest stable native cursor:

| Canonical shapes | AppKit cursor |
| --- | --- |
| `text` | `IBeamCursor` |
| `default`, `help`, `progress`, `wait` | `arrowCursor` |
| `pointer`, `zoom-in`, `zoom-out` | `pointingHandCursor` |
| `cell`, `crosshair` | `crosshairCursor` |
| `vertical-text` | `IBeamCursorForVerticalLayout` |
| `context-menu` | `contextualMenuCursor` |
| `alias` | `dragLinkCursor` |
| `copy` | `dragCopyCursor` |
| `move`, `grab`, `all-scroll` | `openHandCursor` |
| `grabbing` | `closedHandCursor` |
| `no-drop`, `not-allowed` | `operationNotAllowedCursor` |
| `col-resize`, `ew-resize` | `resizeLeftRightCursor` |
| `row-resize`, `ns-resize` | `resizeUpDownCursor` |
| `n-resize` | `resizeUpCursor` |
| `e-resize` | `resizeRightCursor` |
| `s-resize` | `resizeDownCursor` |
| `w-resize` | `resizeLeftCursor` |
| diagonal resize shapes | `crosshairCursor` |

AppKit has no public busy, help, or zoom cursor and no public diagonal resize
cursor. Boring Terminal does not ship imitation bitmap cursors for them. The
fallbacks remain deterministic.

The shell does not infer shape from mouse buttons, tracking modes, or
application geometry. Command-hover over an OSC 8 hyperlink temporarily wins
with the pointing hand; otherwise the OSC 22 state of the pane beneath the
pointer wins. A snapshot refresh may change the cursor while stationary.

## Attach dialect 19

Thirty-four values no longer fit the two snapshot-mode bits assigned by
dialect 18. This is an exact wire-schema change and allocates attach dialect 19.

Dialect 19 restores those two bits to reserved zero and appends one pointer
shape byte immediately after the snapshot-mode byte. Values 0 through 33 use
the canonical order listed above, except that the released v18 values remain
stable at the front: 0 `text`, 1 `default`, 2 `pointer`, 3 `crosshair`; the
remaining canonical values occupy 4 through 33. Values 34 through 255 are
invalid. The in-memory snapshot stores modes and pointer shape separately.

The current viewer adds a frozen v18 snapshot adapter. It decodes the exact
v18 two-bit values into the canonical model and does not make the daemon link
legacy code. Public v13 snapshots share the old byte shape but require both
pointer bits to be zero and translate to `text`. Public v10 remains retained
during development because v19 has not yet consumed a public compatibility
slot. If dialect 19 ships publicly, release-boundary rotation removes v10 and
records v19 as current with v18 and v13 retained, per RFC 0019.

An attached v18 daemon cannot understand the new names and truthfully reports
its historical text fallback. The viewer must not synthesize new state.

## Tests and acceptance

- Table-driven parser tests cover every canonical name and alias.
- Whole-stream and every-byte-split terminal tests cover representative drag,
  resize, and fallback values.
- Empty and unknown names, RIS, and DECSTR retain their specified behavior.
- Snapshot round trips cover the full enum and reject reserved mode bits and
  pointer bytes above 33.
- Frozen v18 frames decode all four historical pointer values through only the
  v18 adapter; the current decoder rejects the v18 layout.
- The daemon binary imports only the current v19 codec.
- Terminal Kanban shows its pointing hand over a card, a closed hand during
  dragging, and restores the appropriate hover shape after release.

## Rejected alternatives

### Add only `grab` and `grabbing`

That fixes one application but leaves resize and drag-and-drop tools at the
same known boundary while already forcing a dialect change.

### Infer pointers from viewer input

The viewer cannot know whether an application accepted a drag or which resize
edge it exposes. Terminal state remains authoritative.

### Ship custom bitmap cursors for missing AppKit shapes

System cursors carry platform-appropriate size, contrast, accessibility, and
hotspot behavior. Custom approximations need a separate visual/accessibility
design and are not required for protocol completeness.

### Accept both v18 and v19 snapshot layouts in one decoder

Payload length is not an extension point. A lenient decoder would violate the
strict attach-dialect boundary and make malformed frames ambiguous.
