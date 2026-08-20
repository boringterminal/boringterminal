# RFC 0012: Daemon ownership and viewer attach protocol

Status: shipped

## Objective

Closing or crashing Boring Terminal must not terminate a running shell, agent,
or its scrollback. `boringterminald` is therefore the sole owner of PTYs and VT
state. The AppKit process is a replaceable viewer.

The acceptance test is deliberately blunt:

1. start a long-running command and produce enough output for scrollback;
2. quit the GUI without closing the session;
3. reopen Boring Terminal;
4. the same session, process, title, attention state, viewport, and scrollback
   are available.

Explicitly closing a session is different: it asks the daemon to SIGHUP that
session's process group and remove it from the registry.

## Lifetime and discovery

The app bundle contains `Contents/MacOS/boringterminald`. On connection failure,
the GUI starts that exact sibling executable with stdin/stdout/stderr closed and
in a distinct process group, then retries the socket for a bounded interval.
The daemon ignores SIGHUP and outlives its spawning GUI. This is demand-starting,
not a permanent login item: a reboot loses kernel PTYs regardless, and an empty
daemon restart cannot recover them.

Before accepting connections or spawning a session, the daemon changes its
process working directory to `$HOME`. LaunchServices commonly starts GUI
applications in `/`; that implementation detail must never leak into a user's
login shell. The create request may carry a preferred absolute cwd: the viewer
uses its inherited cwd for the first session when it is not LaunchServices' `/`.
Without that preference, a viewer-created new session inherits the focused
session's foreground-process cwd via
`proc_pidinfo(PROC_PIDVNODEPATHINFO)`, falling back to home if inspection
fails. RFC 0020's validated OSC 7 cwd overrides this heuristic; an explicit
RFC 0007 cwd overrides both.

The socket is
`~/Library/Application Support/boringterminal/daemon.sock`. The containing
directory is mode 0700 and the socket is mode 0600. A stale socket is removed
only after a connection attempt proves no daemon is listening. The control
socket from RFC 0007 remains a separate, human-facing protocol.

## Transport

The private attach protocol is a bounded, little-endian binary stream over a
Unix-domain `SOCK_STREAM` socket. Every frame begins with:

```
u32 magic       // "BTD1"
u16 version     // 18
u16 message tag
u32 payload length
```

Payloads are capped at 128 MiB before allocation. Unknown versions/tags close
the connection; malformed lengths never reach the VT core. Command connections
are strictly request/response, so version 15 needs no request IDs. A second
subscribed connection carries daemon-to-viewer invalidations and never shares a
writer with commands.

The viewer may open more than one command connection because request ordering
is defined per connection. Its sustained-graphics path uses one connection for
latency-sensitive input/control and a separate serialized connection for bulk
snapshot/image fetches. Bulk traffic never sets focus or reorders terminal
input; the daemon remains authoritative and handles both through the same
mechanical command surface.

RFC 0015's shared-graphics optimization, introduced in version 13 and retained
by version 15, is a capability probe within an already selected attach
dialect. A viewer opens a disposable bulk connection
and sends `graphics_attach` as its first frame. A supporting daemon replies
`graphics_ready` and marks that connection graphics-capable. An older daemon
applies the existing unknown-tag rule and closes only that unused connection;
the viewer then opens an ordinary bulk connection in the same dialect and latches byte
image transport for the attachment. The probe is never sent on the interactive
connection or after other work, so optional graphics support cannot make a GUI
upgrade terminate or strand sessions owned by a surviving daemon.
All non-graphics protocol changes continue to require an ordinary version bump.

RFC 0019 owns version negotiation and daemon replacement. A successful Unix
socket connection is not proof of attach compatibility. The viewer selects an
exact mutually supported dialect before constructing its command, bulk, and
event lanes; each lane retains that dialect for its lifetime. RFC 0019 requires
the version-15 viewer to retain v13 and v10 client adapters for the first
pre-negotiation migrations. The v10 capsule translates its older snapshot
shape and reports search/create-beside unavailable; strict frame validation
remains unchanged after dialect selection.

The command surface required by the viewer is intentionally mechanical:

