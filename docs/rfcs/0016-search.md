# RFC 0016: Terminal and cross-session search

Status: accepted

## Decision

Search has two scopes with two deliberately different surfaces:

- **Find in Session** (`⌘F`) searches the focused terminal's current buffer
  and scrollback. It is a compact native overlay inside that terminal pane.
- **Find in All Sessions** (`⇧⌘F`) searches every session still owned by the
  daemon. It temporarily turns the session sidebar into a grouped result list
  while leaving the terminal surface visible.

There is no permanent search icon, search tab, or full-page search workspace.
Local search is navigation within content already on screen; global search is
navigation between switchboard entries. Neither is a new terminal session.

RFC 0019 compatibility mode disables both search surfaces against a retained
v10 daemon. Search is daemon-owned and first appeared in attach dialect 11;
the viewer never sends the unknown search command or fabricates results from a
visible snapshot. Ordinary scrollback and selection remain available.

This is the missing part of RFC 0000's non-negotiable scrollback-with-search
promise. It passes the one-line product test directly: an agent can emit an
ocean of output in any of ten sessions and the user can recover the relevant
line without surrendering the session context.

## Prior art and the boundary

Apple's fixed vocabulary is the base: `⌘F` finds, `⌘G` advances, and
`⇧⌘G` goes backward. Zed makes the useful scope distinction between an
in-buffer `⌘F` surface and a project-wide `⇧⌘F` result surface. Alacritty
and Ghostty prove that terminal search must navigate terminal-owned history,
highlight viewport matches, and run independently of PTY input.

Boring Terminal borrows the scope distinction, not Zed's search tab. Zed's
project results are an editable multibuffer and therefore a document in their
own right. Our results are read-only jump targets. Turning them into a tab
would make the sidebar contain two unrelated object kinds and force search to
participate in session close, pairing, attention, and persistence semantics.

Primary references, retrieved 2026-08-18:

- Apple, *Keyboard shortcuts in Terminal on Mac*:
  https://support.apple.com/guide/terminal/keyboard-shortcuts-trmlshtcts/2.15/mac/26
- Zed, *Features* and *Built-in Terminal*:
  https://zed.dev/features and https://zed.dev/docs/terminal
- Alacritty search state/rendering:
  `~/Projects/reference/alacritty/alacritty/src/event.rs` and
  `alacritty/src/display/mod.rs`
- Ghostty threaded search and viewport result messages:
  `~/Projects/reference/ghostty/src/terminal/search/` and
  `ghostty/src/renderer/message.zig`

## Search semantics

The searchable representation is terminal text, not pixels and not the raw
byte stream:

- a grapheme cell contributes its base scalar and suffix exactly once;
- a wide spacer contributes nothing;
- soft-wrapped rows are one logical line, so a match may cross a visual wrap;
- a hard line boundary ends a match;
- right-padding cells that do not represent written content are ignored;
- OSC 8 searches its visible label, not its hidden URI;
- Kitty image placeholders and image metadata do not become searchable text.

The v1 query is a single-line literal substring. Matching uses canonical
Unicode equivalence and default Unicode case folding, with a mapping back to
the original grapheme cells for highlighting. libc locale and `wcwidth` are
never involved. Regex, whole-word, case toggles, replacement, and search
history are deliberately absent until actual use proves that the literal
surface is insufficient.

The primary screen searches its complete retained history plus the live
screen. The alternate screen has no history by RFC 0003, so it searches only
the current fixed grid. A TUI repaint may invalidate those alternate-screen
matches; the daemon publishes a new result generation rather than retaining a
hit against text that no longer exists.

Results are semantic ranges anchored by RFC 0003 pins. Reflow, scrolling, and
new rows do not turn a hit into an unrelated location. Eviction invalidates a
hit cleanly. Search never mutates terminal cells, selection, cursor state, or
the byte stream visible to the child.

## Find in Session

`⌘F` opens a small native find bar at the upper-right of the focused pane.
It overlays the Metal surface and never changes the PTY's rows or columns. In
a pair it belongs only to the focused member; in a zoomed pair it belongs to
the visible member. Changing the focused session closes the local search
rather than silently applying its query to a different byte stream.

The bar is the reusable native component specified by RFC 0017. It contains one
`NSSearchField`, a current/total result label, previous and next controls, and a
close control. There is no permanent title-bar button and no options drawer.
While an exact count is still being computed, the counter may show an
indeterminate value; PTY parsing must never wait for it.

Its chrome follows the rest of the native shell: one compact row, a modest
corner radius, and the same separator hairline used by sidebar and pair
boundaries. The field, trailing-aligned count, and borderless controls share
one optical baseline. An empty query shows no result status; `No results`
describes a completed non-empty search only. The standard macOS field focus
ring remains intact. A small six-dot leading grip moves the overlay within the
focused pane. Its position is viewer-local and resets when search closes; it
does not alter terminal geometry or daemon state.

Interaction is fixed:

- `⌘F` opens the bar or focuses and selects its existing query;
- `⌘A` follows the native responder chain and selects the complete query while
  the field editor is focused;
- Return and Shift-Return select the next and previous result;
- `⌘G` and `⇧⌘G` do the same whether the field or terminal has focus;
- Escape closes the bar;
- clicking the terminal returns keyboard focus to the PTY without closing the
  bar, so `⌘G` remains useful;
