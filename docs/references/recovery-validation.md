# Workspace recovery validation

Local acceptance evidence, 2026-09-27, macOS 26.2 arm64, Zig 0.16.0 Debug.
RFC 0025 owns the requirements; RCA 0002 owns the unresolved permission incident.
These measurements are individual local samples, not latency guarantees.

## Automated backend coverage

`zig build test -Dportable-system-goldens=true` covers bounded parsing, private
atomic storage and injected publication failures, repeated daemon loss,
concurrent accept/activation, dormant close, failed close barriers, explicit
retry/home, and rejection of activation addressed to a different daemon epoch.

The scale test seeds a checkpoint, starts a real daemon, accepts the saved
workspace, and verifies every entry is dormant. It then activates one entry and
verifies all others remain dormant. No 1,024-shell burst is needed.

| Saved entries | Checkpoint bytes | Accept including durable commit | Activate one shell |
|---:|---:|---:|---:|
| 10 | 2,059 | 12 ms | 4 ms |
| 100 | 18,889 | 34 ms | 3 ms |
| 1,024 | 193,577 | 250 ms | 3 ms |

These samples use ordinary short titles and cwd paths. An additional case uses
1,024 entries with maximum-length titles/cwds filled with JSON-escaped characters:
3,297,323 bytes, 283 ms accept+commit, and 90 ms to activate one shell explicitly
in Home. This remains below the 4 MiB envelope bound. It proves the store and
daemon's bounded layout path, not 1,024 simultaneously running shells.
The output-only test runs a shell loop through multiple cwd-sampling cycles,
checks that terminal contents continue changing, and compares checkpoint
revision, inode, and modification time for primary and previous generations.

The standard test build also creates an uninstalled `recovery-test-daemon` from
a separate entrypoint. Four deterministic race cases pause before spawn or
before publication, then close the row or drain the service. The viewer worker
cancels in under one second while the barrier is still closed. After release,
the test waits for activation completion, verifies an already-created child
was reaped, checks the empty registry where the daemon remains running, and
restarts to verify that removed entries do not reappear. This caught and fixed
the drain holding the mutation lock throughout its grace period.

A storage regression rejects backup scrubbing after successful primary rename,
verifies unchanged in-memory intent, and checks that reconciliation restores
both generations. Failed removal/accept/dismiss now queue one debounced
reconciliation; a persistent error does not cause a retry loop.

Twenty subprocess cases now use actual SIGKILL before writing, after a partial
write, after a complete write, after file sync, and after rename, for both
primary/backup files during ordinary save and durable clear. Each verifies the
child died by signal, reopens the released writer lock, validates the complete
authoritative generation, and checks that a subsequent clear removes abandoned
temporary data. The writer uses one validated reserved temporary name rather
than accumulating random files after crashes. Separate regressions reject
symlinks and multiply linked temporary files without removing them. All hooks
exist only in the uninstalled test entrypoint; the normal daemon has no runtime
kill-point switch. This is process-crash evidence, not power-loss evidence.

## Native recovery UI

Build a separate test app so the ordinary app stays free of automation:

```sh
zig build app -Drecovery-ui-smoke=true --prefix zig-out/recovery-ui-smoke
python3 scripts/test-recovery-ui.py --app 'zig-out/recovery-ui-smoke/Boring Terminal.app/Contents/MacOS/boringterminal'
```

This uses native button actions and the AppKit event loop. It covers the offer
with a hidden sidebar, wide/narrow layouts, zoomed and unzoomed pairs, dormant
background sessions, missing-directory Retry/Home, abrupt daemon loss, explicit
reconnect, and dismissal. The driver prints its disposable HOME containing logs
and screenshots. Native view captures omit Metal terminal contents; they prove
recovery chrome layout only. They do not prove terminal rendering correctness.

Add `--capacity` to exercise native startup with 1,024 saved entries. This
passed at `/tmp/bt-gui-r93_apd8`: the fresh shell remains alive, all saved entries
restore, only the selected restored shell starts, and a degraded-saving banner
stays visible while the combined count exceeds the checkpoint bound. Closing
the extra shell resumes full checkpoints and clears the banner. The ordinary
unit/integration suite also checks that an old saved title is replaced by the
fresh shell's fallback title and that closing sessions above capacity works.
The first capacity run exposed a missing recovery-status notification; the fix
invalidates the viewer registry without scheduling another checkpoint write.