- list/create/close sessions (create optionally carries an absolute initial cwd);
- fetch a render snapshot and an explicitly identified image generation;
- write raw input, submit semantic paste, and resize the PTY/grid;
- set focus (attention clear semantics);
- submit semantic mouse events (the daemon returns whether current VT modes
  accepted the event and queues any encoded bytes as ordinary input);
- submit semantic key events (the daemon consults active-screen Kitty and
  DECCKM state, then queues any encoded bytes as ordinary input);
- clear scrollback and release synchronized-output hold;
- scroll viewport;
- begin/drag/clear selection and read selected text;
- search retained terminal text, navigate an opaque pinned result, and return
  bounded visible highlight masks plus count metadata;
- query whether job control has a foreground process.

Input writes are accepted atomically into a bounded per-session queue. Version
6 retains the 8 MiB viewer-input reservation; a request that does not fit is
rejected with `protocol_error` without accepting a prefix. Semantic paste is
encoded under the terminal lock from authoritative mode-2004 state, then its
complete encoded buffer is admitted atomically by the same queue. An `ok`
response means the bytes are owned by the daemon, not necessarily already
written to the kernel PTY. This keeps PTY backpressure off the AppKit request
path while making overload explicit instead of buffering without bound.

The event stream reports session opened/changed/exited/closed and whether grid,
metadata, bell, or lifecycle state changed. It is an invalidation stream, not a
second state store; the viewer fetches authoritative state after coalescing.
Painting a cached sidebar row never consumes its pending invalidation; only an
authoritative snapshot does. Thus title/attention changes for an inactive
session converge without selecting that session, including while sessions are
being created rapidly.
Losing this auxiliary stream does not by itself mean the daemon died. The
viewer reconnects the subscription and invalidates every local cache after
reattaching; only failure of the command connection enters disconnected mode.

Protocol version 14 retains version 13's display-registry invalidation.
Registry-only changes use reserved session id zero; session create/close may
carry both lifecycle and registry flags. The viewer responds by fetching the
authoritative registry rather than attempting to replay mutations from events.

## Snapshot shape

A session list entry contains stable id, title, exited/working/attention flags,
and order. A render snapshot contains:

- session id, grid dimensions, cursor and viewport position;
- render/input modes needed by the GUI (alternate screen, cursor visibility,
  focus reporting, synchronized output + epoch);
- title and lifecycle/attention flags;
- visible rows as terminal `Cell` values plus selection bits;
- visible Kitty image descriptors and their cell-anchored placements.

The row/cell representation is the renderer's existing semantic input, not a
pixel protocol. Version 9 sends every visible row after an invalidation because
the current renderer also rebuilds every row. Dirty-row subsets may replace
that without changing the wire representation. Full scrollback remains in the
daemon and is exposed by remote viewport/selection operations, so reattach cost
is bounded by the visible grid rather than session age.

## Concurrency

Each daemon session remains address-stable and keeps its existing PTY reader
thread and mutex. The registry lock protects order and lookup but is never held
across PTY I/O or snapshot encoding. Registry membership, the reader, close
escalation, and each command using a session hold explicit lifetime references.
Explicit close removes the registry reference, sends SIGHUP, and starts the
documented grace-period escalation to SIGKILL. The final reference destroys the
VT and session after the reader has reaped the child; retired sessions therefore
cannot accumulate in the long-lived daemon.

The PTY master is nonblocking and one per-session kqueue loop owns both read
and write readiness. Command handlers only copy into the viewer-input queue and
trigger `EVFILT_USER`; `EVFILT_WRITE` drains it when the kernel can accept more.
VT-generated replies use a separate 64 KiB high-priority queue so a child
waiting for CPR/DA cannot deadlock behind a large paste. No daemon connection
thread and no VT-output path performs a blocking PTY write.

Viewer focus is explicit: the selected session is focused only while the window
is key. Disconnect clears that viewer's focus but never closes a session.
Version 6 has one GUI viewer; the protocol leaves focus associated with a
connection so multiple viewers can later mean "focused by any viewer" without
changing attention semantics.

The same focus transition is also the host event for RFC 0002 mode 1004. The
daemon, which owns the authoritative VT mode, emits `CSI I`/`CSI O` only when
the session's logical focus actually changes and reporting is enabled. These
three-byte terminal events use the bounded high-priority terminal queue so a
full viewer paste cannot lose a focus transition. Version 6 retains the
existing `focus` command's wire shape.

