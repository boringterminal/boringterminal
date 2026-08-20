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
daemon executables with `lipo`, explicitly ad-hoc signs the daemon, GUI, and
enclosing app in leaf-first order, verifies the signature and architecture
slices, and creates the DMG with the MIT license and an Applications shortcut.
The per-architecture Zig build uses the same serial signing order. The script
uses a private `mktemp` staging directory and removes it on exit.

## GitHub release

Before tagging, update these three semantic versions together:

- `src/version.zig`
- `build.zig.zon`
- `CFBundleShortVersionString` in `assets/Info.plist`

Increment the numeric `CFBundleVersion` for every published build. Then run:

```sh
zig build test -Dportable-system-goldens=true
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
the repository-scoped `GITHUB_TOKEN`. No signing secrets are required.

## Gatekeeper

An ad-hoc signature detects bundle damage but does not establish an identified
Apple developer or satisfy notarization. On a downloaded release, macOS may
show an unidentified-developer warning. The supported route is to Control-click
the app in Finder, choose **Open**, and confirm once. Do not claim the release
is notarized.