- closing search leaves the viewport at the selected result.

All matches in the visible viewport receive a restrained highlight. The
selected result receives the stronger treatment and is revealed with context
outside the overlay whenever scrollback permits. At an unscrollable top or
bottom edge, the user can move the overlay by its grip instead of changing the
terminal viewport merely to make room for chrome. Search highlight and text
selection are independent renderer layers; beginning a search never
manufactures or clears a selection.

## Find in All Sessions

`⇧⌘F` places a search field at the top of the existing sidebar and replaces
its rows with results grouped by session in current visual order. Pair members
remain separate sessions inside their shared display-item position. Each
group shows the session title and match count; each result shows a bounded
single-line excerpt around the match.

Selecting a result focuses that exact session, reveals its containing sidebar
item, and moves its viewport to the match. The global result list stays open
so the user can continue comparing hits. Return opens the selected result,
arrow keys traverse results, `⌘G`/`⇧⌘G` advance globally, and Escape exits
global search.

If the sidebar was hidden, global search reveals it temporarily and restores
the prior hidden state when search closes. If it was visible, its prior row
scroll position is restored. Local and global search are mutually exclusive;
invoking one closes the other.

Only sessions currently in the daemon registry participate, including an
exited session that the user has not closed. There is no archived-history or
on-disk search. New output updates matches while the surface is open, but
metadata-only changes never reorder results.

## Ownership and protocol

The daemon owns the complete scrollback and therefore owns matching. Shipping
all retained rows to AppKit would make search latency and memory proportional
to session age, contradict bounded attach. Search state is scoped to the
viewer connection rather than stored as session state: two future viewers may
search the same session independently, and viewer restart discards queries
without changing the PTY.

Attach protocol v11 adds bounded semantic commands for focused-session search:

- start/update/end a viewer-local per-session search;
- select next/previous from a stable semantic result anchor;
- reveal a selected result through the authoritative viewport;
- return bounded counts plus visible match and selected-match masks tied to the
  snapshot's grid generation.

The viewer retains the query and current anchor; the daemon retains no search
state between requests. Each request captures the daemon-owned logical-line
corpus in bounded row batches, performs canonical caseless matching outside
the session mutex, reveals navigation targets through stable grid pins, and
returns highlights only when their generation still matches the rendered
snapshot. Disconnecting a viewer therefore discards its search without daemon
cleanup or any effect on another viewer.

If output changes while those batches are copied or while a detached corpus is
matched, the daemon retries from one generation. After bounded retries it
returns a deliberately stale empty mask rather than failing the refresh
connection: the viewer still presents the latest terminal snapshot, retains
the pending search operation, and tries again on the next invalidation.

All-session search remains a future protocol extension. It will reuse the same
matcher and anchors while adding bounded grouped summaries/excerpts; it must
not ship entire retained histories to AppKit.

The daemon may scan incrementally or on worker threads, but a scan never runs
under the PTY reader's critical path and never blocks input, VT replies, or
snapshot publication. Queries, generations, excerpts, and result batches are
length/count bounded before allocation. Exact counts may arrive progressively;
navigation and the current visible result take priority over counting every
hit.

The GUI receives semantic ranges and excerpts, not another grid copy. The
ordinary render snapshot remains authoritative for cells. Search generations
let the viewer discard stale results after query changes, grid mutation,
eviction, or alternate-screen repaint.

Search queries remain local to the mode-0600 attach socket. They are not sent
to the PTY, written to disk, added to the public control protocol, or logged.

## Acceptance gates

- Find a literal spanning a soft wrap and highlight the correct grapheme cells
  before and after width reflow.
- Canonically equivalent composed/decomposed text matches, and a wide or
  multi-scalar grapheme highlights as one terminal cell range.
- Search a full 10,000-row history without delaying PTY parsing, keyboard
  input, or frame presentation.
- Continue receiving output while scrolled to a result; the viewport is not
  yanked to live bottom and the selected pin remains coherent.
- In a pair, local search touches only the focused member. In global search,
  both members appear independently and a result focuses the correct side.
- Alternate-screen repaint invalidates obsolete hits without exposing primary
  scrollback as if it belonged to the TUI.
- Opening and closing the overlay never changes terminal geometry. Opening
  global search from a hidden sidebar restores the hidden state on exit.
- Disconnecting the viewer releases its search state without affecting any
  session, scrollback, attention state, or foreground process.

## Rejected alternatives

- **Permanent search icon:** spends title-bar chrome on a standard `⌘F`
  action already discoverable through Edit > Find and Keyboard Shortcuts.
- **A bar below the title bar:** changes terminal geometry and makes every TUI
  repaint merely because the user wants to find text.
- **A search session/tab:** mixes a read-only application view into a sidebar
  whose entries promise live PTYs, then inherits irrelevant pair/close/title
  semantics.
- **A full-page global search:** hides the terminal context that makes a result
  useful. The existing sidebar is sufficient for bounded excerpts and leaves
  the selected output visible.
- **Viewer-side scrollback search:** duplicates unbounded daemon-owned state
  and breaks the bounded snapshot/reattach contract.
- **Searching raw PTY bytes:** exposes erased control traffic and cannot map a
  result reliably to the rendered, reflowed grid.
