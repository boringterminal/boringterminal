# RFC 0019: Daemon upgrades without stranded sessions

Status: accepted

## Objective

Updating Boring Terminal must never make its surviving sessions inaccessible,
silently terminate them, or require another terminal application to recover.

The app bundle and daemon process have different lifetimes. Replacing the
bundle does not update a daemon already resident in memory. The viewer must
therefore treat attach compatibility as a normal negotiated state, not as an
impossible installation error.

[RCA 0001](../rcas/0001-daemon-version-skew.md) records the v13-to-v14
failure that prompted this RFC.

## User contract

On launch after an update, exactly one of these outcomes is allowed:

1. **Current attach.** Viewer and daemon select the current dialect and startup
   is indistinguishable from an ordinary relaunch.
2. **Compatible attach.** The viewer selects a supported older dialect and the
   existing sessions remain usable. Features unavailable in that daemon
   degrade honestly. A lifecycle-capable old daemon is replaced after its final
   session closes and all other viewers detach; the one pre-lifecycle migration
   remains visible and user-triggered.
3. **No compatible dialect.** Before a terminal window is created, the app
   presents a native recovery alert. The default action quits and leaves every
   session untouched. A clearly destructive “Restart Background Service”
   action terminates the old sessions only after explicit confirmation, then
   starts the bundled daemon.

An EOF, `VersionMismatch`, or unknown lifecycle response is never allowed to
escape as an application-startup crash. Repeated launch must not make the
situation worse.

## Two protocol layers

### Lifecycle handshake

The daemon socket gains a small, stable lifecycle protocol distinguished by
the four-byte magic `BTL1`. It is parsed before `BTD1` attach framing and has
its own version, initially 1. It is deliberately independent of terminal
snapshot and input evolution.

Lifecycle requests are bounded request/response messages and expose only:

- daemon product version;
- supported attach dialects;
- current session count;
- active attach-connection count;
- `stop_if_idle`;
- `terminate_all`, reserved for the confirmed destructive recovery path.

No PTY bytes, snapshots, titles, cwd values, environment, or session contents
cross this layer. It is not the RFC 0007 automation surface and is not exposed
over TCP.

The existing mode-0700 support directory and mode-0600 Unix socket remain the
primary authorization boundary. The daemon also rejects a lifecycle peer whose
effective uid differs from its own. Messages and strings retain small explicit
bounds; unknown lifecycle versions and operations close only that connection.

Once shipped, lifecycle version 1 is compatibility infrastructure. It may gain
optional trailing fields under length framing, but its existing operations and
meanings do not change when the attach dialect changes.

### Attach dialect

`BTD1` remains the high-volume, strict binary protocol in RFC 0012. A dialect
number still identifies one exact wire schema; a decoder never guesses at a
payload shape and never accepts a frame under the wrong dialect.

After the lifecycle reply, the viewer chooses the highest dialect in the
intersection of its supported set and the daemon's. Every command, bulk, and
event connection stores that selected dialect and both reads and writes frames
with it. Capability probes such as shared graphics occur only after dialect
selection.

Compatibility is deliberately asymmetric. The current viewer supports its
current dialect and the two preceding public-release dialects. A daemon
normally implements only the dialect it shipped with. The newer viewer is the
process crossing the update boundary, so requiring every new daemon to retain
old viewer schemas would add a compatibility matrix without improving session
survival. An old viewer continues talking to its old daemon; replacement is
forbidden while any other attach connection remains.

Compatibility code is organized by dialect at the codec boundary. Terminal,
renderer, daemon session, and AppKit state do not fork by release. Removing a
still-required viewer adapter is a release decision recorded in this RFC, not
drive-by cleanup during a protocol bump.

Development-only dialects need no compatibility commitment. Before a release,
the release checklist records its attach dialect and updates the compatibility
fixture.

## Evolution framework

The attach protocol is private and may change. Compatibility exists to cross a
running update safely, not to turn the protocol into a permanent public API.
Every wire change is classified before implementation:

1. **Internal change.** No bytes or peer-visible semantics change. Keep the
   dialect number and add no compatibility code.
