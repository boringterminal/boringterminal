# RFC 0014: Paired sessions — a bounded two-up view

Status: accepted (amended 2026-08-19)

## Decision

RFC 0000 and RFC 0006 deliberately reject splits because Boring Terminal is a
session switchboard, not a general layout system. This RFC proposes one narrow
exception: two existing sessions may form a persistent **pair** and render
side-by-side. The limit is structural, not a first implementation phase:
exactly one level, at most two sessions, and one orientation.

The feature passes the product's one-line test when someone needs to watch an
agent beside its test runner, compare two agents, or keep a shell visible while
an agent works. Arbitrary pane trees, layout profiles, and terminal
multiplexing still fail it.

This is the sole accepted exception to RFC 0000 and RFC 0006's general
no-splits rule. It authorizes only the bounded pair specified here; anything
more requires another explicit product-level decision.

## Prior art and the part worth borrowing

Arc treats a split as a first-class sidebar item that can be revisited, not as
two anonymous panes temporarily sharing pixels. Tabs can be combined by a
direct manipulation, focused independently, resized, and separated without
destroying either tab. That compound-item model is the useful precedent; Arc's
browser-specific Spaces, favorites, previews, archives, colors, and general
command surface are not.

Reference: Arc Help Center, *Split View: View Multiple Tabs at Once*, retrieved
2026-08-17:
https://resources.arc.net/hc/en-us/articles/19335393146775-Split-View-View-Multiple-Tabs-at-Once

## Model

A daemon session remains the unit that owns one PTY, VT, title, attention
state, scrollback, and lifecycle. Pairing never merges those states. The
switchboard's ordered presentation list instead contains:

```text
DisplayItem = Single(session_id)
            | Pair(left_session_id, right_session_id,
                   focused_member, divider_ratio, zoomed)
```

Each session id occurs in exactly one display item. A pair cannot contain a
pair, accept a third session, or refer to the same session twice. Pairing and
separating preserve the underlying sessions and byte streams exactly.

The only orientation is side-by-side. A second orientation sounds small but
doubles creation affordances, shortcuts, persistence, and resize edge cases;
it is the beginning of a pane manager. Side-by-side matches wide Mac displays
and preserves useful row counts for agent TUIs.

## Creation, separation, and ordering

- Sidebar manipulation uses a native AppKit dragging session, not a pan
  gesture that merely watches the pointer. The dragged row or member is shown
  as a translucent lifted snapshot, valid destinations publish insertion or
  pairing feedback, and a rejected/cancelled drop animates back to its source.
- A vertical insertion target between rows reorders a display item. A pair
  moves as one item. Reordering never changes focus, member order, or PTY
  state.
- Dragging one single-session row onto the left or right half of another
  single creates a pair in that visible order. The pair occupies the target
  row's former position; the dragged row is removed from its old position.
  The side-sensitive target makes member order a deliberate choice instead of
  an accident of which row happened to be the target.
- A pair never advertises itself as a valid drop target. To replace a member,
  separate first. There is no implicit eviction or three-way layout.
- A native context-menu action, **Separate Sessions**, turns the pair back into
  two adjacent single rows, left then right. Dragging either compact member to
  an insertion target performs the same operation at the drop position.
- Dragging a compact member across its sibling swaps the pair's left and right
  members without changing the focused member or divider ratio. The Session
  menu and pair context menu also expose **Swap Sides** for keyboard and
  accessibility parity.
- Dragging a compact member onto the left or right half of a different single
  atomically collapses its original pair to the survivor and forms a new pair
  with the destination session in the indicated order. No observer may see an
  intermediate three-single registry, and failure leaves the original pair
  untouched.
- Pair creation retains whichever member was focused before the operation.
  Selecting the pair later restores its most recently focused member.
- Manual ordering treats the pair as one display item. It moves as a unit
  until separated.

Pairing two existing sessions must also be keyboard-accessible, but it gets no
dedicated global shortcut. The Session menu exposes **Pair With Previous
Session**, **Pair With Next Session**, and **Separate Sessions** when
applicable. This preserves the small global shortcut vocabulary and gives
AppKit accessibility an ordinary menu action to invoke.