## Released daemon upgrade

Build unmodified sources from tags v0.5.0 and v0.6.0 into separate directories,
then run the following for each old app (dialects 18 and 19 respectively):

```sh
python3 scripts/test-released-daemon-ui.py --old-app '/path/to/tag/zig-out/Boring Terminal.app' --dialect 18
```

Both passed locally. The driver launches the tagged daemon and a shell under a
disposable HOME, replaces the bundle path with the current test app, and opens
the current native viewer. It verifies unchanged daemon and shell PIDs, retained
output, new input reaching the same shell, the actual update-pending menu item,
and recovery being unavailable for the old daemon. It closes the final session,
quits, and reopens; the replacement daemon must have a new PID and dialect 20,
and the pending menu item must be absent. No installed user bundle is modified.

Artifacts: `/tmp/bt-gui-skew-_4frvya1` (18) and
`/tmp/bt-gui-skew-qxlp0rq2` (19). Current viewer logs were clean. Tagged Debug
daemons emitted allocation-leak diagnostics on graceful shutdown. Because their
executable paths had been replaced, symbolized source locations may refer to
the new executable; those stacks cannot attribute a new-code regression.
This tests source-built tags, not downloaded signed release artifacts.

## Remaining evidence

The completion audit distinguishes the following evidence boundaries:

| Requirement | Evidence and verdict |
|---|---|
| Prior art and design | RFC 0025 records original source baseline, primary-source links, borrowed mechanics, alternatives, ownership, UX, protocol, and storage contracts. Delivered. |
| Native restore, lazy shells, retry/home, reconnect | Actual-button smoke tests, wide/narrow/minimum captures, daemon-loss integration. Passed locally. |
| Preserve live sessions through an app update | Both retained tagged daemons, unchanged shell/daemon PIDs and output, current viewer input, pending menu, idle replacement. Passed for source-built tags. |
| Order, pair sides, ratio, zoom, focus and detach | Integration mutates all of these, detaches, kills/restarts daemon, and compares the complete saved workspace to the new pending workspace. Passed. |
| Repeated loss and idempotency | Pure transition tests plus real daemon repeated-loss and concurrent-viewer tests. Passed. |
| Closed/dismissed entries stay removed | Durable barriers, restart checks, backup corruption, blocked-spawn close/drain races. Passed. |
| Metadata only, no command replay | Store schema has only IDs/layout/title/cwd/provenance; activation invokes the configured login shell with strict cwd. No command/PTY/screen serialization or replay path. Inspected and tested through fresh activation. |
| Capacity and write frequency | 10/100/1,024 cases, worst escaped strings, native overflow flow, primary/backup inode/mtime and revision stability under continuous output. Passed. |
| Failures between filesystem publication stages | Injected failures plus 20 real SIGKILL cases at primary/backup write/sync/rename boundaries. Complete-generation recovery, abandoned-temp reuse, and unsafe-temp rejection pass. |
| Strict cwd failures | Missing/denied POSIX cwd, failed exec, explicit retry/home, no passive retry. Passed; not a TCC test. |
| Stable signing support | Shared signer, explicit identity options, fail-closed regression, normal bundle verification, CI/release gates, full local universal DMG and mounted-payload verification. Passed locally with ad-hoc signing; certificate-backed consent remains unverified. |
| Reported permission-loop RCA and fix | RCA delivered; forced ad-hoc signing limitation corrected. Incident remains unreproduced and root cause unconfirmed. Not complete. |
| Real reboot/power loss and macOS consent | Not verified. Requires an appropriate test environment; stable-certificate comparison additionally needs signing credentials. |

Real power loss/reboot, TCC Allow/Deny and helper attribution, and consent
retention across certificate-signed builds remain unverified. SIGKILL and POSIX
permission denial are not substitutes. The user has no signing certificate.
The reported permission loop is not resolved by these recovery and compatibility
checks.

Final local gates: 322/322 tests, 606 keyboard checks, daemon import closure,
formatting/diff checks, normal app build, and local universal packaging passed.
The unpublished DMG under `zig-out/release/` retains the source's existing
v0.6.0 filename; it is a verification artifact, not a published release. Its
checksum/integrity, read-only mounted payload, strict nested signatures, and
arm64/x86_64 slices were checked; no tag, commit, upload, or publication occurred.
An Intel runtime was not used. The release packager and test apps keep test
hooks out of the installed daemon.
