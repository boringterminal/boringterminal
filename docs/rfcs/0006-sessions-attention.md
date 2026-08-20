# RFC 0006: Sessions, attention routing, and the daemon

Status: accepted

This RFC is the product (RFC 0000). Everything here must stay cheap because
the credibility work (RFC 0002/0003) is expensive.

## Sessions and the sidebar

- One vertical sidebar on the left, hidden or shown with ⌘B. No horizontal
  tabs or general pane tree: this is navigation, not a layout system. RFC 0014
  defines the sole exception, a non-nesting two-session side-by-side pair that
  occupies one sidebar row.
- A row shows: an actionable-attention dot and title. Nothing else. No
  previews, thumbnails, idle mark, spinner, or generic working indicator;
  agent TUIs already communicate their internal working state better.
- Ordering: manual drag + optional "attention floats to top" (config bool —
  earn this one exception by using it before deciding).
- Groups: a flat one-level grouping (e.g. per project) with header rows.
  Collapsed groups aggregate attention. No nesting.
- Keyboard: ⌘1..9 jump, ⌘⇧[ ] cycle, ⌘B toggles the sidebar, ⌘W closes
  the active session, and ⌘J fuzzy-jumps by title (this is the command
  palette; there is no other command palette). RFC 0014 adds the bounded
  pair-only creation/focus/move/zoom vocabulary; RFC 0016 adds focused and
  all-session search. Neither introduces a general pane or command system.

## Implementation staging (amended 2026-08-16)

Milestone 4 lands as vertical slices while preserving the daemon boundary:

1. **In-process session ownership.** A stable, heap-allocated `Session` owns
   one PTY, one VT state machine, its lock, title, and lifecycle state. A
   `SessionManager` owns the ordered registry and active index. The single
   window renders and sends input only to the active session; inactive
   sessions continue parsing output without consuming GPU work. Window
   resizes apply to every session so switching never reveals a stale grid.
   ⌘T creates a session and ⌘1..9 selects by position.
2. **Sidebar and attention.** Expose the registry visually, add cycling and
   lifecycle controls, then derive attention state from the standard signals
   below. This validates the product interaction before IPC is introduced.
3. **Daemon extraction.** Move the same session registry and authoritative VT
   state into `boringterminald`; replace the in-process references with the
   attach protocol without changing sidebar semantics.

Until slice 3 ships, quitting the app still hangs up all sessions. This is an
explicit intermediate state, not the final lifetime contract.

The presentation uses a restrained native visual-effect rail at the left with
compact vertical rows. Its default width is 160 points. A native divider makes
that width directly resizable from 140 through 280 points, further clamped so
the terminal always retains RFC 0005's minimum 20 columns. This is transient
macOS interface state, not a config-file option: the preferred width persists
in user defaults, survives hiding/showing the rail, and is restored when a
temporarily narrow window can accommodate it again. Double-clicking the
divider resets the preference to 160 points.

Dragging the divider participates in RFC 0009's live-resize path. AppKit
geometry follows the pointer continuously, while the daemon receives a resize
only when the terminal crosses a cell boundary; no point-by-point SIGWINCH
storm is introduced. The divider has a forgiving invisible hit target and a
restrained one-pixel visual separator, with the native horizontal-resize
cursor.

Each full-row click target shows its current title and exited state at stable
horizontal positions. Selection is a subtle adaptive background—never an
inline glyph—so switching cannot move the label. Dots are reserved exclusively
for attention and occupy their own fixed column. The terminal's Metal surface
occupies the remaining content area. Sidebar visibility is persisted as a
native per-user preference. Groups, drag ordering, and attention decoration
layer onto these same rows.
When the rows exceed the rail height they live in a native vertical scroll
view, retain their fixed pitch, and clip instead of collapsing onto one
another. Trackpad/wheel scrolling stays local to the rail. Selecting through
click, ⌘1…⌘9, or ⌘⇧[ / ⌘⇧] scrolls only as far as needed to reveal the active
row; background metadata updates never pull the user's browsing position.
Shortcut hints are hidden by default. Holding ⌘ reveals a fixed overlay badge
(`⌘1`…`⌘9`) for each eligible session in visual order; RFC 0014 places one in
each member segment of a pair. Releasing ⌘ hides them. The overlay never
reflows or shifts the title.

Any pointer-hovered row reveals a fixed trailing close target; it uses the
same close action as ⌘W and never displaces the title. Closing a session
sends its process group SIGHUP and selects the next row at that position, or
the previous row when the closed session was last. Closing the only session
closes the window and follows the normal application-termination path.
Before that destructive step, a native warning is shown only when the PTY's
foreground process group differs from its login shell process group. Thus an
idle prompt or an already-exited session closes immediately, while an active
foreground command gets an explicit Close Session / Cancel choice.

Two native icon-only controls sit in the title bar immediately after the
traffic lights: Boring Terminal's embedded sidebar glyph toggles the rail and
its plus glyph creates a session. The monochrome vector templates use native
appearance tinting but do not depend on the SF Symbols catalogue. The controls
invoke the same ⌘B and ⌘T actions exposed by the menus, include native
tooltips/accessibility labels, and do not introduce a general toolbar.

## Attention states (the whole feature)

Derived exclusively from standard sequences — never from parsing agent
output (RFC 0000 principle 2):

