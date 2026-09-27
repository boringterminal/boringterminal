# Releasing Boring Terminal

Release artifacts are universal (`arm64` + `x86_64`), ad-hoc-signed macOS 13+
applications in a compressed DMG. They are intentionally unnotarized until the
project has an Apple Developer account; see RFC 0011.

## Local package

From the repository root:

```sh
./scripts/package-macos.sh
```

Artifacts land in `zig-out/release/`:

- `Boring-Terminal-v<VERSION>-macos-universal.dmg`
- the matching `.sha256` file

The script builds both architectures with `ReleaseSafe`, merges the app and
daemon executables with `lipo`, signs the daemon, GUI, and
enclosing app in leaf-first order, verifies the signature and architecture
slices, and creates the DMG with the MIT license and an Applications shortcut.
The default remains ad-hoc. The per-architecture Zig build and final package
use the same `scripts/sign-macos.sh` signer and serial order. The script
uses a private `mktemp` staging directory and removes it on exit.

### Certificate signing and privacy identity

When a certificate and private key are available in the build keychain:

```sh
zig build app -Dcodesign-identity='Apple Development: Your Name (TEAMID)'
BORINGTERMINAL_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  ./scripts/package-macos.sh
```

Use the same signing identity across successive builds under test. These are
separate development/distribution examples, not a claim that their default
designated requirements are interchangeable. The packager signs the final
universal binaries after `lipo`; architecture staging builds can remain ad-hoc.
An empty or unusable requested identity fails instead of falling back to `-`.
This does not notarize the result or grant filesystem permissions. Do not
publish a certificate-signed artifact using the current ad-hoc release notice
without updating the workflow's signing configuration and accurate notice.

Ad-hoc builds do not supply a stable identity for macOS privacy authorization
across changed builds. Test TCC using a certificate-signed app launched from
Finder/LaunchServices in a fresh test account/VM; direct `zig build run` may
attribute access to the launching terminal. Also test after viewer exit while
the helper survives. Follow [RCA 0002](../rcas/0002-filesystem-permission-prompts.md).

## GitHub release

Before tagging, update these three semantic versions together:

- `src/version.zig`
- `build.zig.zon`
- `CFBundleShortVersionString` in `assets/Info.plist`

Increment the numeric `CFBundleVersion` for every published build. Then run:

```sh
zig build test -Dportable-system-goldens=true
/bin/bash scripts/test-macos-signing.sh
zig build esctest
git tag -a vX.Y.Z -m "Boring Terminal X.Y.Z"
git push origin vX.Y.Z
```

Hosted CI uses the portable system-golden mode because its current macOS image
does not carry the same CoreText fonts and rasterizer as the development host.
The ordinary `zig build test` command remains the stricter reference-host
suite with exact font and glyph-containing Metal hashes.

`.github/workflows/release.yml` validates the tag and versions, repeats the
tests, runs the same packager, and creates or updates the GitHub release using
the repository-scoped `GITHUB_TOKEN`. New releases prepend the Gatekeeper
notice below to their generated notes. No signing secrets are required.
When `docs/releases/<tag>.md` exists, the workflow includes those reviewed
user-facing notes after the signing notice and before generated commit notes.
Failed unit/integration steps attach a bounded diagnostic excerpt as a check
annotation. This exposes actionable test errors even when full Actions logs
require an authenticated session; successful checks keep their ordinary output.

## Gatekeeper

An ad-hoc signature detects bundle damage but does not establish an identified
Apple developer or satisfy notarization. On a downloaded release, macOS may
show an unidentified-developer warning. The supported route is to Control-click
the app in Finder, choose **Open**, and confirm once. Do not claim the release
is notarized.
