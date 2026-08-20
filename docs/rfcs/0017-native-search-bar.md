# RFC 0017: Reusable native search bar

Status: accepted

## Decision

Boring Terminal has one reusable AppKit `SearchBar` component for every
in-window search surface. RFC 0016's focused-session overlay is its first host;
the future all-session sidebar search uses the same editor and interaction
contract with different surrounding layout.

The component lives in `src/shell/search_bar.zig`. It owns native chrome and
text editing only: an `NSVisualEffectView`, one horizontal `NSStackView`, a
movable grip, one `NSSearchField`, a result-status label, previous/next
controls, and close. It
does not know about terminal sessions, the daemon protocol, matching, grid
pins, or result ordering. A host supplies a target plus query/previous/next/
close selectors and maps its own result model into the component's typed
status.

This is native composition, not a custom text widget. The search field keeps
AppKit's window-owned `NSTextView` field editor, input-method integration,
focus ring, clear button, undo manager, selection model, clipboard behavior,
spelling/input services, and standard responder-chain commands.

## Why this RFC exists

The first inline implementation placed AppKit objects and editing callbacks
directly in `window.zig`. Its field used single-line clipping without enabling
cell scrolling or keeping the shared editor's selection visible. A query only
slightly wider than the field therefore hid the insertion point and appeared
to stop accepting input. Piecemeal frame fixes also duplicated state that the
future global-search surface would need.

The defect is architectural: a search box is a small input subsystem, not a
row of unrelated views. Its editing, layout, focus, accessibility, and
lifecycle invariants must move together.

## Native editing contract

`NSSearchField` and its `NSSearchFieldCell` are configured explicitly:

- single-line mode is enabled; wrapping is disabled;
- the cell is scrollable, so excess text moves horizontally past its bounds;
- the clear/search button geometry remains system-owned;
- immediate change delivery is enabled, but a host request is not issued for
  uncommitted marked text;
- after an edit callback, focus restoration, or component relayout, the
  current field editor's selected range is scrolled into view;
- the single-line field does not become a wheel-scroll view. AppKit's field
  editor moves the viewport for caret navigation and selection dragging at an
  edge; unmodified wheel/trackpad events remain available to the containing
  terminal instead of becoming a second, undiscoverable horizontal scrollbar;
- the component never calls `setStringValue:` during an active ordinary edit,
  because replacing the control value can reset the editor's selection,
  composition, undo grouping, or horizontal viewport;
- programmatic clear/restore operations update the editor and control as one
  transaction.

The field accepts arbitrary valid Unicode text and preserves grapheme and IME
composition boundaries. Its host may impose a backend bound, but exceeding it
does not truncate, corrupt, discard, or make the query uneditable. The host
shows a stable validation status and sends no invalid request. RFC 0016's v1
host accepts at most 1024 UTF-8 bytes and 256 Unicode scalars. Interactive
paragraph/line-separator insertion is filtered by AppKit's single-line mode;
a multiline paste is normalized to spaces before it reaches the host.

Editing follows the macOS responder chain:

- `⌘A` selects the whole query;
- `⌘C`, `⌘X`, and `⌘V` operate on the query while its field editor is first
  responder;
- `⌘Z` / `⇧⌘Z`, arrow/word movement, Shift selection, Home/End equivalents,
  Option-delete, and input-source commands remain AppKit-owned;
- the visible navigation pair uses a thin up chevron for the previous result
  and a thin down chevron for the next result, matching the vertical order of
  terminal scrollback rather than suggesting horizontal tab/history movement;
- Return selects the next result and Shift-Return selects the previous result;
- `⌘G` selects next and `⇧⌘G` selects previous whether the editor or terminal
  is focused;
- Escape closes the host search surface; the native clear button clears the
  query without closing it;
- clicking terminal content may return focus to the terminal without
  destroying the query, status, or editor state needed when focus returns.

## State and asynchronous results

The component exposes these presentation states:

- `idle`: empty query, no status text;
- `searching`: non-empty valid query awaiting its current generation;
- `result`: current ordinal, bounded total, and optional truncation marker;
- `no_results`: completed non-empty query with no matches;
- `invalid`: locally rejected query, with a short reason such as `Too long`.

The host owns query/result generations. A stale asynchronous response never
changes the component status or editor selection. Previous/next actions during
`idle`, `searching`, `no_results`, or `invalid` are harmless no-ops; they never
send terminal input. The status is trailing-aligned and shares an optical
baseline with the native field and buttons.

## Layout, movement, and reuse

The component takes a host rectangle and positions only its draggable outer
overlay. A horizontal `NSStackView` owns the internal row, centers every
arranged view on the same Y axis, honors intrinsic control sizes, and gives the
search field the flexible width. The result label and buttons have stable
width constraints. Callers and pure layout policy never assign independent
vertical origins to individual controls; optical alignment therefore cannot
drift through unrelated magic offsets. The focused terminal overlay uses a
350-point preferred width and compact 32-point row, inset from the pane. Its
24-point native controls receive four-point vertical insets. The movable grip
uses a quiet 12-point lane and a two-point gap before the field; this keeps the
six dots usable without making the leading chrome feel like a second control.
Fixed trailing controls never overlap the field editor or its system clear
button, and the stable result-status slot is not collapsed while idle because
doing so would move the navigation controls as results arrive.

Narrow hosts degrade in this order:

1. hide the textual result status (VoiceOver retains it);
2. hide previous/next buttons while keeping `⌘G` / `⇧⌘G`;
3. retain the grip, editable field, and close control as the irreducible row.