2. **Optional capability.** Old behavior remains correct and the feature can be
   negotiated before use. Keep the dialect only when an older peer will reject
   or ignore the probe exactly as specified. A new required command is not an
   optional capability merely because the UI could hide its failure.
3. **Exact-schema change.** A field, tag, validation rule, ordering guarantee,
   or required semantic changes. Allocate a new dialect. Do not make the
   decoder lenient and do not infer shape from payload length unless the old
   dialect already defined that extension point.
4. **Incompatible semantic change.** The new viewer cannot translate honestly
   to the previous daemon. Allocate a new dialect, omit the unsafe adapter for
   the affected operation, and enter the explicit update-pending or unsupported
   flow. Session preservation wins over immediate feature availability.
5. **Security retirement.** A known-unsafe daemon dialect may be removed from
   the compatibility set in a security release. The app explains why an update
   is required, still preserves sessions by default on first presentation, and
   never silently kills them.

An adapter converts between one exact released wire schema and the current
canonical client model. It may perform an explicit, documented downgrade such
as sending committed text through bounded raw input. It may not emulate
daemon-authoritative modes from a stale snapshot, accept multiple layouts with
one parser, or add version branches to `src/vt/`, the renderer, or AppKit event
handling. If translation would require any of those, the feature is
unavailable on that daemon.

Each previous-dialect adapter is a viewer-only **compatibility capsule** behind
one selected-dialect dispatch module. The daemon links only the current codec;
stable client code sees only the selected dialect and capabilities. Capsules
are compiled and signed with the application, never loaded dynamically. A
release-window rotation deletes capsules and frozen fixtures that fall outside
the window, registers the newly superseded public dialect, and touches no VT,
renderer, daemon-session, or AppKit code. The required layout and cleanup check
are defined in the operational guide below.

The compatibility budget is two previous **public** dialects, not two previous
product versions and not every historical release. Multiple releases that
share a dialect add no adapter. Multiple experimental bumps between releases
add no retention obligation. Rotation happens only when a public release ships
a new attach dialect. That release must ship frozen fixtures and skew coverage
for every retained dialect. A security retirement may shorten the window under
the rules below.

The practical decision and release checklist lives in
[`docs/references/daemon-protocol-evolution.md`](../references/daemon-protocol-evolution.md).

## First retained migrations: v10/v13 daemons to v15 viewer

The currently deployed daemons predate `BTL1`. The v15 viewer therefore has one
explicit legacy path:

1. attempt a disposable v15 `list` request;
2. if the peer closes on the versioned frame, reconnect and attempt v13, then
   v10, newest first;
3. accept a daemon only after a complete, valid registry response under that
   exact dialect;
4. construct all client lanes with the selected dialect.

The failed v15 probe is harmless: strict v13 behavior closes only that
connection and never changes daemon or session state.

The v13 adapter uses the v13 key-event layout. Inputs representable in that
dialect remain semantic. Committed text that cannot use the phase-1 key shape
uses the existing bounded raw-input command; v14-only alternate-key and
associated-text reporting and v15's pixel-bearing semantic mouse request are
unavailable because the v13 daemon cannot have negotiated those capabilities
truthfully. Snapshots, search, OSC 8, display registry, and shared graphics
retain their v13 shapes. The unreleased v14 development dialect is skipped:
only public dialects consume the compatibility budget.

The v10 adapter uses the same public phase-1 key layout and raw committed-text
downgrade. It additionally translates v10's exact snapshot into the canonical
viewer model with no search epoch or OSC 8 hyperlinks. Focused-session search
(introduced in v11) and atomic **New Session Beside Current** (introduced in
v12) are disabled while attached to v10; neither unknown command is ever sent.
Existing v10 display pairs, graphics, input, scrollback, titles, and ordinary
session creation remain usable.

Attach dialect 16 adds OSC 7 cwd metadata. The current viewer keeps the same
public v13/v10 compatibility window and decodes their frozen metadata shape
through one isolated capsule, translating the absent cwd to `null`. Dialect 15
was development-only, so no v15 codec or fixture enters stable code. The old
daemons retain their foreground-process cwd fallback rather than receiving a
field they cannot understand.