Fresh pair creation follows the native terminal convention instead of making
the user create, locate, and drag a second session. **New Session Beside
Current** (`⌘D`) is available only when the focused display item is a single
and the window can satisfy the two 20-column minima. It atomically creates a
new session to the right, inherits the focused foreground process's cwd under
RFC 0006, pairs it with the current session, and focuses the new member. When
the current item is already a pair, the command is disabled and the shortcut
beeps; it never adds a third member or silently creates an unrelated single.
`⌘T` remains ordinary **New Session**.

Pane organization is directional rather than a separate organizer surface:

- `⌥⌘←` and `⌥⌘→` focus the left or right member;
- `⇧⌥⌘←` and `⇧⌥⌘→` move the focused member to that side,
  swapping the pair only when necessary;
- `⌥⌘↑` and `⌥⌘↓` focus the previous or next sidebar display item;
- `⇧⌥⌘↑` and `⇧⌥⌘↓` move the focused display item up or down as one
  unit, so a pair retains its members, focus, ratio, and zoom;
- **Swap Sides** and divider double-click-to-equal-width remain available in
  the Session/context menus for discoverability and pointer use.

Horizontal actions are disabled outside a pair. Vertical actions follow the
sidebar's row model: a single is a one-session item and a pair is a compound
item. Entering a pair restores its remembered focused member. Vertical
navigation and movement stop at the first and last item rather than wrapping;
an unavailable edge action is disabled and never leaks its key equivalent to
the PTY. `⌘⇧[` and `⌘⇧]` retain their distinct, wrapping traversal through
every individual session. There is no pane overview or layout palette: with
exactly two side-by-side members, explicit focus and movement completely
describe the possible organization.

## Sidebar presentation

A pair occupies one ordinary fixed-pitch sidebar row and uses one outer rounded
selection capsule, not two unrelated adjacent pills. Inside it, a quiet
hairline divides two equal compact title segments identifying the left and
right sessions. Each title uses the same middle-ellipsis policy as a single
row. The focused member receives a subtle nested selection fill clipped by the
outer capsule; focus never changes label geometry.

Each segment reserves a fixed attention-dot position. An unfocused member can
therefore ask for attention without reducing the pair to an ambiguous aggregate
dot. When the sidebar is hidden, RFC 0006's title-bar and Dock indicators remain
aggregate counts.

Holding Command numbers individual sessions in visual order, not compound
rows. A pair therefore shows one badge in each member segment: if it follows
no earlier sessions, its left and right members are `⌘1` and `⌘2`, and the
next single is `⌘3`. `⌘1…⌘9` focuses that exact session; grouping never makes
a direct shortcut ambiguous or renumbers two sessions as one. Clicking a
segment likewise focuses that member. `⌘⇧[` and `⌘⇧]` continue through the
same visual order, treating the pair's left and right members as adjacent
stops.

Each pair segment reserves its own fixed trailing close slot and reveals that
close control only while the segment is hovered. It closes that exact member,
independent of current focus, and its tooltip names the session. The reserved
slot prevents either title from shifting on hover. `⌘W` closes the focused
member. Both paths use RFC 0006's foreground-process confirmation; the
survivor atomically becomes a single display item in the pair's position.
There is no one-click "close both" action and no ambiguous pair-level close.

RFC 0006's bounded resizable sidebar is important here: 160 points remains the
calm default, while a user who relies on pairs may widen it without adding a
layout setting to the config file.

## Surface, focus, and input

The window still has one terminal content surface. A pair divides that surface
with one resizable vertical divider and two pane rectangles. The divider starts
at 50%, persists with the pair, and double-clicks back to 50%. Both panes must
retain at least 20 terminal columns. The pair raises the active window's
minimum content width to two 20-column terminals plus the divider and visible
sidebar. Pair creation is unavailable when the current screen cannot
accommodate that minimum without placing the window off-screen.

Exactly one member has input focus:

- keyboard, paste, IME, selection commands, and local cursor presentation go
  to the focused member;
- clicking either terminal pane focuses it before handling the click;
- the NSWindow title follows the focused member, preserving RFC 0005;
- mode-1004 focus reporting sends a real loss/gain transition when focus moves
  between members;
- when the window resigns key, both are unfocused.

Visibility is not focus. The visible but unfocused member may raise attention,
and focusing the other member must not clear it. This distinction is essential
for the feature's agent use case.