## Version 2 grapheme amendment (2026-08-16)

Version 2 replaces each snapshot cell's single `u32` codepoint field with a
length-prefixed sequence of one to 64 Unicode scalar values. The first scalar
is the cell's inline base and any remainder is rebuilt into a snapshot-owned
suffix arena during decode. Blank and wide-spacer cells still encode one space
scalar. Internal arena offsets never cross the socket.

The decoder rejects invalid scalar values, empty or oversized sequences, and
inconsistent wide/spacer flags before exposing a snapshot to the renderer.
The protocol version is bumped rather than adding an ambiguous optional tail:
daemon and viewer ship in one app bundle, and a mixed v1/v2 pair must fail
closed and reconnect after both binaries are updated.

## Version 3 semantic-key amendment (2026-08-16)

Version 3 retains version 2's snapshot representation and adds one bounded
semantic-key command. Its payload is an explicit key tag (plus a Unicode scalar
for character keys), modifier bits, and press/repeat/release action. Native
event or Objective-C struct layout never crosses the socket. The daemon owns
Kitty keyboard negotiation state, so encoding in the viewer from a render
snapshot would be both a duplicated state machine and observably racy.

This additive command still requires a version bump because the viewer uses it
for ordinary navigation keys even while Kitty mode is reset. A new viewer must
not send an unknown tag to a surviving version-2 daemon and discover the
mismatch only after losing its command connection.

## Version 4 graphics-snapshot amendment (2026-08-16)

Version 4 extends each renderer snapshot with bounded Kitty graphics data.
Image records carry image id, monotonically increasing resource generation,
pixel dimensions, and validated straight-alpha RGBA8 bytes. Placement records
carry image/placement ids, the current view-relative cell anchor, and z-index. Counts,
dimensions, byte lengths, ids, and placement references are validated before
allocation or publication. The frame payload ceiling rises from 32 MiB to
128 MiB solely to contain the phase-1 64 MiB image ceiling plus cell state;
the codec remains length-prefixed and rejects larger frames before allocation.

This deliberately simple phase-1 representation can repeat unchanged pixels
across snapshots. Resource generations make a later cache/fetch command an
additive optimization; it must not move image ownership into the viewer or
change the daemon's authoritative placement semantics.

## Version 5 semantic-paste amendment (2026-08-17)

Version 5 adds one bounded semantic-paste command containing a session id and
the raw UTF-8 pasteboard bytes. The daemon consults live mode-2004 state while
holding the terminal lock, applies RFC 0005's control filtering and newline
policy, adds bracketed-paste delimiters when negotiated, and admits the whole
encoded result to the PTY queue atomically. It performs no time-based pacing or
per-line writes.

The render snapshot no longer carries bracketed-paste or cursor-key state.
Those bits were both unnecessary presentation data and unsafe authorities for
input encoding: a viewer can act on an older snapshot after the child changes
mode. As with the semantic-key amendment, the protocol version is bumped so a
new viewer cannot send an unknown input command to a surviving daemon and
discover the mismatch after its command connection is lost.

## Version 6 image-resource amendment (2026-08-17)

Version 6 removes RGBA payloads from render snapshots. Each visible image is
represented by an immutable descriptor containing image id, resource
generation, width, and height; placements continue to reference that exact
identity. A separate bounded fetch command names the session, image id, and
generation and returns the descriptor plus validated straight-alpha RGBA8
bytes. The daemon encodes the response while holding the session lock, so a
concurrent replacement cannot free the source during the copy. It remains the
authoritative resource owner.

The viewer caches fetched resources per session and fetches a generation at
most once while its latest snapshot references it. It validates the response
against the snapshot descriptor before publication. If replacement or eviction
makes a descriptor stale between snapshot and fetch, the daemon returns a
protocol error; the viewer keeps its last coherent frame, leaves the session
dirty, and retries from a newer invalidation. A stale fetch is not a daemon
disconnect.

Renderer texture identity is `(session id, image id, generation)`, because
generation counters are session-local. The active snapshot determines GPU
texture retention, while each session's latest snapshot bounds its CPU cache.
Thus unchanged placement/grid refreshes carry no pixels and trigger no texture
upload, inactive sessions retain reattach-ready decoded bytes only while their
latest snapshot references them, and daemon/viewer memory remains bounded by
the existing resource limits. The 128 MiB frame ceiling remains for a single
maximum-size fetch response, not routine snapshots.

