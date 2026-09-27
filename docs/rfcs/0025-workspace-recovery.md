# RFC 0025: Restore sessions after daemon loss

Status: accepted (implemented; real reboot/TCC acceptance pending)
Date: 2026-09-27
Research baseline: `7e087e00dc79fae5d6c421dda011166cd352b296`

## Decision

Add a small, daemon-owned workspace checkpoint and a **Restore Sessions**
offer after the daemon loses its sessions, including after a Mac restart or
power failure. “Tabs” are Boring Terminal's existing vertical session rows;
this introduces no horizontal tab bar or general split layout.

Restore session order, local working directories, and bounded two-session
pairs into **new login shells**. Keep live-daemon reattachment automatic and
unchanged. Do not replay commands, resume agents, or imply that a restored
shell is the process that was running before the interruption.

This passes RFC 0000's product test: someone running ten agents can recover
their project locations and session arrangement without reconstructing them
by hand. It does not require agent-specific integrations or another service.

This RFC makes a narrow exception to RFC 0006's exclusion of persistence
across daemon restart/reboot: workspace reconstruction is separate from
process survival. RFC 0019's preserve-live-sessions upgrade policy remains.

## Source behavior at the research baseline

The following are source observations, not inferred product capabilities:

| Area | Current behavior and implementation landmark |
|---|---|
| Ownership | `src/daemon/server.zig:Daemon` owns sessions and the display registry in memory. `run` initializes both empty. |
| Viewer loss | RFC 0012 and `src/shell/daemon_client.zig` separate viewer lifetime from daemon/PTY lifetime. Reopening attaches to surviving sessions. |
| Startup | `src/shell/window.zig` calls `listRegistry`; an empty result immediately creates one shell and then selects the first display item. |
| Cwd | RFC 0020, `Session.copyWorkingDirectorySnapshot`, and `inheritedWorkingDirectory` prefer a valid local OSC 7 report, then inspect the foreground process, then use home. |
| Pairing | `src/daemon/display_registry.zig` owns ordered `single`/`pair` items, left/right IDs, focused member, divider ratio, and zoom. |
| Spawn | `Session.create` creates a fresh VT and calls `Pty.spawn` with the current environment and the user's login shell. Initial cwd is not separately retained as recovery metadata. |
| Focus | `focused_session_id` is cleared on viewer detach; persistence needs a separate last-selected value, not the current key-window focus flag. |
| Shutdown | `stopIfIdle` checks sessions and attachments atomically; `terminateAll` explicitly closes sessions. Neither is a workspace checkpoint operation. |
| Protocol | Current attach dialect is 19, with viewer capsules for public v18 and v13. Disk persistence must not reuse the snapshot wire format. |

There is no durable workspace snapshot in these paths. An app-crash dialog
alone would solve the wrong problem: the daemon already survives that crash.

## Prior art and decisions borrowed

Sources checked 2026-09-27. These are behavior references, not code to port.