The field always receives the remaining width and has a tested minimum before
any fixed control is allowed to overlap it. Window resize, sidebar resize,
pair-divider movement, scale changes, and pane focus changes re-run the same
pure visibility/outer-width policy; `NSStackView` performs the internal native
layout.

The six-dot grip moves an overlay only within its host rectangle. Dragging
never steals field selection gestures, changes terminal rows/columns, or sends
daemon state. The cursor changes between open and closed hand, the position is
re-clamped after resize, and it resets when the host closes the search surface.
Sidebar-hosted search may disable movement while reusing every other contract.

## Accessibility and appearance

Standard AppKit controls retain their native accessibility roles. The host
provides a scope-specific field label such as `Find in Session`; previous,
next, close, and grip have concise labels and help text. Result or validation
status remains available to assistive technology even when compact layout
hides its visual label. The component preserves increased-contrast, reduced-
transparency, accent/focus-ring, light/dark appearance, and Full Keyboard
Access behavior by using semantic `NSColor` values and native controls.

The outer material, modest radius, and separator hairline follow Boring
Terminal's sidebar and pair chrome. No caller may restyle the editor, replace
the standard clear/search cells, or add scope/options affordances without an
RFC amendment.

## Ownership and lifetime

`SearchBar` owns and releases its retained AppKit objects. Its runtime grip
view stores a non-owning pointer to the address-stable `SearchBar`; teardown
clears that pointer before releasing views. UI access is main-thread only.
Callbacks target the host responder rather than global process state, allowing
one component per window and preventing a later global-search instance from
sharing query or drag state accidentally.

## Verification gates

- Type, paste, select, and edit queries wider than the visible field; the
  insertion point and active selection remain visible at both ends and in the
  middle after every immediate-search callback.
- Confirm selection dragging at either horizontal edge reveals hidden text and
  that ordinary wheel input over the field does not invent a private scroll
  gesture or prevent the containing terminal from scrolling.
- Exercise exactly-at-limit and over-limit ASCII, composed/decomposed Unicode,
  emoji/ZWJ, RTL, dead-key, and marked-text input without truncation or invalid
  UTF-8 reaching the host.
- Verify `⌘A/C/X/V/Z`, clear, Return, Shift-Return, `⌘G`, `⇧⌘G`, and Escape
  with both field and terminal focus.
- Resize through ordinary, paired, minimum-width, hidden-sidebar, and Retina/
  non-Retina geometries; no control overlaps the editable text rectangle.
- Drag to every pane edge, resize, close/reopen, and switch focused sessions;
  clamping, cursor state, and reset remain correct.
- Delay and reorder fake result generations; stale results never replace the
  current status or disturb editing.
- Inspect VoiceOver order/labels and increased-contrast/reduced-transparency
  appearance.
- A pure layout test covers preferred and every compact tier. An AppKit smoke
  enters a query several times the field width and asserts the editor's
  selection is visible after the action callback.

## Prior art and authoritative references

Retrieved 2026-08-18:

- Apple Human Interface Guidelines, *Search fields*:
  https://developer.apple.com/design/human-interface-guidelines/search-fields
- Apple, `NSSearchField` and `NSSearchFieldCell`:
  https://developer.apple.com/documentation/appkit/nssearchfield and
  https://developer.apple.com/documentation/appkit/nssearchfieldcell
- Apple, `NSCell.usesSingleLineMode` and `NSCell.isScrollable`:
  https://developer.apple.com/documentation/appkit/nscell/usessinglelinemode
  and https://developer.apple.com/documentation/appkit/nscell/isscrollable
- Apple, `NSControl.currentEditor()` and `NSWindow.fieldEditor(_:for:)`:
  https://developer.apple.com/documentation/appkit/nscontrol/currenteditor()
  and https://developer.apple.com/documentation/appkit/nswindow/fieldeditor(_:for:)
- Apple, `NSText.scrollRangeToVisible(_:)` and `NSTextInputClient`:
  https://developer.apple.com/documentation/appkit/nstext/scrollrangetovisible(_:)
  and https://developer.apple.com/documentation/appkit/nstextinputclient
- Apple, *Accessibility for AppKit*:
  https://developer.apple.com/documentation/appkit/accessibility-for-appkit

Apple specifies that a window shares one `NSTextView` field editor among
lightweight controls, that `currentEditor()` returns it only while the control
is actively edited, that `isScrollable` permits excess text to move beyond
cell bounds, and that `scrollRangeToVisible:` exposes a requested range. The
component relies on those contracts rather than implementing its own editor.

## Rejected alternatives

- **Keep hand-positioning every internal control.** Matching reported text
  baselines still leaves different native cells with different optical insets,
  while each font or control-size change creates another compensating offset.
- **Fix only the current frame width.** Any finite width fails again for a
  longer query and leaves global search to repeat the same integration bugs.
- **Custom `NSTextView` or `NSTextInputClient`.** Reimplements selection, IME,
  undo, clipboard, accessibility, and key bindings that AppKit already owns.
- **Terminal-painted input.** Mixes application chrome with PTY cells, changes
  geometry, and loses the native responder chain.
- **Programmatically replace the value after every key.** Resets shared-editor
  selection/composition/undo state and is the opposite of native editing.
- **Expand the overlay with the query.** Obscures terminal content and makes
  window/pair geometry unstable; horizontal field-editor scrolling is the
  standard behavior.
