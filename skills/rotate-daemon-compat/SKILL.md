---
name: rotate-daemon-compat
description: Rotate Boring Terminal's viewer-only retained daemon protocol compatibility capsules. Use when preparing a release whose attach dialect changed, replacing or deleting a legacy daemon adapter/fixture, updating the selected-dialect registration, auditing that compatibility remains removable, or verifying that boringterminald contains no legacy codec path.
---

# Rotate daemon compatibility

Keep the two previous **public** attach dialects as removable viewer-only capsules.
Do not turn development protocol numbers into a compatibility matrix.

## Read the contract

Before editing, read:

1. `AGENTS.md`
2. `docs/rfcs/0019-daemon-upgrades.md`
3. `docs/references/daemon-protocol-evolution.md`
4. `docs/rfcs/0012-daemon-attach-protocol.md`
5. `docs/references/releasing.md` when this is part of a release

Inspect the worktree before changing it. Preserve unrelated user changes and
stop if the rotation overlaps uncommitted compatibility work whose ownership is
unclear.

## Establish the rotation

Determine from source and Git history, never memory:

- the current attach dialect;
- the latest public release and its attach dialect;
- the capsules currently registered as retained dialects;
- the dialect intended for the release being prepared.

Use the previous release tag's source as the authority for its wire shape. If
the new release uses the same dialect as the previous public release, do not
rotate anything. Development-only dialects create no retention obligation.

Stop and report the mismatch instead of guessing when the public tag, retained
dialect, or intended release boundary cannot be established.

## Rotate the capsule

Follow this order:

1. Delete capsules and their embedded frozen fixtures falling outside RFC 0019's
   current-plus-two compatibility window.
2. Add or retain the capsule and fixture for the newly superseded public dialect.
   Derive exact layouts from that release's tagged source; do not reconstruct
   them from current structs.
3. Update the single selected-dialect registration.
4. Update RFC 0019's retained-dialect record, RFC 0012 when the current dialect
   changed, the owning feature RFC's downgrade behavior, and the local
   `LOOP.md` when present.
5. Run the skew gate and prove the daemon build contains no legacy codec path.

Use `apply_patch` for capsule and fixture edits. Do not delete a capsule merely
because current code no longer references its types; rotation happens only at
a public release boundary.

## Enforce the boundary

The allowed dependency direction is:

```text
viewer client -> selected dialect -> current codec OR one retained compat capsule
daemon        -> current codec only
compat capsule -> current canonical value types
```

Only the dispatch module may name current and retained dialects. Reject a
rotation that requires version branches in VT, renderer, daemon-session, or
AppKit code. Move leaked compatibility logic back into the capsule before
continuing.

Capsules are ordinary source compiled into the signed viewer. Never implement
them as plugins, downloaded code, dynamic libraries, or user configuration.

## Validate

Discover the repository's current skew-test/build targets from `build.zig` and
scripts; do not invent command names. At minimum:

1. Run `git diff --check`.
2. Run every retained-dialect skew test and its live-session preservation
   coverage.
3. Run the matching current viewer/daemon protocol tests.
4. Build both viewer and daemon.
5. Audit the daemon's import/build dependency closure for the compatibility
   module. Use the repository's binary audit when present; otherwise inspect
   surviving symbols as a secondary check and report that a deterministic
   binary gate is still missing.
6. Search outside the capsule/dispatch/tests/docs for the retired dialect name
   and version branches. Every remaining match needs a current reason.

Do not weaken a skew assertion, retain more than two previous public capsules,
or claim the daemon is clean based only on a stripped-symbol search. A missing frozen
fixture or skew gate blocks rotation.

## Hand off

Report:

- current and both retained attach dialects;
- deleted and added capsule/fixture paths;
- the single registration changed;
- skew, matching-build, and daemon-purity results;
- any intentionally unavailable feature in compatibility mode;
- whether release preparation still needs a commit, tag, push, or publication.

Do not commit, tag, push, or publish unless the user separately requested that
release action.
