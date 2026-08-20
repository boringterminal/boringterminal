---
name: release-boring-terminal
description: Prepare, publish, resume, or audit Boring Terminal macOS releases. Use when asked to bump the product version, prepare a release commit, cut or push a release tag, trigger or monitor the GitHub Actions release workflow, verify its universal DMG and checksum, or diagnose a failed Boring Terminal release.
---

# Release Boring Terminal

Use the repository's existing version checks, tests, packager, and tag-triggered
GitHub Actions workflow. Do not recreate release logic in the skill.

## Establish the requested boundary

- **Prepare**: update versions, validate, and commit. Do not push or tag.
- **Publish / cut / create a release**: prepare if needed, push `main`, create and
  push the annotated version tag, monitor Actions, and verify the release.
- **Audit / resume**: inspect the existing tag, workflow run, and release before
  changing anything. Never create a duplicate tag or release.

Treat pushing the tag as an external publishing action. Do it only when the user
explicitly asks to publish, cut, create, or push the release. There is no
separate workflow dispatch: pushing `v<semantic-version>` is the canonical
trigger defined by `.github/workflows/release.yml`.

## Read the release contract

Before editing, read:

1. `AGENTS.md`
2. `docs/references/releasing.md`
3. `docs/rfcs/0011-macos-app-bundle.md`
4. `.github/workflows/release.yml`
5. `scripts/package-macos.sh`

Confirm the checkout is the Boring Terminal repository and inspect the remote,
worktree, current source version, latest version tag, and commits since it.
Fetch the remote before deciding whether the branch can be pushed safely.

If the attach dialect changed since the previous public release, also use
`skills/rotate-daemon-compat/SKILL.md` before preparing the release commit. A
release with a new dialect is not ready until its previous-release capsule,
frozen fixture, skew test, and daemon-purity audit pass.

## Choose and apply the version

Use a user-specified version when provided. Otherwise infer SemVer from the
release contents: patch for fixes only, minor for backward-compatible features,
and major only for an intentionally breaking stable release. State the inferred
version before editing; ask only when the release scope makes the bump genuinely
ambiguous.

Keep these authoritative values equal:

- `src/version.zig`
- `build.zig.zon`
- `CFBundleShortVersionString` in `assets/Info.plist`

Increment numeric `CFBundleVersion` for every published build. Search for the
old semantic version with `rg` and update current protocol identity tests and
current documentation. Preserve text that intentionally records a historical
release artifact. If a local `LOOP.md` exists, update it so the handoff reflects
the release state; it remains ignored and must not be committed.

## Validate before publishing

Run the same gates as hosted release CI:

```sh
git diff --check
./scripts/package-macos.sh --check vX.Y.Z
zig build test -Dportable-system-goldens=true
zig build esctest
```

Stop on any failure. Review and commit only the intended release changes with a
message such as `chore: prepare vX.Y.Z release`. Do not tag a dirty worktree.

## Publish through GitHub Actions

1. Fetch again and verify `origin/main` has not diverged.
2. Push the release commit to `origin main`.
3. Create an annotated tag on that exact commit:

   ```sh
   git tag -a vX.Y.Z -m "Boring Terminal X.Y.Z"
   git push origin vX.Y.Z
   ```

4. Monitor the `Release` run to completion. Prefer `gh run watch --exit-status`
   when GitHub CLI is available. For a private repository without `gh`, use the
   authenticated GitHub API via the existing Git credential helper; keep the
   credential in command substitution and never print or persist it.
5. Verify the published release is non-draft and contains both:
   `Boring-Terminal-vX.Y.Z-macos-universal.dmg` and its `.sha256` file.
6. Report the release and workflow links, tag commit, test result, and the
   ad-hoc-signing/Gatekeeper caveat from RFC 0011.

The workflow generates release notes and builds the universal artifact. Do not
also create a manual GitHub release unless the workflow contract changes.

## Handle failures safely

- For a transient Actions failure, rerun the same workflow against the existing
  tag after identifying the cause.
- For a source or packaging bug, do not force-move or delete a published tag.
  Fix forward and cut the next patch version.
- Never claim notarization or identified-developer trust; releases remain
  ad-hoc signed until Apple Developer credentials exist.