| State | Signal |
|-------|--------|
| **idle** | OSC 133 B..C never entered, or last command finished + prompt shown (133 A/D) |
| **working** | OSC 133 C seen, D not yet (tracked internally; not rendered) |
| **needs you** | BEL, OSC 9 / OSC 777 notification, or 133 D with nonzero exit, while unfocused |
| **exited** | child reaped |

Unfocused "needs you" appears in the sidebar and the Dock badge count.
Focusing the session clears it. OSC 9/777 are attention inputs, not an
instruction to mirror every event into macOS Notification Center: doing so
duplicates agent-owned notifications and turns BEL/failed commands into spam.
The quiet surface → aggregate → clear pipeline is the entire agent story, and
it works identically for Claude Code, cargo build, and a bare zsh. Native
notifications are deliberately absent until real use proves these surfaces
insufficient.

When the sidebar is hidden, its existing title-bar toggle carries one small
orange attention badge if any session needs the user. It is an indicator, not
a third button: clicking it opens the sidebar, where per-session dots identify
the source. The Dock badge retains the aggregate count while the app is in the
background.

The sidebar dot is deliberately narrower than an agent's own status UI: it
appears only for an actionable signal received while that PTY is unfocused.
Working/idle state remains useful for exit routing and prompt-safe reflow but
does not add duplicate chrome.
Here, focused means both selected and inside the key Boring Terminal window.
If the whole app is behind another application, its selected session is also
unfocused and may raise attention. Returning to the window clears only the
selected session.

Shells/agents that don't emit OSC 133 degrade gracefully: no working/idle
inference, bell and title still work. Boring Terminal consumes the standard
sequence but does not install, inject, or maintain shell-specific hooks. Users
who want prompt marks may use their shell's existing OSC 133 integration.

**OSC 133 is also the resize-repaint fix.** zle repaints after SIGWINCH
relative to its *stale* layout; at the width step where the prompt's
wrap-height changes, it prints the new prompt one row off and orphans the
old paint — the duplicated-prompt artifact every reflowing terminal shows
with zsh. With prompt-start marks, reflow clears from the last mark and
lets the shell repaint into clean rows (kitty's shell-integration
behavior). Implement this as part of the 133 work: a prompt mark is a pin
(RFC 0003), and resize invalidates the marked region.

Concrete algorithm (implemented with milestone-4 groundwork): when a
width-changing reflow runs while the shell is at a prompt (state
`prompt`, valid mark, primary screen), the rows from the mark to the
screen bottom are **dropped** from the rewrap — they are prompt paint the
shell will redraw. In their place, blank rows are appended and the cursor
is placed to **preserve its row offset from the mark** (old cursor row −
old mark row). zle's SIGWINCH repaint moves up by exactly that stale
offset before reprinting; preserving it lands the repaint on the fresh
mark row every time, killing the duplicate-prompt artifact for
integrated shells. Unintegrated shells keep today's parity behavior.

## Titles

Before a child emits a title, every session is presented as `Boring Terminal`.
Daemon session ids are stable internal identities, not user-facing ordinal
labels: closing sessions and opening another must never produce names such as
`Shell 8` or imply missing sidebar rows. OSC 0/2 replaces the fallback row and
window title (agents already emit it). User rename pins the title (OSC updates
show as subtitle/tooltip); a pin beats the stream.

## The daemon

The single worst failure mode this product could have: closing a window
kills an agent 40 minutes into a task. Therefore sessions outlive windows.

- `boringterminald`: owns PTYs + `vt` state per session (parsing happens here, so
  scrollback/state persist unattached). The bundled helper is demand-started by
  the app into its own process group and listens on a mode-0600 Unix socket in
  `~/Library/Application Support/boringterminal/`. Launchd adds no recovery:
  after daemon failure the kernel PTYs are already gone, so restarting an empty
  process is not session persistence.
- The app is a *viewer*: attaches to sessions, receives grid deltas /
  snapshots, sends input. Close the window → session keeps running; reopen →
  reattach with full scrollback. Quit the app → same.
- Protocol between app and daemon is internal and versioned, but design it
  as "snapshot + incremental damage", i.e. the same shape the renderer
  already consumes (RFC 0004). Do not invent a second representation.
- Unattached sessions still track attention; the state appears when a viewer
  attaches again. The daemon does not post macOS notifications.
- Crash isolation bonus: renderer/app crash never kills sessions.

Cost acknowledged: the daemon split is real complexity (two processes, a
protocol, reattach). It is scheduled for milestone 4 — but the PTY/vt module
boundary that makes it possible is drawn in milestone 1 (RFC 0005).

## Resolved decisions

- The daemon owns the authoritative grid. Attach sends a row-oriented viewport
  snapshot while the daemon retains the complete scrollback; viewport and
  selection commands operate remotely. Version 1 may resend all visible rows
  after a coalesced invalidation, then narrow that same encoding to dirty rows.
  Replaying an unbounded byte stream on attach is rejected.
- Session persistence across daemon restart or reboot is out of scope: a PTY
  cannot survive its kernel process.
- The first daemon session starts in the viewer's inherited process working
  directory when launched from a terminal. LaunchServices' synthetic `/` is
  treated as "no cwd" and falls back to `$HOME`. ⌘T inherits the focused
  session's foreground-process working directory using macOS process metadata,
  again falling back to `$HOME` if inspection fails. OSC 7 will replace the
  process lookup when a shell reports a newer authoritative cwd. RFC 0020
  defines the OSC 7 report, validation, metadata, and fallback behavior. Explicit
  per-session cwd/env enters through `term open --cwd` in RFC 0007 and
  overrides these defaults.