Both paired sessions receive geometry matching their own pane. Dragging either
the pair divider or sidebar divider uses RFC 0009's transactional live-resize
path and sends daemon resizes only at cell-boundary changes. A resize cannot
temporarily publish a grid under 20 columns.

## Temporary pane zoom (amended 2026-08-18)

A pair may temporarily **zoom** its focused member to occupy the complete
terminal surface without changing pair membership. **Zoom Focused Pane** /
**Show Both Panes** uses `⇧⌘Return`, matching the established macOS terminal
interaction. The same action appears in the Session and pair context menus;
double-clicking a compact sidebar member focuses and zooms it. Double-clicking
terminal content remains word selection and is never intercepted.

While zoomed:

- the content divider disappears and only the zoomed member is rendered;
- the sidebar retains the compound pair row, with the visible member at full
  emphasis and its hidden sibling more subdued;
- clicking or directly focusing the hidden sibling switches which member is
  zoomed rather than restoring the split;
- attention, title, lifecycle, close, and direct `⌘1…⌘9` behavior remain
  independent for both sessions;
- the hidden PTY continues running at the geometry it would have under the
  saved pair ratio, but it schedules no GPU work;
- restoring the pair reinstates the exact saved divider ratio and focused
  member.

Zoom is daemon-owned presentation state in the pair record. It survives display
switches and replacement of the disposable viewer for exactly as long as the
pair and its daemon-owned PTYs survive. The pair stores whether it is zoomed;
its already-authoritative focused member identifies the visible member, so
there is no second member identity that can drift. A window resize still
updates the hidden member's calculated split geometry at cell boundaries so
restoration never reveals a stale grid. Switching focus while zoomed resizes
the formerly visible member back to its split geometry and the newly visible
member to the full surface under the same registry mutation.

Grid resize and presentation form a geometry transaction. After zoom, restore,
divider movement, window resize, sidebar resize, or text zoom changes a pane's
requested rows or columns, the viewer keeps the last coherent drawable until a
snapshot matching every newly visible pane's requested grid arrives. It never
places a stale half-width snapshot into a full-width pane (or the reverse).
This is a presentation barrier only: PTY resize and parsing remain asynchronous,
and a failed refresh leaves the previous coherent frame visible.

Closing a member, separating the pair, or transferring a member clears its
zoom state. Swapping sides preserves the zoomed session by identity. Closing
the hidden member leaves the visible survivor as an ordinary single. Search
from RFC 0016 always targets the visible/focused member.

The daemon remains authoritative for both PTYs, VT states, pair zoom, focus
transitions, and resize commands. A future multi-viewer design must resolve
competing geometry through an explicit policy; the current single-viewer rule
keeps one unambiguous zoom state and does not guess at that future design.

## Renderer boundary

A pair does not create a second renderer or duplicate long-lived atlases. The
single CAMetalLayer frame becomes a pure function of one or two pane inputs:

```text
Frame = f([{ snapshot, resources, pane_rect, focused }])
```

One shared renderer builds both panes with independent origins and scissor
rectangles, then encodes one command buffer and one presentation. Glyph and
color-emoji atlases remain shared. Kitty texture identity already includes the
session id and remains collision-free. Only the focused pane draws the active
terminal cursor and marked-text overlay.

Damage from either visible member schedules the shared frame. Sessions outside
the selected display item retain RFC 0004's zero-GPU background behavior. The
two-pane limit bounds visible instance and image work without inventing a new
render scheduler.

## Ownership and reattach

Pairs are switchboard state, not disposable NSView state. The daemon owns the
ordered `DisplayItem` list, focused-member memory, normalized divider ratio,
and zoom flag for its lifetime. Attach protocol versions 9, 10, and 12 provide the
bounded atomic pair/create/separate/reorder/ratio commands and return display
items with the session list. Closing a member collapses its pair under the
same registry lock that removes the session.

This makes viewer crash/quit/reopen preserve the same compound rows while the
PTYs survive. No disk persistence is needed: if the daemon dies, the paired
sessions also die. The current single-viewer rule remains; multi-viewer-specific
layouts are deferred rather than guessed.

Member transfer and side swapping are daemon-owned atomic registry commands,
for the same reason pairing and close-collapse are daemon-owned. Viewer crash
or command failure cannot strand a half-applied compound-row operation.

