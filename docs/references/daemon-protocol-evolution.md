# Daemon protocol evolution

Working rules for changing the private viewer/daemon boundary. RFC 0012 owns
the attach protocol; RFC 0019 owns update compatibility and recovery.

## Terms

- **Lifecycle protocol (`BTL1`)** — small stable discovery, idle-stop, and
  confirmed recovery surface. It does not carry terminal data.
- **Attach dialect (`BTD1`, version N)** — one exact high-volume wire schema.
- **Capability** — optional behavior whose absence leaves the old behavior
  correct.
- **Adapter** — current-viewer codec/translation for one retained public attach
  dialect.

Do not call a product version, attach dialect, and capability version the same
thing in code or documentation.

## Decide before changing code

Answer in order:

1. **Do peer-visible bytes or semantics change?**
   - No: no dialect bump.
   - Yes: continue.
2. **Can the feature be absent while all existing behavior remains correct?**
   - Yes: use an explicit capability or sacrificial probe with specified old
     behavior.
   - No: continue.
3. **Did the old dialect already define a bounded extension point whose decoder
   ignores the new field?**
   - Yes: use it and test both shapes.
   - No: bump the attach dialect.
4. **Can the current viewer translate the operation to a retained public
   daemon without guessing authoritative state or lying about support?**
   - Yes: add one exact adapter.
   - No: gate that operation and use RFC 0019's visible compatibility state.

Payload length is not an extension point by itself. Current decoders commonly
require `finish()`, so appending bytes normally requires a new dialect.

## Adapter boundary

Keep the current in-memory model canonical. An old-dialect module may:

- encode current requests in the old exact layout;
- decode old responses into current owned values;
- report a capability unavailable;
- perform a documented semantic downgrade that does not consult stale state.

It may not:

- make one decoder accept several layouts;
- branch terminal or renderer behavior on daemon version;
- reconstruct daemon modes from a viewer snapshot;
- silently discard an input the user expects to reach the PTY;
- fabricate new fields with plausible defaults;
- retry a mutating request under another dialect after delivery is uncertain.

Prefer a visibly small dialect module over scattered `if (version < N)` checks.
The client stores the selected dialect once and every command, bulk, graphics,
and event lane uses it for its complete lifetime.

### Compatibility capsules

Legacy support lives in a removable viewer-only capsule:

```text
src/daemon/
  lifecycle.zig             # stable BTL1 negotiation
  protocol.zig              # current canonical wire codec
src/shell/daemon_protocol/
  selected.zig              # the only current/retained dispatch point
  compat/
    v13.zig                 # one exact retained public dialect
    v10.zig                 # second retained public dialect
src/shell/daemon_protocol/fixtures/
  v13/                      # embedded frozen frames for the skew fixture
  v10/
```

The exact filenames may follow the implementation's natural Zig package
boundary, but the dependency direction is mandatory:

```text
viewer client -> selected dialect -> current codec OR one retained capsule
daemon        -> current codec only
compat capsule -> current canonical value types
```

Stable code sees a small selected-dialect value and capability result. It does
not import `v13`/`v10`, switch on numeric versions, or know downgrade details. The
single dispatch module may switch between `current` and retained capsules;
nowhere else may do so. The daemon build must not link compatibility capsules.

Capsules are ordinary reviewed source compiled and signed into the viewer.
They are not plugins, dynamically loaded libraries, downloaded code, or files
selected from user configuration. Keeping them in the normal build preserves
reproducibility and avoids turning protocol compatibility into a code-loading
surface.

When a release rotates the compatibility window, cleanup is mechanical:

1. delete capsules and frozen fixtures falling outside the three-dialect
   window;
2. add the newly superseded public dialect capsule and fixture if the dialect
   changed;
3. update the one `selected.zig` registration;
4. update RFC 0019's retained-dialect record and release-skew test;
5. prove the current daemon binary still contains no legacy codec path.

If cleanup requires edits throughout stable client or product code, the
capsule boundary has failed and must be repaired before release.

## Compatibility budget

- Current viewer: current dialect plus the two preceding public dialects.
- Current daemon: its own dialect. Older-daemon compatibility is a viewer
  concern because the daemon is the process surviving an update.
- Development-only dialects: no retention promise.
- Unchanged dialect across releases: no new adapter.
- Rotation is triggered by a public attach-dialect change, not by an app
  release that reuses the current dialect.

The adapter is not removed merely because the current code no longer uses its
types. Removal happens at a release boundary, is recorded in RFC 0019, and
leaves the lifecycle recovery path intact.

The current retained-dialect record is:

| Role | Dialect | Public releases |
| --- | ---: | --- |
| current | 18 | v0.5.0 (development v14/v15/v16/v17 were never public) |
| retained | 13 | v0.4.0 |
| retained | 10 | v0.2.0, v0.3.0 |

## Feature availability

Every daemon-backed feature introduced with a dialect bump records:

- minimum attach dialect;
- whether compatibility mode disables it or has an honest downgrade;
- whether the UI needs any explanation beyond the global update-pending state;
- tests proving the old daemon never receives the new tag or layout.

Do not add per-feature warning spam. The one update-pending application-menu
item explains the compatibility state; controls for unavailable features are
absent or disabled according to the owning feature RFC.

## Release workflow

Before publishing a release that changes the attach dialect:

1. Record the new dialect and wire change in RFC 0012.
2. Classify the change using the decision tree above.
3. Amend the owning feature RFC with its compatibility behavior.
4. Freeze the newly superseded public dialect fixture and retain the other
   in-window fixture.
5. Implement the current-viewer adapter or explicitly document why honest
   translation is impossible.
6. Run matching-build tests and every retained-dialect skew suite.
7. Manually update over a live long-running session and prove the same child
   pid, scrollback, title, graphics, and input remain usable.
8. Verify the update-pending menu panel, safe dismissal, destructive
   confirmation, and automatic idle replacement where supported.
9. Update the local `LOOP.md` when present and the release notes. Users need the visible consequence,
   not internal protocol numbers.

## Required skew tests

- negotiation never treats `connect(2)` success as compatibility;
- a rejected probe changes no session or daemon state;
- old responses decode under only their exact dialect;
- downgraded requests preserve user-visible meaning;
- unsupported operations are never transmitted;
- disconnect during negotiation returns a typed startup outcome;
- another attached viewer prevents automatic daemon replacement;
- canceling recovery leaves the daemon, socket, and child pids untouched;
- confirmed recovery cannot signal an unverified peer;
- the first new session after idle replacement uses the bundled daemon.

## Breaking changes are allowed

Compatibility is a crossing, not a veto. Allocate a new dialect whenever
strict correctness needs one. If an honest adapter is cheap, retain it within
the two-dialect window. If it is unsafe or would infect core code, do not build
it: preserve the old sessions, show the pending state, and let the user choose
when to restart.

Security fixes may retire a dialect immediately, but still use native recovery
and never silently terminate sessions. State the risk precisely; do not use
“security” as a shortcut around the compatibility analysis.