Attach dialect 17 adds daemon-owned pair zoom state and its atomic mutation.
Dialect 16 was development-only, so it adds no capsule or fixture and consumes
no public compatibility slot. Retained v13/v10 registries translate the absent
pair flag to unzoomed; pane-zoom controls are disabled in compatibility mode
because viewer-local emulation would recreate the replacement flicker and lie
about durability. All other pair operations retain their exact old encoding.

Attach dialect 18 assigns the snapshot mode byte's two reserved bits to the
bounded OSC 22 pointer shape. Dialect 17 was development-only, so it adds no
capsule or fixture. Public v13/v10 snapshots contain zero in both bits; the
current canonical decoder therefore obtains the truthful historical text
default without a legacy branch. The compatibility window remains v13/v10.

A v10 or v13 daemon with sessions is not killed merely to enable newer
enhancements. Because those daemons have no atomic `stop_if_idle`, they are not
terminated automatically even after one viewer observes an empty registry:
another viewer could create a session between that observation and a signal.
These pre-BTL1 migrations therefore use the visible update-pending action.
After confirmation, the viewer identifies the connected same-uid helper
through Darwin peer credentials, verifies that its executable is
`boringterminald`, terminates it, waits for the listener to disappear, and
starts the bundled daemon. The panel must warn that sessions opened in another
window will also close. This peer-credential fallback exists only for the
pre-`BTL1` migration.

## Draining and replacement

An older compatible daemon remains the sole owner of its sessions. The viewer
does not copy PTY descriptors, replay output, or fabricate migrated state.

While attached compatibly:

- existing and newly created sessions continue on that daemon;
- the viewer periodically learns the authoritative count from ordinary
  registry invalidations, not a timer;
- while compatibility remains active, the application menu contains
  **Background Service Update Pending…**. It opens a native panel showing the
  running and bundled versions where reported, authoritative session count,
  **Keep Sessions**, and **Restart and Close Sessions…**. A pre-lifecycle peer
  is labelled **Earlier version** with its detected attach dialect rather than
  inventing a product version. The destructive path confirms again;
- for lifecycle-capable daemons, closing the final session closes that viewer
  under the ordinary one-window lifecycle. During termination it closes its own
  attach lanes and requests `stop_if_idle`. The daemon accepts only if no
  session and no other attach connection exists, atomically enters a draining
  state that rejects new attach/create work, then closes its listener;
- if another viewer still owns an attach lane, termination remains immediate
  and leaves the compatible daemon authoritative. The final viewer to detach,
  or the next launch after every viewer has detached, repeats the atomic idle
  stop. The next launch starts the sibling daemon from the new bundle before it
  creates a session;
- a create or attach racing `stop_if_idle` is serialized by the daemon. It
  either wins and stop is rejected, or loses to draining and retries on the new
  daemon;
- a pre-lifecycle v10/v13 daemon uses the explicit menu/panel action rather than
  automatic replacement.

The menu item is status and action, not an attention event. It remains until
replacement and does not interrupt launch or compete with terminal content. A
disabled feature stays disabled rather than being simulated from stale viewer
state.

## Unsupported daemon recovery

If lifecycle negotiation reports no common attach dialect, the viewer returns
a typed `daemon_upgrade_required` result to the AppKit startup layer. It does
not create a partially initialized `Client` and does not mark an arbitrary
connection as a runtime disconnect.

The recovery alert states that the background service belongs to another
Boring Terminal version and that restarting it will end its sessions. If the
lifecycle reply supplies a count, the copy uses that count. The safe/default
button is Quit. The destructive button requires a second confirmation when the
count is nonzero or unknown.

`terminate_all` performs the same bounded HUP/grace/KILL session teardown as
explicit session close, acknowledges before listener shutdown, and never
unlinks a live peer's socket from the viewer. If a pre-lifecycle daemon is too
old for every retained adapter, destructive recovery may use peer credentials
and executable verification, but only after confirmation. Failure to prove
same uid and helper identity leaves the process untouched and reports a normal
native error.

