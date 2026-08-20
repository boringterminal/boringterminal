# RFC 0011: macOS application bundle and identity

Status: accepted

## Decision

Boring Terminal ships and runs as one ordinary macOS application bundle:
`Boring Terminal.app`. Its stable identity is:

- display/name: `Boring Terminal`
- bundle identifier: `com.boringterminal.BoringTerminal`
- executable: `boringterminal`
- package type: `APPL`

The bundle is the canonical GUI artifact produced by `zig build`. We do not
also install a loose copy of the GUI executable into `zig-out/bin`; debug tools
such as `vtdiff` remain ordinary command-line artifacts.

`zig build run` executes `Boring Terminal.app/Contents/MacOS/boringterminal`
directly after assembling the bundle. This preserves a controlling terminal
and predictable Ctrl-C behavior while allowing AppKit to discover the enclosing
bundle, plist, icon, and identifier. It must not launch through a wrapper that
can outlive or orphan the application process.

## Bundle contents

The repository owns a checked-in app-icon source set. The macOS-only build uses
`iconutil` to compile it into `Contents/Resources/AppIcon.icns`; no runtime icon
construction or alert-specific icon suppression is permitted. `Info.plist`
names that resource through `CFBundleIconFile` and declares the stable identity
above.

### Mark amendment (2026-08-20)

The icon's mark is **K**: the "Cold White" construction (chrome squircle,
machined groove, recessed scanlined CRT) with the face reduced to two
stripe-sliced dashes at optical center. The mouth is deliberately absent; the
two dashes read as closed eyes to a person and as `--`, the end-of-options
separator, to a shell. K is also the character's name. Rejected alternative:
a `$_` prompt glyph, because a small prompt on a dark squircle is visually
the stock macOS Terminal icon and is not ownable.

The complete composition occupies a centered 872 by 872 pixel safe-zone in
the 1024 pixel source canvas. The inset is part of the asset rather than a
runtime Dock adjustment, so every iconset size and the shared website mark
retain the same chrome, screen, and glyph proportions.

Development bundles are ad-hoc signed after the executable, plist, and
resources are installed. Signing is deterministic and leaf-first: the nested
daemon is signed before the GUI executable, and only then is the enclosing app
signed. Zig build steps must encode that serial dependency instead of allowing
the two executable-signing commands to race inside one bundle.

### Release distribution amendment (2026-08-17)

Until the project has an Apple Developer account, the macOS release artifact is
an **ad-hoc-signed, unnotarized universal application** containing both
`arm64` and `x86_64` slices. The release target is macOS 13.0 or newer. The app
is distributed in a compressed read-only DMG with an `/Applications` symlink
and a copy of the root MIT `LICENSE`, plus a SHA-256 checksum. This is the same
no-credentials distribution model
used by Alacritty's macOS release build: merge architecture-specific binaries
with `lipo`, ad-hoc sign the assembled bundle, then package the DMG.

Ad-hoc signing is not presented as Apple trust or notarization. Release notes
and installation documentation must say that Gatekeeper can require the user
to invoke **Open** from Finder's context menu. When Developer ID credentials
become available, CI replaces only the signing/notarization stage; the bundle,
universal-binary, and DMG layout remain unchanged.

Pushing a `v<semantic-version>` tag creates the GitHub release. The tag must
match `src/version.zig`, `build.zig.zon`, and
`CFBundleShortVersionString`; disagreement fails before packaging. CI runs the
unit/integration suite, esctest ratchet, and the same universal packager used
locally. Release builds use Zig `ReleaseSafe`: terminal input is hostile data,
so disabling runtime safety for marginal throughput is not a distribution
tradeoff we accept.

## Why now

Attention routing needs a trustworthy application identity before it can post
native notifications. The same bundle also fixes native alerts showing a
generic executable/folder identity. Building this once avoids both temporary
runtime UI hacks and a notification implementation that later has to migrate
between identities.

## Rejected alternatives

- **Keep launching the loose executable.** AppKit can draw a window, but macOS
  cannot consistently associate alerts, icons, notifications, preferences, and
  future update metadata with a real application.
- **Set alert icons at runtime.** This treats one symptom, adds dead code once
  packaging lands, and leaves every other system surface unidentified.
- **Launch via `open -W`.** The wrapper complicates Ctrl-C and process lifetime;
  direct execution from inside the bundle provides both identity and honest
  terminal ownership.
- **Generate artwork at runtime.** The application icon is product identity,
  not dynamic UI. It belongs in signed bundle resources.
