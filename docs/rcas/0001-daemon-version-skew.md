# RCA 0001: Updated viewer cannot attach to the surviving daemon

Status: resolved
Date: 2026-08-19
Owner: RFC 0019

## Summary

Installing or building a newer Boring Terminal replaces the app bundle on
disk, but it cannot replace an already-running `boringterminald` process. If
the attach protocol changed between those builds, the new viewer connects to
the old daemon's socket successfully, sends a frame in its own protocol
dialect, and has that connection closed by the daemon. Startup then propagates
the failed first request out of `main`, so the app exits while the old daemon
continues to own the socket and the user's sessions.

The sessions are not corrupted or killed. They become inaccessible from the
updated viewer, and the only practical recovery has been to use another
terminal to terminate `boringterminald`. That is a release-blocking lifecycle
bug for a product whose daemon exists to protect long-running work.

The defect was reproduced in the v13-to-v14 development transition. RFC 0019's
negotiation, bounded compatibility capsules, lifecycle protocol, and native
recovery flow now resolve it without weakening the socket stale-file rules.

## Impact

- Boring Terminal may close immediately after an update or local rebuild.
- Existing shells, agents, and builds continue running but cannot be viewed.
- Relaunching repeats the failure because the same daemon still owns
  `daemon.sock`.
- Recovery requires knowledge of the helper process and access to another
  terminal application.
- A user may kill the daemon to recover the GUI and thereby lose every session
  the daemon was preserving.

## Trigger and sequence

1. Viewer and daemon version N are running with at least one session.
2. The app bundle is replaced by a build whose attach protocol is N+1.
3. The old daemon remains mapped and running; replacing its executable on disk
   does not change the process image.
4. `Client.init` connects to the existing socket. A successful `connect(2)` is
   incorrectly treated as a usable daemon.
5. The first `list` request carries N+1 in the `BTD1` frame header.
6. The N daemon's strict frame decoder returns `VersionMismatch` and its
   connection thread closes only that connection.
7. The new viewer observes EOF, marks the client disconnected or propagates the
   startup error, and exits. It never starts its bundled daemon because the
   original socket connection succeeded.

The socket owner is live, so the stale-socket recovery path is correctly not
entered. Starting another daemon would also be wrong: it cannot bind the same
socket and would not own the existing PTYs.

## Root causes

### 1. Connection was used as compatibility detection

The viewer performs no protocol handshake during `Client.init`. Transport
availability and application compatibility are different facts, but startup
treated them as one.

### 2. The protocol has a version, not a negotiation policy

Every frame encoder and decoder is hard-wired to the build's single
`protocol.version`. The daemon rejects every other version before a message can
describe supported versions or a recovery action. The viewer has no way to
select an older dialect even when the schema difference is small and known.

### 3. Fail-closed framing was allowed to become fail-closed application startup

Closing a malformed or unknown connection is correct daemon behavior. Turning
that local connection failure into an unhandled viewer startup error is not.
The safety boundary worked; the lifecycle policy around it was missing.

### 4. Release design assumed the two processes were replaced together

RFC 0012 repeatedly described protocol bumps as having one matching viewer and
daemon build. That assumption conflicts with the same RFC's central guarantee:
the daemon deliberately outlives the viewer and therefore also outlives an app
bundle update.

RFC 0012 also claimed that shared-graphics probing could fall back to an older
attach version. The implementation cannot do that because frame I/O always
uses the compile-time version. That statement described an intended property,
not shipped behavior.

### 5. Tests covered reattach and matching builds, not release skew

The integration suite proves that a viewer can disappear and a matching viewer
can reattach to the same daemon. It does not run a previous public protocol
dialect against the current viewer, nor verify that an unsupported daemon
produces recoverable native UI instead of process exit.

## Contributing factors

- Frequent development protocol bumps made the assumption easy to hit locally.
- The daemon intentionally has no idle shutdown, so even an empty old daemon
  can survive indefinitely and block the bundled replacement.
- A bare `!void` startup path gives protocol/lifecycle errors no typed route to
  AppKit recovery UI.
- No release checklist item exercises an update while a long-running session
  is active.

## What worked

- Strict decoding prevented either binary from misinterpreting a changed wire
  shape.
- Only the offending connection was closed; the daemon, PTYs, VT state, and
  scrollback remained intact.
- Socket ownership and stale-inode rules prevented a second daemon from
  stealing the path.

These properties must remain. The fix belongs in negotiation and lifecycle,
not in weakening frame validation.

## Corrective action

[RFC 0019](../rfcs/0019-daemon-upgrades.md) defines the fix:

- negotiate a mutually supported attach dialect before constructing a client;
- ship v13 and v10 compatibility adapters in the v14 viewer so both retained
  public dialects preserve current sessions;
- keep a small, stable lifecycle handshake independent of the fast attach
  dialect;
- let a lifecycle-capable older daemon drain and replace it automatically only
  when it owns no sessions and has no other attached viewer;
- present a native, preserve-by-default recovery choice when no dialect
  overlaps;
- add release-skew integration and release-acceptance tests.

Automatic termination of a daemon with sessions is explicitly not a
corrective action.

## Prior art

tmux also versions its client/server protocol and rejects mismatches; its
protocol source explicitly requires a version bump when message layouts
change. Reports from tmux users show that an opaque mismatch which leaves a
background server alive is itself a recurring UX failure. Boring Terminal has
a narrower platform and ships both binaries together, so it can provide a
negotiated compatibility window and native recovery rather than exposing that
operational burden to users.

- https://github.com/tmux/tmux/blob/master/tmux-protocol.h
- https://github.com/tmux/tmux/issues/4711
