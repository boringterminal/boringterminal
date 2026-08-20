# RFC 0009: Live resize — real-time re-layout, transactional presentation

Status: accepted

## Problem

During a live window resize, Boring Terminal does not re-render: the compositor
stretches the last presented frame, so the user sees a frozen, distorted
snapshot of the old grid for the whole drag. Only on mouse-up does the
terminal recompute cols×rows, signal the shell, and draw the new layout.
Alacritty and Ghostty re-render on every frame of the drag: grid dimensions
track the mouse continuously, SIGWINCH fires as the drag proceeds, and
running programs (prompt, vim, htop) rewrap in real time.

## Root cause

During a live resize AppKit runs inside a window-server transaction. A
CAMetalLayer presenting **asynchronously** (`presentDrawable:` + `commit`,
our steady-state path) has its frames decoupled from that transaction — the
window server composites the old contents, scaled to the new window size,
until the transaction ends. No amount of extra async frames fixes this;
the presentation mode is wrong for the duration of the drag.

## Design

Two presentation modes, switched by the NSView live-resize lifecycle:

1. **Steady state (async):** encode, `presentDrawable:`, and `commit` into
   RFC 0004's bounded three-slot frame ring. Completion handlers reclaim
   slots; there is no steady-state main-thread GPU wait.
2. **Live resize (transactional):** on `viewWillStartLiveResize` set
   `layer.presentsWithTransaction = true`. Every frame-change notification
   then runs the presentation half of the pipeline synchronously on the main
   thread:
   - recompute drawableSize, cols×rows from the new bounds
   - publish the newest desired cell and pixel geometry to the session resize
     mailbox; the session worker coalesces superseded sizes and performs the
     daemon resize, `Terminal.resize`, and `TIOCSWINSZ` away from AppKit
   - build + encode the frame, then `commit` → `waitUntilScheduled` →
     `[drawable present]`, which lands the frame *inside* the current
     transaction — this ordering is the Apple-documented pattern for
     resize-synchronized CAMetalLayer presentation.
   On `viewDidEndLiveResize`, flip back to async and schedule one settle
   frame at the final size.

## What "real-time re-layout" means before reflow exists

Programs that repaint on SIGWINCH (shell prompt, vim, htop — i.e. whatever
is live on screen) re-layout continuously during the drag. Text that
nothing repaints (scrolled output on the primary screen) clips/pads at the
new width, because reflow is milestone-3 work (RFC 0003). This RFC fixes
*when frames appear*, not *how history rewraps*; the two must not be
conflated when testing.

## Rejected alternatives

- **presentsWithTransaction always on:** couples every frame to a
  transaction commit and adds main-thread waits in steady state; the cost
  belongs only to the drag.
- **Debounced resize (resize once on mouse-up):** explicitly the behavior
  users report as broken; rejected.
- **CVDisplayLink-driven redraw as the resize fix:** cadence alone still
  presents asynchronously and does not put frames in the transaction. The
  display link may bound scheduling, but transactional presentation remains
  the mechanism that fixes stretching.

## Costs accepted

- `waitUntilScheduled` blocks the main thread once per drag frame; bounded
  by the frame ring and small grids. Acceptable; revisit only if drag latency
  is measurably bad (RFC 0004 measurement stance).
- The child may observe fewer SIGWINCH events than AppKit frame-change
  notifications when a newer geometry supersedes one that the worker has not
  applied yet. The final geometry is never dropped.

## Duplicate-geometry amendment (2026-08-20)

AppKit may emit more than one frame-change notification for the same terminal
geometry during a live resize. Those duplicate notifications still redraw in
the current window-server transaction, but they do not send a resize command,
mark the daemon snapshot dirty, or force synchronized output to end. None of
those actions describes a resize when the rows, columns, and pixel dimensions
are unchanged, and the synchronous command round trip adds avoidable drag
latency.

A real geometry change retains the behavior above: update both cell and pixel
dimensions, request SIGWINCH, and present a frame transactionally.
Graphics-heavy clients may still need to rebuild a large surface at each real
geometry change; that client work is not hidden by reporting stale dimensions.

## Coalesced-resize amendment (2026-08-20)

AppKit resize callbacks must not wait for daemon IPC. Each session has a
single-slot resize mailbox owned by its existing refresh worker. Publishing a
new size replaces an unapplied older size. The worker applies the newest size,
then fetches a snapshot tagged with the geometry generation that the daemon
has acknowledged. If another size is already pending, it skips the snapshot
that would immediately become obsolete and applies the newer size first.

Stopping a refresh worker drains the final pending resize before exiting. This
is required because daemon sessions outlive the viewer and persist their last
geometry. Cell and pixel dimensions both participate in duplicate detection;
Kitty graphics clients use the pixel geometry even when the grid dimensions do
not change.

The renderer must continue presenting during the interval between publishing a
desired geometry and receiving its coherent snapshot. It draws the last
coherent snapshot into the current pane rectangle, clipped or padded rather
than scaled. Geometry-dependent interaction layers are withheld during that
interval: the terminal cursor, IME preedit, hyperlink hover, and synchronized-
output hold are not valid at stale cell coordinates. Once the coherent
snapshot arrives they return on the next frame.

Rejecting the whole frame while geometry is pending is forbidden. It leaves
the compositor with an old drawable to rubber-sheet and can expose a blank
layer when drawable size changes. A slightly old but internally coherent frame
is the correct double-buffered fallback.

### Prior art

- Ghostty's AppKit view forwards backing-pixel changes into its surface; the
  surface queues terminal resize work to its I/O thread and renderer size work
  to its dedicated renderer thread rather than doing both in the view callback.
- Alacritty records the newest pending dimensions in its window event path,
  consumes the coalesced update later, and resizes the renderer immediately
  before drawing. It also suppresses PTY resize events when terminal dimensions
  are unchanged.

The exact threading structures differ because Boring Terminal owns sessions in
its daemon. The transferable rule is that the native window callback publishes
geometry and presents; it does not synchronously round-trip through the PTY
owner.

## Test plan

Automated: the resize mailbox retains only its newest unpublished geometry and
the applied geometry generation, not the desired generation, tags snapshots.

Manual (no automated harness for window-server behavior): drag-resize with
(a) a prompt, (b) vim with wrapped text, (c) htop running — content must
re-layout during the drag with no stretched-snapshot or blank phase; cols×rows
must settle to the final size. Repeat with a full-width Kitty-graphics client:
the prior coherent frame may clip/pad briefly but must never stretch. Regression
check: steady-state typing latency feels unchanged after the drag ends.