## Version 7 graphics-placement amendment (2026-08-17)

Version 7 expands a placement record from a nonnegative cell anchor and
z-index to complete renderer-ready physical geometry: a signed viewport row,
cell column, within-cell backing-pixel offsets, source pixel rectangle,
destination backing-pixel size, and z-index. The signed row preserves an image
whose anchor has scrolled above the viewport while its lower portion remains
visible. The source rectangle is validated against the referenced image and
the destination rectangle is required to be nonempty before a snapshot is
published. Metal clips the resulting bounded-integer quad to the viewport.

The daemon remains authoritative for image ids/numbers, placement identity,
source/aspect calculations, scroll anchoring, and deletion. The viewer receives
no new command and infers no protocol semantics from pixels. This version bump
also establishes a synchronous graphics-action barrier in the PTY reader: an
APC that performs host lookup/decoding and cursor movement completes before
subsequent bytes from that read enter the VT parser. Without the barrier,
`a=p` followed by text in one kernel read would parse the text at the old
cursor position even though the published protocol moves the cursor.

## Version 8 Unicode-placeholder amendment (2026-08-17)

Version 8 adds each cell's semantic underline color to the snapshot. SGR 58
and 59 are ordinary terminal attributes, and Kitty Unicode placeholders also
encode an optional placement id in that color; reconstructing it from the
rendered foreground would be lossy. The color uses the same validated
default/indexed/RGB representation as foreground and background.

The placement record remains renderer-ready. Before encoding a snapshot, the
daemon scans visible U+10EEEE cells left-to-right, applies the published
diacritic/inheritance rules, resolves an invisible virtual prototype, and
appends a bounded image quad for each contiguous visible run. Source and
destination rectangles are integer backing-pixel geometry, so the viewer does
not parse placeholder Unicode, colors, or Kitty controls. Derived runs are
bounded by the snapshot cell count in addition to the existing 256 retained
physical placements; their count is encoded as `u32` and rejected when it
exceeds `cells + 256`.

## Version 9 display-registry amendment (2026-08-17)

Version 9 makes RFC 0014's bounded paired-session presentation state daemon
owned. The list response contains the complete session-metadata array followed
by an ordered display-item array. Each item is either one session id or a pair
of distinct session ids with a remembered focused member and a normalized
`u16` divider ratio. Decoding rejects unknown item tags, zero/duplicate ids,
pair members absent from metadata, repeated membership across items, invalid
focused members, invalid endpoint ratios, and registries that do not contain
every listed session exactly once.

Five bounded commands mutate that registry: pair two single items, separate a
pair, remember a pair member's focus, set its divider ratio, and move a display
item to an exact ordered index. Pairing names the target/left member first and
the dragged/right member second. All validation and mutation happens under the
daemon registry lock; a rejected command changes nothing. Closing a paired
session collapses its item to the survivor under that same lock, while closing
a single removes its item. Creating a session appends one single item.

The event stream reports only invalidation, never mutation deltas. This keeps a
viewer crash, dropped event, or reconnect from constructing a second registry
state machine. The private GUI protocol still has one compatible viewer and
daemon build; version 9 deliberately fails closed against earlier binaries.

## Version 10 paired-registry manipulation amendment (2026-08-18)

Version 10 adds three atomic mutations required by RFC 0014's direct
manipulation model. `display_swap` exchanges a pair's visible left/right
members while preserving focus by session id. `display_extract` separates one
member and moves it to an exact final display index without publishing the
intermediate two-single arrangement. `display_transfer` collapses a member's
source pair to its survivor and forms a new ordered pair with a target single
as one registry transaction.

Every command validates membership, source/target shape, destination bounds,
side, and focused member under the daemon registry lock before mutation.
Failure leaves order, pairing, focus, and divider ratios unchanged. The event
stream continues to publish only a registry invalidation; reconnect still
fetches one complete authoritative registry rather than replaying drag deltas.
This version deliberately fails closed against a v9 daemon so a viewer cannot
decompose an intended atomic member operation into observable older commands.

## Version 11 focused-search amendment (2026-08-18)