The daemon serializes session creation with entry into destructive draining. A
create already admitted becomes authoritative before teardown enumerates
sessions and is closed through the same ordinary path; a create that loses the
race is rejected. No session may publish after `terminate_all` begins its close
loop.

## Security and failure rules

- Possession of the attach socket already grants complete terminal control;
  lifecycle operations do not claim a weaker trust boundary.
- Socket mode and effective uid are checked even though the containing
  directory is private.
- A PID read from a file or process-name search is never sufficient authority.
- The viewer never unlinks a socket until connection proves there is no live
  listener, preserving RFC 0012's stale-socket rule.
- A malformed lifecycle message cannot allocate more than its fixed bound and
  cannot reach PTY/VT handlers.
- Failure while draining leaves the old daemon authoritative. Failure after an
  acknowledged idle stop may start a new empty daemon; no session can be lost
  in that branch by definition.
- Automatic replacement is allowed only after atomic `stop_if_idle` confirms
  zero sessions and zero other attach connections.

## Testing and release gate

Automated integration coverage must include:

- current viewer/current daemon negotiation;
- current viewer/v10 and v13 fixture negotiation, exact frozen frames,
  snapshot, title, and input;
- v10/v13 downgrade encoding for ordinary keys and committed UTF-8 text;
- v10 snapshot translation and proof that search/create-beside are not sent;
- an empty old daemon draining and being replaced by the bundled daemon;
- `stop_if_idle` refusing both a live session and another attached viewer;
- create and attach racing `stop_if_idle` without loss or duplicate daemons;
- create racing `terminate_all` without a session publishing after teardown;
- update-pending menu state and destructive confirmation copy;
- unsupported and malformed lifecycle peers returning a typed startup result;
- canceling destructive recovery leaving the peer and its socket alive;
- refusal to signal an unverified or different-uid peer;
- confirmed recovery terminating sessions through the normal grace path and
  relaunching cleanly.

Release acceptance starts a long-running command under each retained public
dialect's released daemon, replaces the app bundle, opens the new viewer, and
proves the same child pid and retained output remain usable. It also proves the
visible pending menu state. For lifecycle-capable predecessors, closing the
final old session and reopening the app must prove that the daemon pid and
attach dialect changed to the bundled release. The v10/v13 migrations instead
verify their explicit restart panel because those daemons cannot provide
atomic idle shutdown.

## Rejected alternatives

### Kill the daemon during update or first launch

This makes the GUI open by destroying the work persistence exists to protect.
It is acceptable only as an explicit, confirmed recovery action.

### Run one daemon per attach version

Versioned sockets let the new app launch, but leave old agents running in a
hidden switchboard the new viewer cannot present. Multiple invisible owners,
resource leaks, and ambiguous new-session routing are worse than a bounded
compatibility adapter.

### Hot-transfer PTYs and VT state to a new process

Passing PTY descriptors is possible, but correct transfer also requires an
atomic, versioned checkpoint of the complete VT, scrollback, graphics,
selection, search, attention, and display registry state while reader threads
are quiesced. That is a second persistence format and a much larger failure
surface. The compatibility-and-drain policy achieves lossless updates without
it. Revisit only if daemon-only features routinely require immediate upgrade.

### Keep every historical attach codec forever

This turns a private local protocol into a permanent public compatibility
surface. A bounded released-version window plus a stable lifecycle layer gives
safe recovery without accumulating every old snapshot schema.

### Weaken the frame version check

The existing strict decoder is what prevented state corruption. Negotiation
selects an exact dialect before normal framing; it does not make payload
validation permissive.

## Prior art

tmux provides the closest ownership model: its server retains terminal state,
its client/server protocol has an explicit version, and mismatched binaries
are rejected. The model validates strict framing but also demonstrates why an
opaque mismatch can strand a user at upgrade time. Boring Terminal's bundled,
macOS-only distribution permits the additional compatibility and native
recovery contract above.

- https://github.com/tmux/tmux/blob/master/tmux-protocol.h
- https://github.com/tmux/tmux/wiki/Getting-Started
- https://github.com/tmux/tmux/issues/4711