**New Session Beside Current** is likewise one daemon-owned atomic registry
operation. Attach protocol version 12 combines session creation and pair
insertion so observers never see a transient appended single and failure
cannot leak an unpaired shell. Attach dialect 17 adds the pair zoom flag and
an atomic set/clear mutation. The current viewer disables pane zoom when
attached to retained v10/v13 daemons because those public schemas cannot
persist it; it never sends them the new tag or fabricates durable state.

RFC 0019 compatibility mode disables **New Session Beside Current** against a
retained v10 daemon because v10 has no atomic create-and-pair operation. It does
not decompose the command into a visible create followed by pair. Existing v10
pairs and every older atomic registry mutation remain available.

The human-facing RFC 0007 CLI continues to address sessions, not panes. Pair
automation is omitted until a real external workflow requires it.

## Acceptance gates

- Pair an agent and a busy shell; both continue updating and accepting input
  independently with no duplicated atlas or texture identity.
- Quit and reopen the viewer; the daemon restores pair membership, order,
  focus memory, and divider ratio with both PTYs intact.
- Attention from the visible unfocused member marks only that member and is
  not cleared by focusing its partner.
- Holding Command and `⌘1…⌘9` number and focus individual sessions in visual
  order, including both members of a pair.
- `⌘D` atomically creates and focuses a right-hand partner for a single, is
  disabled for a full pair, and never exposes an intermediate sidebar row.
- Directional focus/move shortcuts address the exact pair member and never
  create, destroy, or reorder a neighboring display item.
- Vertical focus shortcuts visit sidebar items without wrapping; vertical
  move shortcuts atomically reorder the complete active item, preserving a
  pair's member order, focus, ratio, and zoom identity.
- Zoom either member, switch the zoomed member through sidebar/direct keyboard
  focus, leave and revisit the pair, then restore the exact divider ratio.
  The hidden session continues parsing and can raise attention without
  scheduling Metal work.
- `⌘W`, child exit, and explicit close collapse a pair to its survivor without
  moving neighboring display items or prompting for the wrong process.
- Sidebar and pair dividers survive rapid live dragging; grids never fall below
  20 columns and SIGWINCH is sent only when cell geometry changes.
- A third session cannot be dropped into a pair, pairs cannot nest, and no
  alternate orientation exists in code or configuration.
- Ten sessions with one visible pair render only those two sessions; the other
  eight retain the existing damage-only, zero-GPU background behavior.

## Rejected alternatives

- **Arbitrary split trees or tmux-style panes:** turns the switchboard into a
  layout system and creates recursive focus, resize, close, and persistence
  semantics. Rejected permanently.
- **Horizontal and vertical orientations:** unnecessary choice for a bounded
  comparison surface and the first step toward layouts. Side-by-side only.
- **Viewer-local pairs:** reopening the replaceable viewer would discard a
  first-class sidebar item while the sessions survive. Rejected.
- **A pair as a synthetic terminal session:** would merge unrelated PTYs,
  titles, attention, and lifecycles. The pair is presentation state only.
- **Closing a pair as one unit:** too easy to terminate two foreground jobs
  through one ambiguous close target. Close the focused member explicitly.
- **Collapsing a member into a thin rail:** creates another persistent layout
  and an awkward hit target. Reversible zoom preserves the pair without a
  third pane shape.
- **A pane organizer:** a modal layout surface for two fixed side-by-side
  members adds no capability beyond focus, move-left/right, swap, and reset
  width.

## Shortcut prior art (amended 2026-08-18)

Apple Terminal uses `⌘D` for a side-by-side split. iTerm2 uses `⌘D` for the
same orientation, `⌥⌘` plus arrows to navigate panes, and `⇧⌘Return` to
maximize/restore the current pane. Ghostty exposes the same underlying actions
as `new_split`, `goto_split`, `toggle_split_zoom`, and `equalize_splits`.
Boring Terminal adopts the familiar macOS vocabulary while retaining its hard
two-member, one-orientation limit.

Primary references, retrieved 2026-08-18:

- Apple, *Keyboard shortcuts in Terminal on Mac*:
  https://support.apple.com/guide/terminal/keyboard-shortcuts-trmlshtcts/2.15/mac/26
- iTerm2, *Highlights for New Users*:
  https://iterm2.com/documentation-highlights.html
- Ghostty, *Keybinding Action Reference*:
  https://ghostty.org/docs/config/keybind/reference