Version 11 adds RFC 0016's bounded `search` request and `search_result`
response. A request names one session, a validated single-line UTF-8 query, a
navigation operation (`initial`, `refresh`, `next`, or `previous`), and an
optional prior semantic result pin. It never sends query bytes to the PTY and
does not store the query in session state. This makes search viewer-local even
though the retained text remains daemon-owned.

The response contains total/truncation metadata, the selected result and its
ordinal when one exists, and two visible-cell masks: all matches and the
selected match. The masks are bounded by the current grid dimensions and are
ephemeral renderer input, not a second scrollback representation. Navigation
atomically reveals the chosen pin before those masks are generated. Refresh
does not move the viewport and preserves the named result only while that pin
still matches.

Search work runs on the requesting command connection, never the PTY kqueue
thread. The terminal mutex is held only long enough to take a bounded semantic
corpus snapshot or apply the final reveal; canonical case folding and matching
run after that snapshot is detached. Large histories are copied in bounded row
batches so PTY parsing and priority replies can proceed between batches. A
grid generation on the corpus/result lets the viewer discard work made stale
by reflow, eviction, or repaint. This version deliberately fails closed
against v10 because treating an unknown search tag as terminal input or an
empty successful result would both be incorrect.

Every row batch belongs to the corpus generation captured before allocation;
if output mutates that generation mid-copy or during matching, the daemon
retries from a fresh descriptor. After bounded retries it returns generation
zero with empty masks. Since real terminal generations never use zero, the
viewer presents the independently fetched current snapshot, preserves its
pending query/navigation operation, and retries on the next invalidation. A
busy PTY can therefore defer search without freezing output or attaching a
torn result to current cells.

## Version 12 atomic pair-creation amendment (2026-08-18)

Version 12 adds RFC 0014's `create_beside` command. The request names an
existing single session and carries the same validated initial geometry and
optional absolute cwd as ordinary creation. The daemon reserves an id and
creates the PTY before taking the registry lock, then appends the session and
replaces the existing single with an ordered pair `(existing, created)` in one
registry transaction. The created member is the remembered focus and the pair
starts at the default equal ratio.

If the existing session was closed, paired, or otherwise ceased to be a
single while the PTY was being created, registration fails, the unregistered
child is torn down, and no session or display item becomes observable. A
successful response returns the new session metadata and publishes one
registry invalidation; observers can therefore see only the old single or the
complete pair, never a transient appended row. Directional pair focus and
side movement continue to use version 9's `display_focus` and version 10's
atomic `display_swap`; persistent zoom is added by version 17.

## Version 13 OSC 8 hyperlink amendment (2026-08-18)

Version 13 extends render snapshots with RFC 0018's semantic hyperlink data.
Each encoded cell carries a snapshot-local `u32` hyperlink id, and a bounded
table contains only identities referenced by visible cells. Snapshot capture
remaps the daemon VT's retained ids to this dense viewer-local namespace; the
viewer never receives the scrollback-wide hyperlink table.

Each table entry carries the explicit OSC `id` (empty for an implicit run) and
the URI. Decoding enforces RFC 0018's printable-ASCII and length bounds,
nonempty URIs, unique identities, and valid cell references before publication.
The renderer and pointer interaction compare only snapshot-local ids and clear
hover state when a snapshot is replaced, so id reuse cannot cross frames. This
version deliberately fails closed against v12 because interpreting the added
cell field as graphics counts would corrupt the remainder of the snapshot.

## Version 14 semantic keyboard amendment (2026-08-19)

Version 14 replaces the fixed phase-1 key payload with RFC 0013's bounded
semantic input transaction. After code/action/modifiers and the primary scalar,
the payload carries optional shifted and PC-101 base-layout scalars followed by
at most 4096 bytes of valid UTF-8 committed text. Decoding rejects non-scalars,
text on release events, nonzero key fields for non-codepoint/non-text keys, and
trailing bytes before the session input queue is touched.

This remains a strict wire-schema bump: a v13 daemon would interpret the added
fields as trailing corruption, while a v13 viewer cannot supply the information
required to truthfully advertise Kitty flags 4, 8, and 16. RFC 0019 prevents
that local framing rule from becoming an application-startup failure. Its v13
adapter lets the current viewer attach to the surviving daemon; the unavailable
phase-2 keyboard fields degrade honestly until that daemon is empty and
replaced.