| Project | Documented mechanism | Implication for Boring Terminal |
|---|---|---|
| [iTerm2](https://iterm2.com/documentation-restoration.html) | Long-lived servers preserve jobs through GUI crashes; OS restoration recovers window contents. Reboot terminates jobs. | Keep live reattachment distinct from reconstruction after server loss. |
| [VS Code](https://code.visualstudio.com/docs/terminal/advanced) | Separates process reconnection on window reload from process revival on restart; content restoration is separately bounded. | Give each recovery level an honest name and avoid equating a relaunched shell with its old process. |
| [Windows Terminal](https://learn.microsoft.com/en-us/windows/terminal/customize-settings/startup#behavior-on-new-terminal-session) | Persists window/tab/pane layout, profiles, and reported cwd; automatic saves support crash recovery. Pane contents are excluded. | Metadata-only recovery is useful without full terminal serialization. |
| [Ghostty](https://ghostty.org/docs/config/reference#window-save-state) | macOS window-state restoration covers tabs/splits and geometry; cwd restoration depends on shell integration. | Restore the arrangement users recognize, but keep the daemon as authority here. |
| [WezTerm](https://wezterm.org/multiplexing.html) | Multiplexer domains separate terminal sessions from GUI windows. | Existing Boring Terminal daemon ownership is the right foundation; no second multiplexer is needed. |
| [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) and [continuum](https://github.com/tmux-plugins/tmux-continuum) | Resurrect saves session/window/pane arrangement and directories; continuum adds periodic saving and optional restore. Continuum's documented default interval is 15 minutes. | Save continuously, but use short, event-driven metadata checkpoints rather than a long backup interval or command reconstruction. |
| [kitty sessions](https://sw.kovidgoyal.net/kitty/sessions/) | Declarative sessions can capture layout, directories, and program launches. | A persisted workspace description is sufficient; arbitrary saved launch commands are unnecessary for this feature. GPL source is not copied. |

The proposed improvement is the combination: live sessions always win,
recovery is explicit and lazy, pending recovery cannot be overwritten by a
fresh startup, and retrying a restore does not create duplicate shells.

## User experience

When the current daemon exposes a recoverable workspace, show a quiet native
strip above the terminal area, visible even with the sidebar hidden:

> Previous sessions were interrupted. Restore 8 sessions?
>
> Opens new shells in saved folders. Running commands won't resume.
>
> **Restore Sessions** · **Dismiss**

“Interrupted” deliberately covers both abrupt loss and an ordinary reboot
that ends the background service. The app cannot reliably diagnose a power
failure from an absent process. An ordinary GUI quit never produces this
offer while its daemon survives.

- Keep a usable fresh shell available while the offer is pending. Restoration
  appends the old arrangement without closing this shell or any newer work.
  Accepting one extra shell avoids an unsafe “is this shell untouched?” guess.
- Restore order and pairs immediately as dormant entries; start the selected
  entry on demand. Selecting an unzoomed pair starts both visible members;
  selecting a zoomed pair starts only the visible member. Other shells start
  when made visible. This limits startup-script storms and resource spikes.
- Dormant state is explicit in the content area: **Open Shell** and the saved
  directory. Do not reuse the orange attention dot for recovery.
- Use the previous title only as contextual text while dormant. Once started,
  use the ordinary fallback title until new OSC title output arrives. Do not
  pin an old “agent working” title onto a new shell.
- An unavailable directory produces one per-entry explanation with **Open in
  Home** and **Retry**. No recursive parent-directory search and no automatic
  retry loop. Opening a shell may execute its normal startup files; the claim
  is that Boring Terminal never replays a previous foreground command.
- Dismiss durably discards the pending offer. Closing the viewer does not.
  There is no archive browser, history catalogue, new command palette, or
  session-selection wizard in v1.
- A daemon disconnect while the viewer is running keeps its existing content
  disconnected and input disabled. Offer a user-triggered **Reconnect** using
  the normal negotiation path. If the daemon is gone, the newly started
  daemon can offer recovery; never transparently redirect typed input into a
  replacement shell.

## Scope and fidelity

Persist local session identities, display order, pairs, ratio/zoom, last
selected session, contextual titles, and best-known local cwd plus its source
and observation time. Only sessions that were running or dormant are eligible;
an already-exited session is not a command to restart. Removing an exited pair
member collapses the pair to its eligible survivor.

Do not persist PTY handles/PIDs as reconnect authority, terminal bytes,
scrollback, images, selection/search state, command lines, environment
variables, attention/working flags, or agent conversation IDs. Remote SSH and
tmux processes are not recreated automatically. Recovery opens a local shell
at the last usable local cwd. Machine reboot cannot preserve local processes;
remote jobs may independently survive, but this feature does not discover them.

Native window/sidebar preferences keep their existing owner. A new shell gets
dimensions from current window geometry, not an obsolete screen measurement.

## Ownership and durable model

Add `src/daemon/recovery.zig` for pure records/validation/transitions and
`src/daemon/recovery_store.zig` for filesystem work. The existing daemon is
the only writer. AppKit, the renderer, and `src/vt/` never read recovery files.

Dormant entries must be lightweight registry records, not partially initialized
`Session` objects: today's `Session` requires a real PTY and VT. Allocate that
object only on activation. Audit viewer startup, selection, rendering, close,
and daemon session counts for this distinction. Dormant current entries count
as sessions for lifecycle reporting/idle-drain decisions; pending recovery
alone may survive an idle daemon replacement through the store.

Use one versioned JSON envelope, initially `format_version = 1`, independent
of attach dialects. JSON uses Zig's existing facilities. A representative
model, not a frozen codec, is:

```text
Store {
  format_version, revision, owner_epoch,
  current: Workspace,
  pending: Workspace | null
}
Workspace {
  sessions: [{ recovery_id, last_title, cwd, cwd_source, cwd_observed_at }],
  display_items: [Single(recovery_id) | Pair(left, right, focused, ratio, zoomed)],
  last_selected: recovery_id | null
}
```

`recovery_id` is a persistent opaque ID. Runtime session IDs remain allocated
by the current daemon. A recovery ID also serves as the activation idempotency
key; a PID or an old runtime ID never does.

The current workspace represents running/dormant entries owned by this daemon.
Pending entries represent unresolved work from an earlier daemon. On startup,
after exclusive ownership and validation, move the former current workspace
into pending and set current empty **in one committed envelope**. If pending
already exists, combine the sets by recovery ID, preserving the old pending
order followed by newly interrupted work. This is not a history timeline:
there is one unresolved set, and each session appears once. Pending-only
startup must not overwrite itself with an empty snapshot.

Acquire a mode-0600, nonblocking advisory writer lock in the private support
directory, retain its descriptor for daemon lifetime, and mark it close-on-exec.
Do not unlink the lock file. Startup must still respect the existing live
socket owner, including older daemons that do not take this lock. Never touch
recovery state before proving this process is the sole daemon. The lock
serializes new-daemon contenders; socket checks preserve old-daemon authority.

Initial bounds: 4 MiB per envelope, 1,024 total current+pending entries, 512
bytes per title, and the existing 1,024-byte cwd bound. Validate IDs, uniqueness,
pair references/ratios, selection membership, strings, and the whole topology
before exposing an offer. Enforce a depth/allocation bound while decoding.
Never silently truncate a larger workspace: keep the prior valid checkpoint
and expose a once-per-condition “Session recovery is unavailable” status.
These limits bound persistence, not live terminal capacity.

At capacity, the fresh shell must not prevent restoring the saved workspace or
closing sessions to get below the limit. Accept/Dismiss/Close may transition
the last valid saved generation when a complete current capture exceeds the
bound. Preserve every previously saved entry except those explicitly consumed
or removed; do not choose a new truncated subset of live sessions. Keep the
degraded banner visible: changes since the last complete checkpoint, including
an extra fresh shell, are not saved. Once the live+pending count fits, resume
complete checkpoints and notify viewers when degraded status clears, without
marking another checkpoint dirty merely to deliver that notification. This
permits restoring all 1,024 saved entries while
keeping the fresh shell alive, with an explicit temporary durability limit.

## Checkpoint scheduling and power loss

Checkpoint structural changes, cwd/title updates, and last selection; never
checkpoint because terminal cells changed. Coalesce ordinary metadata changes
for 250 ms, with a maximum intended dirty age of 1 s while storage is healthy.
These are scheduling targets, not hard real-time durability promises.

Copy a coherent metadata snapshot under existing short-lived locks and hand
it to one writer. Release registry/session locks before serialization, process
inspection, or I/O. Use monotonically increasing revisions so an older write
cannot replace a newer one. Emit metadata-dirty notifications from the PTY
reader; never perform recovery I/O on that thread.

Persist `recovery.json` through a temporary file in the same directory: bounded
encode, complete write, sync, rename, and sync the directory. Keep one previous
validated generation as `recovery.previous.json`. The primary is authoritative
whenever valid, including when empty; consult the previous generation only if
the primary is absent or invalid. Never choose a nonempty backup over a valid
empty state. Update the backup without moving away the only valid primary.

The exclusive writer reserves one `.recovery-write.tmp` name. Before reuse,
validate any abandoned temporary as an owned, private, single-link regular file
and remove it; reject unsafe objects rather than following or deleting them.
Temporary contents are never recovery authority. Reusing one reserved name
bounds leftovers from repeated abrupt termination, and a subsequent successful
commit/dismiss consumes any abandoned metadata instead of leaving a history of
random temporary files. Do not sweep unrelated filenames or claim secure erase.

Atomic replacement prevents a torn JSON write; it alone does not establish
power-loss durability. Use and test Darwin's `F_FULLFSYNC` where supported,
with checked sync errors and explicit degraded status on failure. Apple
documents the distinction in [fcntl(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fcntl.2.html);
SQLite's [atomic-commit discussion](https://www.sqlite.org/atomiccommit.html)
is the failure-model reference. Do not promise recovery of writes the OS or
hardware never committed.

Explicit close/removal, Dismiss, and restore acceptance use a writer barrier
before reporting durable success. Serialize these transitions with ordinary
mutations without holding PTY locks across disk I/O. On write failure, existing
terminal work remains usable; report the failed durability operation and keep
the pending source. If the user closes a session despite a persistence error,
state explicitly that its old entry may reappear after daemon loss. A
read-only/full disk must not silently claim the removal was saved.

A barrier can fail after primary replacement but before backup/sync completion.
The operation remains unacknowledged and in-memory intent stays unchanged;
either complete generation may be on disk. Queue one debounced reconciliation
from that in-memory intent. If it also fails, retain degraded status and wait
for another metadata change or explicit user operation; never spin on disk
errors. This bounds the interval during which a failed removal might have
omitted a still-open session from the primary, without claiming atomic rollback
or durability when storage itself is failing.

No shutdown hook is necessary to capture work. Signal handlers cannot protect
against SIGKILL or power failure. Do not gate recovery on a “clean exit” bit:
an OS-requested orderly shutdown still destroys valuable live sessions.
Normal explicit closes remove entries; `terminate_all` durably clears current
entries before its acknowledged destructive shutdown, while leaving unrelated
pending recovery alone. Idle daemon replacement preserves pending state.

## Working directories without background permission prompts

Reuse RFC 0020's syntactic URI/local-host validation. Recording an OSC 7 report
must not open/stat the named directory. Retain the effective initial cwd as a
fallback. For unintegrated shells, sample foreground-process cwd at most every
5 s while a session is live, with bounded work spread across sessions; this
metadata lookup must not enumerate/open directories. Unchanged results cause
no writes. Document that these samples can lag an unreported `cd`.

Record the best-known path and its provenance; validate usability only when
the user activates that recovered entry. Resolve local OSC 7, sampled cwd, and
initial cwd in that order before interruption, so reboot needs no dead-process
inspection. Once a recovery path fails, pause the entry rather than scanning
alternatives that might trigger more privacy prompts. Home fallback is explicit.

Never send `cd <path>` as terminal input. Pass an absolute bounded cwd through
PTY spawn. Today's child ignores `chdir` failure; recovery needs a bounded
close-on-exec spawn-status pipe to distinguish cwd/exec failures from successful
spawn and display the actual outcome. Do not infer success from the parent
obtaining a PTY descriptor. A denied path is not retried on timer, refresh, or
viewer reattach. The permission-loop RCA must be considered before enabling
batch recovery so recovery cannot amplify that failure mode.

## Restore transaction and repeated crashes

Acceptance moves pending entries into current as dormant entries in one
durable transaction before spawning anything. Existing current sessions remain.
Repeated acceptance with the same recovery generation returns the existing
result; competing viewers cannot each append the same workspace.

Activation transitions `dormant -> starting -> running` under the daemon's
serialization. Only one spawn is admitted per recovery ID. A failed spawn
returns to dormant with an error and requires an explicit retry. While the
daemon lives, a lost socket response followed by a repeated request returns
the already-created session rather than launching another process.

Disk stores workspace intent, not the truth of live process existence. If the
daemon dies during activation, the next owner offers the entry again. This is
at-most-one activation within a daemon epoch, not an impossible exactly-once
process launch across a machine crash. Since no old command is replayed,
the residual risk is repeating normal shell startup side effects. After a
second interruption, still require a click; never auto-restore into a crash loop.

Closing a dormant entry discards it without spawning. Closing one member
collapses a pair by existing rules. If only one member can start, retain the
other as a dormant error pane; do not silently delete it or claim full success.
Focus restores to the saved eligible member, otherwise the first entry.

## Protocol and implementation seams

This is an exact-schema change under RFC 0019. Allocate the next dialect at
implementation time; do not hard-code a number into this draft. Add typed
recovery status/accept/dismiss/activate requests and registry metadata for
dormant entries. Include a recovery generation/revision in mutations and
publish completion/status changes through existing invalidations. Recovery
is attach-layer work; keep titles, paths, and workspace data out of `BTL1`.

| File | Intended change |
|---|---|
| `src/daemon/server.zig` | Initialize recovery after exclusive ownership; capture metadata; serialize restore, close, drain, and activation. |
| `src/daemon/recovery*.zig` (new) | Bounded records, normalization, disk transactions, revisions, and failure injection. |
| `src/daemon/display_registry.zig` | Reuse existing pair/order invariants; use an explicit import with ID mapping. |
| `src/shell/session.zig` | Retain recovery ID/initial cwd; emit metadata changes without filesystem work. |
| `src/shell/pty.zig` | Report cwd/exec failures reliably; use the normal current login-shell/environment path. |
| `src/daemon/protocol.zig` and selected codecs | Exact new registry/request schema; old dialects report recovery unsupported. |
| `src/shell/daemon_client.zig` | Typed recovery operations and idempotent retry responses. |
| `src/shell/window.zig` | Startup offer, dormant/error content, explicit reconnect, and visibility-driven activation. |
| `src/daemon/integration_tests.zig` | Daemon-loss, duplicate-viewer, disk-failure, and lifecycle coverage. |

Do not force-replace a live old daemon to enable recovery. Its sessions remain
usable, with recovery unavailable until its normal safe upgrade. A first-time
upgrade cannot recover metadata that the previous version never saved.
Unknown future disk versions are preserved and surfaced as unsupported, not
overwritten or heuristically decoded. Version 1 needs no migration; future
upgrades must validate and migrate into a new committed generation.

## Privacy and retention

Use the existing private Application Support directory and mode-0600 files;
reject symlink/nonregular recovery files and verify ownership. Titles and
paths can themselves be sensitive. Persist no command content, credentials,
or environment, never include paths/titles in routine logs, and never sync or
upload this store. Discard/consumption must also scrub obsolete backup metadata
after the primary commit; an interrupted scrub must never resurrect a validly
dismissed primary. This is logical deletion, not a secure-erasure promise.

Use automatic metadata recovery in v1 to keep the config surface small. If
users need a global opt-out, design daemon-owned policy and deletion semantics
explicitly; the existing viewer-only config loader cannot reliably control
unattached daemon persistence by itself.

## Verification and release criteria

| Scenario | Required outcome |
|---|---|
| Close/kill viewer, daemon alive | Same PTYs/PIDs and output reattach; no restore prompt. |
| Kill daemon; separately reboot a test Mac | Offer committed metadata, spawn fresh shells only after acceptance/activation. |
| Kill at each temp-write/sync/rename stage | Load one valid generation; never partial topology. |
| Crash while offer is pending, repeatedly | All unresolved entries remain; new shells do not overwrite old work. |
| Crash after restore commit, before/after spawn | Next launch offers recoverable intent; no automatic restart loop. |
| Two viewers accept/activate; response is lost | One workspace import and at most one live spawn per ID/epoch. |
| Reorder, pair, swap, ratio/zoom/focus; detach | Arrangement survives; detach does not erase last selection. |
| Close final session; explicit destructive service restart | No resurrection of intentionally removed current entries after successful durability barrier. |
| Missing directory, denied folder, failed exec | Per-entry error, explicit retry/home; no timer-driven permission loop. |
| Session runs SSH or an agent at interruption | Local fresh shell; no inferred SSH/agent command execution. |
| Disk full/read-only, malformed/oversized/future schema | Live use remains available, source preserved, truthful recovery status. |
| Old compatible daemon and version-skew upgrade | Existing sessions preserved; recovery feature honestly unavailable. |

Unit-test pure transitions and invalid records; use subprocess integration
with temporary HOME and hermetic shells for kill points and permission-error
injection. TCC Allow/Deny, detached-helper identity, and real reboot tests need
a macOS test account/VM; `chmod` and SIGKILL alone do not prove those cases.
Blocked-activation race tests use a separate, uninstalled daemon test entrypoint
with barriers before spawn and before publication. The ordinary daemon has no
barrier implementation or runtime switch. Destroying a viewer must cancel its
waiting socket promptly; closing or draining an entry during a barrier must
prevent a subsequently created process from publishing or restoring that entry.
After durably removing entries, service drain releases the workspace mutation
lock before its process-exit grace period. Draining still rejects creation and
recovery admission, while an already-running activation can acquire the lock,
observe removal, and reap its unpublished child before daemon exit.
Run `zig build test` and existing attach-skew gates for implementation. Measure
checkpoint latency and shell activation at 10, 100, and the maximum supported
recovery count; confirm no disk writes under output-only workloads.

## Delivery plan and rejected alternatives

Implementation checkpoint (2026-09-27): the bounded model/store, exclusive
writer, metadata capture, repeated-loss preservation, strict cwd/exec status,
and stale-socket handling are implemented. Dialect 20 adds the recovery status,
durable idempotent accept/dismiss, dormant registry, and lazy activation. Its
viewer retains public dialects 19/18 with frozen fixtures. Close now preserves
the session and reports an error when its removal barrier fails. Activation
drops the workspace mutation lock while waiting for spawn/consent, then checks
that the entry still exists before publishing a process. A concurrent close
cannot be undone by a late activation.

The viewer allocates a refresh worker for a dormant entry only when it becomes
visible. Activation uses a separate socket, cancellable when that viewer row
is destroyed. Tests cover concurrent accept/activation, missing/denied cwd,
explicit retry/home, no passive retry after error, dormant close, durable
dismissal, failed close persistence, and retained-dialect feature gating.
The native restore/dismiss banner, explicit reconnect, per-pane errors with
Retry/Open in Home, and persistence-error presentation are implemented. The
banner remains available with the sidebar hidden and adapts to narrow windows.
Session controls use a native titlebar accessory to avoid colliding with the
macOS 26 window title. Activation is pinned to the original daemon owner epoch,
so a replacement daemon cannot receive an activation for a reused runtime ID.

The isolated native smoke harness exercises actual buttons through restore,
zoomed-pair lazy activation, missing-folder retry, Open in Home, abrupt daemon
loss, reconnect, and dismissal. It captures wide/narrow recovery chrome; view
captures do not include Metal terminal contents. Run `zig build app
-Drecovery-ui-smoke=true --prefix zig-out/recovery-ui-smoke`, then
`python3 scripts/test-recovery-ui.py --app 'zig-out/recovery-ui-smoke/Boring Terminal.app/Contents/MacOS/boringterminal'`.
The harness uses a disposable HOME and only kills its fixture daemon.

Source-built public releases 0.5.0/0.6.0 also pass native live-process and idle
upgrade acceptance. Scale checks cover 10/100/1,024 dormant entries, and an
output-only workload leaves checkpoint files unchanged. See
[validation evidence](../references/recovery-validation.md) for commands,
measurements, and limits. These checks do not constitute full feature
acceptance: real reboot/TCC remain pending. Maximum-length escaped strings,
blocked-activation cancellation/close/drain races, and native startup with
1,024 saved entries plus the extra fresh shell now have passing coverage.

1. Implement/test the bounded checkpoint store and daemon capture, including
   failure injection, without a user-facing restore claim.
2. Add the new registry/protocol state and idempotent dormant activation;
   retain released compatibility capsules under RFC 0019.
3. Add the native recovery offer and reconnect path; complete permission,
   power-loss, and upgrade acceptance before enabling the feature by default.

The clean boundary is small metadata persistence plus registry lifecycle work.
The subtle work is durable removal, repeated-crash handling, and avoiding
duplicate spawns; a one-file “save tabs on quit” patch is insufficient.

- **App-only clean-exit flag:** app crashes do not imply daemon loss, and
  unattached sessions continue changing. Wrong owner and wrong trigger.
- **Save only at shutdown:** cannot handle sudden power loss or SIGKILL.
- **Automatic restore of every shell:** startup scripts and bad saved paths can
  generate storms; explicit acceptance and lazy activation bound the effect.
- **Replay commands or agent-specific resume:** can repeat side effects and
  violates the standard-protocol/no-agent-adapter product boundary.
- **Serialize the entire VT:** much larger disk/privacy/migration surface;
  scrollback is separable future work and cannot recreate a kernel process.
- **launchd restart as persistence:** restarts an empty owner; it cannot recover
  its lost PTYs. Keep the existing demand-start mechanism.
- **SQLite initially:** sound transactional prior art, but a small whole-record
  checkpoint fits existing Zig facilities. Reconsider if the pending/current
  transaction rules become more complex; do not invent an append-only database.

## Remaining review decisions

The proposal recommends metadata-only recovery, a single unresolved workspace,
explicit acceptance, and lazy activation. Before acceptance, validate native
placement of the recovery strip and dormant panes, the 1,024-entry bound, and
sync cost on supported Macs. Full scrollback/history and process resurrection
are separate proposals, not hidden prerequisites of this one.