## Version 15 semantic mouse amendment (2026-08-19)

Version 15 extends the semantic mouse request with unsigned 32-bit, zero-based
pane-local backing-pixel `x` and `y` coordinates after its existing cell
coordinates. The viewer always supplies both representations. The daemon
validates the complete request, then chooses cells, pixels, or no output from
the authoritative mouse modes while holding the session's VT lock. AppKit
points and display scale never enter the pure VT core.

The schema bump is strict because a v14 daemon would reject the new trailing
fields. Version 14 was an unreleased development dialect, so it does not enter
RFC 0019's public compatibility window. The v15 viewer retains only the public
v13 and v10 capsules. Their mouse adapters deliberately emit the frozen
cell-only request; mode 1016 remains unavailable when attached to those old
daemons, which already report it unsupported.

## Version 16 OSC 7 metadata amendment (2026-08-19)

Version 16 appends an optional, bounded absolute working directory to session
metadata. The daemon derives it only from RFC 0020's validated OSC 7 report;
renderer snapshots remain unchanged. Metadata invalidation carries report and
clear transitions, and new-session creation prefers the stored path before its
foreground-process lookup.

The schema bump is strict because older metadata decoders require end of input.
Version 15 was an unreleased development dialect and does not enter RFC 0019's
compatibility window. Retained v13 and v10 metadata adapters translate the
absent field to `null`; their daemons continue using process inspection.

## Version 17 persistent pair-zoom amendment (2026-08-19)

Version 17 appends one canonical boolean zoom flag to every pair in the display
registry and adds `display_zoom`, whose complete payload is a pair member id
and the desired boolean state. Setting zoom also makes that member the pair's
focused member; clearing it retains focus and the saved divider ratio. Swap
preserves the zoomed session by preserving focus identity, while separate,
member extraction/transfer, pair collapse, and fresh pair creation clear zoom
with the pair they replace.

This is an exact-schema bump: older registry decoders require the pair record
to end after its ratio and older daemons do not know the mutation tag. Version
16 was development-only and consumes no public compatibility slot. Retained
v13/v10 registry capsules decode their absent zoom state as false, and the
viewer disables zoom rather than pretending that those daemons can persist it.

## Version 18 OSC 22 pointer-shape amendment (2026-08-20)

Version 18 assigns the two previously reserved bits in the snapshot mode byte
to RFC 0002's four-state pointer shape. No payload grows: text is encoded as
zero, followed by default, pointer, and crosshair. The daemon snapshot remains
the authoritative state so the requested cursor survives viewer replacement
and each member of a split retains its own value.

The dialect bump is still strict. Older decoders required both reserved bits
to be zero and would reject a pointer-shaped snapshot. Version 17 was an
unreleased development dialect and consumes no public compatibility slot.
Public v13/v10 snapshots already encode zero in those bits, so their retained
viewer path truthfully exposes the text default without a legacy terminal
codec or fabricated application state.

## Failure behavior

- GUI disconnect/crash: daemon drops subscriptions and focus; sessions continue.
- Event subscription loss: GUI reconnects and invalidates all cached session
  state; the independent command connection remains authoritative.
- Daemon disconnect/crash: GUI shows a disconnected state and never fabricates
  a blank replacement for an existing session.
- Protocol mismatch/corruption after negotiation: close the offending
  connection; never feed bytes into VT or execute a partial command. Startup
  mismatch is a typed RFC 0019 compatibility outcome, never an unhandled viewer
  error.
- Daemon start race: one process wins `bind`; losers connect to the winner and
  exit without touching its socket.

No persistence across daemon restart or reboot is promised because the PTYs
cannot survive either event.

## Rejected alternatives

- **Replay PTY output on attach.** An unbounded byte log grows forever and
  replay repeats side effects; a capped log silently loses scrollback/state.
- **Move VT parsing back into the GUI.** The session would stop advancing while
  detached and a GUI crash would again destroy authoritative state.
- **Share Terminal memory.** Its allocator-owned slices and locks are
  process-local; a shared-memory object graph would be a more fragile second
  terminal representation.
- **Use the JSON control socket for frames.** RFC 0007 is low-volume and
  human-debuggable. Encoding thousands of styled cells as JSON is needless
  CPU, allocation, and protocol ambiguity.
