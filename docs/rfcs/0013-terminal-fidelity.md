# RFC 0013: Terminal fidelity and agent graphics

Status: draft

## Decision

Pause milestone 5's control socket and CLI while real agent workflows expose
terminal-compatibility gaps. Codex is the canonical cell/TUI fixture;
terminal-browser is the first inline-graphics fixture. Full Kitty graphics
and keyboard protocol compliance is the destination, delivered in reviewable
phases. A difference from a reference terminal is investigated from captured
bytes and capability replies, never papered over with application-specific
rendering.

This passes RFC 0000's one-line test directly: an agent session is not useful
if its controls are visually ambiguous or its output cannot be presented.

## Work streams and order

### 1. Cell and capability fidelity

Capture the exact application byte stream plus terminal replies, reduce each
failure to the smallest replayable fixture, and compare Boring Terminal with
Alacritty or Ghostty. Fix parser/grid/renderer behavior only after the layer at
fault is known.

The first fixture is Codex's composer. The observed missing panel background
may be an application theme choice rather than lost SGR cells, so OSC 10/11/12
queries are the first capability under test. RFC 0002 owns their semantics.
BCE, SGR, reverse video, synchronized output, and renderer background quads
remain independent assertions in the fixture.

Then finish the remaining TUI-facing milestone-2b surface: DECRQM, focus and
mouse reporting, XTGETTCAP, and Kitty keyboard negotiation. The escape
sequence checklist remains the implementation dashboard.

### 2. Font and Unicode fidelity

Replace the hardcoded SF Mono 13 input with the project's single config-file
font choice while preserving a deterministic default. Complete style-face
resolution, fallback baseline alignment, color emoji, grapheme/combining-mark
storage and rendering, and the pinned Unicode-width policy. Do not add
ligatures or a shaping engine.

Golden fixtures cover ASCII weight/metrics, bold/italic, box drawing, emoji,
Devanagari combining marks, CJK, selection, decorations, and mixed fallback
on Retina scale. Font differences and VT differences are reported separately.
The first box fixture is Codex's rounded panel using `─`, `│`, `╭`, `╮`, `╯`,
and `╰`; every connector must touch the corresponding cell edge without a gap
or overlap artifact. RFC 0004 owns the built-in `U+2500`–`U+259F` rendering
policy and its incremental coverage.

The adjacent Codex banner fixture begins with `✨`. Its closing `│` is a width
oracle as well as a line-rendering oracle: under the Unicode 16.0.0 policy the
sparkle occupies two cells, so every following cell and the closing rule must
remain aligned with rows that contain only ASCII. Codepoint-width lookup lands
before grapheme storage; it removes the placeholder table without claiming
VS15/VS16, ZWJ, flag-pair, or combining-cluster completion.

The one configuration file is
`~/Library/Application Support/boringterminal/config`. It is optional and is
not created merely by launching the app. The application menu's explicit
“Open Configuration” action may create a comment-only starter file, without
changing the effective defaults, before opening it through `NSWorkspace` in
the user's default `public.plain-text` application. The initial font surface
is deliberately two keys:

```text
font-family = "SF Mono"
font-size = 13
```

Blank lines and whole-line `#` comments are allowed. Values may be bare or
double-quoted; escapes and inline comments are not a second language hidden in
the parser. Unknown keys, duplicate keys, malformed lines, a non-monospace or
missing family, and sizes outside 6–72 points reject the whole candidate file.
The viewer keeps its previous effective configuration (or the system
monospaced face at 13 points during startup) and reports the error; it never
partially applies a file. A successful font change replaces the `FontSet` and
glyph atlas as one unit. Startup loading lands first; filesystem watching and
atomic hot reload remain required before this work stream is complete.

Hot reload watches both the containing `boringterminal` support directory and
the current `config` inode. The file watch catches in-place writes; directory
events catch write-to-temp + rename saves and rearm the file watch against the
replacement inode. Events are coalesced onto the AppKit main queue. Each
reload reads and parses a complete candidate, builds its replacement
`FontSet` and both glyph-atlas pages off to the side, and publishes all three
only after every step succeeds. Parse, font-discovery, monospace-validation,
and allocation failures keep the previous effective configuration and
renderer untouched. Removing the optional file is a valid reload to the
deterministic defaults; the application still never creates the file.

After a successful metric change, the viewer recomputes the grid from the
existing content size, resizes every daemon session, updates the window's
cell-derived minimum size, releases synchronized-output holds, and repaints.
Watching and candidate construction may begin away from the main thread, but
CoreText/Metal publication and all AppKit mutation occur on the main thread.

The View menu also exposes temporary text scaling with the conventional
`⌘+`, `⌘−`, and `⌘0` shortcuts. Each step changes the effective terminal font
by one point within the same 6–72 point bounds; reset returns to the configured
size. This state is viewer-local, applies only to terminal cells, and never
rewrites the configuration file or native AppKit chrome. A config reload that
changes `font-size` resets temporary scaling to the new declared value; a
family-only reload preserves the current temporary size. Font publication,
grid recomputation, and RFC 0014's coherent-geometry presentation barrier are
one transaction, so text scaling never displays a stale grid under new cell
metrics.

The `FontSet` resolves four terminal styles: regular, bold, italic, and bold
italic. The regular configured/system face is authoritative for cell width,
cell height, and baseline. CoreText may supply a styled face only when its
family, fixed-pitch property, advance, and requested symbolic traits still
match that base face; a lookalike from another family is not accepted as a
style. If a real face is unavailable, this implementation stage retains the
regular face rather than falsely labelling it styled. RFC 0004's synthetic
embolden/skew fallback remains required separately for families without real
variants.

Scalar lookup tries the requested base-family face, then the regular face,
then the regular fallback cascade. This ordering follows Ghostty's resolver
policy and avoids changing cell metrics merely to obtain a styled glyph from
another family. Cluster-local CoreText shaping starts with the same selected
style face. Scalar and cluster atlas keys include the requested style so one
style can never reuse another style's raster. Every raster reports bearings
relative to its own typographic baseline; the renderer places that bearing at
the regular face's single cell baseline. Fallback ascent/descent never alter
grid metrics or independently shift a row.

### 3. Phased, complete Kitty protocol support

RFC 0000 previously deferred all image protocols until an agent emitted
images in practice. `terminal-browser open terminal-browser.com` now provides
that concrete use case and first acceptance command. It justifies beginning
the work; it does not cap the implementation to what terminal-browser emits.

The target is the complete published Kitty graphics protocol and complete
Kitty keyboard protocol, not general behavioral parity with the Kitty terminal
application. Kitty remote control, shell integration, configuration, and UI
are unrelated surfaces. Sixel and iTerm2's image protocol remain out of scope.

Keyboard compliance is pinned first to the published specification retrieved
on 2026-08-16. Phase 1 implements negotiation plus flags 1 and 2 end-to-end;
the terminal masks and reports unsupported flags rather than pretending the
later text-bearing enhancements exist. Phase 2 adds flags 4, 8, and 16 with
native key/text correlation and expands the functional-key table. The final
matrix still requires all five flags and every applicable functional key; the
phase boundary is not a permanent compatibility exception.

#### Kitty keyboard phase 2 amendment (2026-08-19)

Phase 2 is pinned to the published Kitty keyboard protocol retrieved on
2026-08-19. All five progressive-enhancement bits are accepted and reported.
The viewer sends a bounded semantic input transaction to the daemon containing
the logical unshifted key, optional shifted and PC-101 base-layout keys, the
complete modifier state, press/repeat/release action, and any UTF-8 text
committed by AppKit for that event. It never consults a render snapshot to
choose an encoding. The daemon validates that transaction and encodes it under
the active screen's authoritative flag stack.

Bit 4 adds shifted/base-layout subfields only to events already represented as
escape sequences. The shifted alternate is present only while Shift is active;
an omitted shifted alternate with a present base-layout key retains the empty
middle subfield required by the protocol. Bit 8 reports text-producing,
recovery, and standalone modifier keys canonically, includes lock modifiers,
and implies disambiguation. Bit 16 appends committed text as Unicode scalar
values only when bit 8 is active, only for press/repeat events, and never emits
C0/C1 controls as associated text. Pure AppKit text with no recoverable key
identity uses key number zero. If AppKit commits text without a key identity
while bit 8 is active but bit 16 is not, the terminal preserves that text as
UTF-8 rather than silently losing IME, dictation, or the character palette;
this is the same user-data-preserving fallback used by Ghostty's MIT-licensed
encoder.

The semantic transaction caps committed text at 4096 UTF-8 bytes, rejects
malformed UTF-8 and non-scalar key fields, and is admitted to the PTY queue
atomically after encoding. Application key equivalents remain AppKit-owned.
Unclaimed Command-modified keys and standalone Command modifier transitions
may reach the daemon, but yield bytes only when the foreground program has
explicitly negotiated a Kitty mode that represents them.

The native functional table includes every distinct ordinary macOS key event:
F1–F20, the numeric keypad, navigation/editing/recovery keys, Caps Lock, Num
Lock/Clear, and left/right Shift, Control, Option, and Command. F21–F35,
Hyper/Meta/ISO-level shifts, and media keys have published protocol numbers but
no corresponding ordinary AppKit key event; macOS system handling is not
intercepted merely to fabricate terminal events.

#### Kitty keyboard conformance completion amendment (2026-08-19)

Keyboard phase 2 is release-complete only when the hermetic corpus exercises
the production implementation at every boundary where native input can change
meaning. The checked-in ratchet therefore includes:

- all 32 progressive-enhancement flag values through byte-split negotiation,
  query, screen isolation, bounded stack eviction, and reset;
- every `vt.keyboard.Code` reachable from an ordinary AppKit event, with exact
  press, repeat, and release bytes under the complete enhancement set, plus the
  complete six-modifier powerset and the legacy control/recovery cases;
- a pure native-normalizer seam, separated from Objective-C message delivery,
  covering every accepted macOS virtual key code, physical base-layout
  alternates, Option-composed commits, repeats, releases, and standalone sided
  modifier transitions;
- current-dialect codec round trips and malformed/boundary rejection for tags,
  actions, modifiers, scalars, UTF-8, event shape, text size, and trailing data;
  and
- deterministic raw-mode PTY fixtures proving that current, v13, and v10
  dispatch decisions produce the expected child-visible bytes.

Each inventory entry has a stable ratcheted id and a public specification or
RFC provenance anchor. Ordinary CI remains hermetic: it does not install,
download, or execute Kitty. Published protocol numbers are interoperability
data; Kitty implementation and test structure are not inputs to this suite.

Graphics lands in phases, with each phase preserving the final protocol model:

1. **Interoperability baseline:** capability query/reply, direct chunked
   transmission, the formats and placements terminal-browser uses, deletion,
   scrolling, and bounded resource ownership. This gate makes
   terminal-browser useful early.
2. **Transport and placement completion:** every transmission medium and
   format applicable on macOS, image ids/numbers, placement ids, virtual and
   Unicode-placeholder placements, offsets, scaling, z-order, cursor movement,
   and every deletion selector.
3. **Frames and animation:** frame composition, edits, animation control,
   timing semantics, and resource lifetime behavior.
4. **Compliance closeout:** exercise every action, key, response, error path,
   and chunk boundary defined by a pinned revision of the published protocol;
   document any protocol item that is genuinely inapplicable on macOS rather
   than silently omitting it.

Before phase 1 implementation, capture terminal-browser's traffic and pin the
Kitty graphics specification revision used by the tests. Later phases are
driven by the specification and protocol fixtures, not only by currently
observed applications.

#### Graphics phase 1 contract (amended 2026-08-16)

Phase 1 is pinned to the published Kitty graphics protocol retrieved on
2026-08-16 and terminal-browser v0.5.4 at commit
`8a4305695ab89ae9bdd579062610f9c064ab4303`. The client first queries direct
24-bit RGB support with
`APC Gi=4207,a=q,t=d,f=24,s=1,v=1;AAAA ST`. Its renderer probes file and POSIX
shared-memory media, then deliberately falls back when those probes fail to
direct, zlib-compressed, base64-chunked 32-bit RGBA frames. A frame uses
`a=T,f=32,o=z,t=d,i=<id>,p=1,C=1,q=2,m=<more>` on its first chunk, `m=<more>`
on continuation chunks, and `a=d,d=A,q=2` on teardown. This captured stream is
the phase-1 interoperability corpus.

The baseline therefore implements:

- APC `G` parsing with an 8 KiB per-command bound and a 32 MiB encoded-upload
  bound; overflow or malformed chunks abort the in-flight upload without
  printing payload bytes;
- direct (`t=d`) RGB (`f=24`) and RGBA (`f=32`) data, optional zlib (`o=z`),
  query (`a=q`), transmit-and-place (`a=T`), continuation (`m=1/0`), image and
  placement ids, the no-cursor-movement policy (`C=1`), and delete-all/delete-
  by-id (`d=A/I`);
- exact Kitty acknowledgements (`q=1` reports errors only; `q=2` never
  replies). File, temporary-file,
  and shared-memory probes receive a printable `ENOTSUP` response in phase 1;
  no child-provided path is opened;
- cursor-anchored, native-pixel-size placement at z-index zero. The placement
  is committed only after base64, zlib, dimensions, and byte count validate.
  Retransmitting an id replaces its resource and placements atomically;
- host-supplied backing-pixel cell geometry for PTY `winsize` and XTWINOPS
  14/16. Native image pixels convert to renderer points exactly once; this
  keeps a Retina frame and cell-based pointer coordinates in the same space;
- placement removal on ED 2, RIS, and alternate-screen clearing, plus
  cell-anchored movement/clipping with terminal scrolling. Other erase
  operations do not remove graphics, matching the published interaction
  rules;
- a Metal texture pass for RGBA resources, with protocol pixels kept outside
  the glyph atlas. Phase-1 z-index zero draws above cell content; later phases
  add the complete negative/positive ordering model.

Decoded resources are daemon-host-owned. The pure VT owns only bounded encoded
transfer state and deterministic placement metadata; a graphics action asks
the host to decode/store a resource, and an explicit success callback commits
the placement. The daemon store is capped at 64 images, 64 MiB per decoded
image, 16,384 pixels per dimension, and 128 MiB total, evicting the oldest unreferenced resource before
returning `ENOSPC`. The versioned viewer snapshot carries only visible,
bounded resources and placements in phase 1; a later resource-cache protocol
may remove repeated copies without changing VT semantics.

Decoded image resources are host/renderer-owned and bounded by explicit byte,
dimension, and count limits. The pure VT state owns deterministic placement
metadata and emits effects for resource operations; it performs no file I/O,
image decoding, clock access, or GPU work. Direct paths supplied by a child
must not become arbitrary file-read capability.

#### Graphics phase 2a shared-memory amendment (2026-08-17)

The first live-video profile of terminal-browser v0.5.4 found the daemon
saturating one CPU core in direct-frame base64 and Zig zlib decoding, while
the viewer repeatedly copied the decoded frame through the attach snapshot.
Video below 20 fps and perceptible input latency are not acceptable forms of
the phase-1 interoperability baseline. POSIX shared memory is therefore the
first transport-completion slice rather than a later cosmetic optimization.

Phase 2a accepts `t=s` for raw RGB/RGBA and zlib-compressed RGB/RGBA queries
and transmit-and-place commands. The APC payload is still base64, but decodes
only to the POSIX shared-memory object name; image bytes never travel through
the PTY. `S` and `O` select a bounded byte range. With `S=0`, uncompressed
RGB/RGBA derives its exact byte count from `width * height * channels`; other
formats read from `O` through the current object size. Darwin can report a
shared-memory backing size rounded up to its VM page, so treating `fstat` size
as raw pixel length rejects conforming clients. This follows the protocol's
raw-pixel-size rule and Ghostty's independently implemented range behavior.
The selected transport bytes remain subject to the existing decoded-image,
dimension, resource-count, and total quota limits.

The pure VT parses and bounds the medium, range, and encoded name, then emits
one graphics action. Only the daemon host may call `shm_open`, `fstat`,
`mmap`, `munmap`, `close`, or `shm_unlink`. It opens the name read-only, maps
only the page-aligned span containing the selected range, rejects an invalid
name, range, or object size, closes every opened descriptor, and attempts to
unlink the object after reading it, including for query actions, as required
by the published protocol. A failure before a successful open cannot unlink
an object it did not acquire. Shared-memory
names confer no filesystem-path capability; `t=f` and `t=t` remain rejected
until their regular-file and safe-temporary-file policy lands.

The `shm_open` call passes only flags defined for that API. In particular it
does not pass `O_CLOEXEC`: Darwin documents that every descriptor returned by
`shm_open` already has `FD_CLOEXEC`, and newer macOS releases reject the
otherwise redundant flag. Ghostty's independently implemented Kitty transport
uses the same read-only flag set. Producer-side fixtures follow the same rule.

The first acceptance fixture is terminal-browser's `i=299,a=q,t=s` probe,
followed by its uncompressed `a=T,t=s,f=32` rotating-slot frames. A successful
probe must make terminal-browser choose shared memory without an environment
override. Direct transport remains supported for remote clients. This slice
does not yet remove the daemon-to-viewer frame copy; that boundary is measured
again after the transport change before designing a resource/damage protocol.

#### Graphics phase 2b viewer-resource amendment (2026-08-17)

The post-shared-memory profile still showed decoded RGBA allocated, copied,
serialized, decoded, and reconsidered for Metal upload on every attach
snapshot, even when the resource generation had not changed. Protocol v6
separates immutable resources from mutable render state: snapshots carry only
visible descriptors and placements, while a bounded fetch command publishes a
missing generation once to the viewer. Later snapshots of the same generation
carry no pixel bytes and reuse the existing Metal texture.

Resource identity includes session id, image id, and daemon-assigned
generation. The daemon remains authoritative and may reject a stale fetch after
replacement; the viewer retains its previous coherent frame and retries a new
snapshot instead of fabricating pixels or treating the race as disconnect.
Viewer CPU caching is bounded to resources referenced by each session's latest
snapshot. GPU retention is bounded to the active snapshot, avoiding background
VRAM growth while still eliminating repeated upload during normal playback.

The sustained-video follow-up prepares a newly fetched immutable generation's
Metal texture on the viewer refresh worker before atomic publication. This
does not change the protocol resource identity or daemon authority: it moves
the already-required CPU-to-Metal copy away from AppKit presentation. Viewer,
renderer-cache, and in-flight-frame retains form the complete texture lifetime.
Inactive byte-fallback resources may keep only the bounded adopted socket
backing from the latest per-session snapshot and release their prepared-texture
retain. RFC 0015 staged resources have no viewer CPU copy; hiding removes their
local cache entry and reactivation stages the still-authoritative generation
again.

This amendment optimizes the private daemon/viewer boundary only. It changes no
Kitty escape semantics, resource lifetime, placement, or deletion behavior and
does not claim zero-copy delivery of a genuinely new video frame. Acceptance
requires a real-daemon test proving that an unchanged generation is fetched
once across repeated snapshots, replacement requires exactly one new fetch,
and stale identities fail without corrupting the command connection.

#### Graphics phase 2c file-transport amendment (2026-08-17)

Phase 2c accepts the published regular-file (`t=f`) and temporary-file (`t=t`)
media for raw RGB/RGBA data, with the same optional zlib compression and
bounded `S`/`O` byte ranges as shared memory. The APC payload decodes to a
filesystem path, not pixel bytes. Local media are single-command references;
`m` is ignored for `t=f`, `t=t`, and `t=s` rather than starting a direct-data
chunk transfer.

Only the daemon host opens a child-provided path. It opens read-only while
following symlinks as the protocol requires, derives the canonical path from
the opened descriptor, and accepts only a regular file. Device and other
special files are rejected, as are canonical paths under `/dev`. Reads are
capped by the existing 64 MiB per-image limit. With `S=0`, data is read from
`O` through end-of-file; raw decoding then enforces the dimensions' exact byte
count. An explicit range must fit entirely in the opened file.

Temporary-file cleanup is narrower than regular-file access. The canonical
opened file must contain `tty-graphics-protocol` in its full path and reside
under a canonical known temporary root: `/tmp`, `/var/tmp`, or the daemon's
`TMPDIR` when present. Prefix matching requires a path-component boundary.
Only after those checks does cleanup become armed; the canonical path is then
unlinked on every later success or failure. A rejected path is never deleted.
This follows the published security contract and Ghostty's independently
implemented open-then-validate policy while keeping all filesystem effects out
of the pure VT.

#### Graphics phase 2d PNG amendment (2026-08-17)

Phase 2d accepts the required Kitty `f=100` PNG format over direct,
regular-file, temporary-file, and POSIX shared-memory media. Unlike raw
RGB/RGBA, PNG dimensions come from the datastream; supplied `s` and `v` values
do not override them. Direct PNG remains chunkable. The optional `o=z` wrapper
is removed before PNG decoding and requires a nonzero `S` containing the
uncompressed PNG datastream size, matching the published protocol. This is the
one case where `S` is not a local-medium input-range length: file and shared-
memory transports read from `O` through their bounded end and the zlib stream
defines its compressed extent. Outer decompression must produce exactly `S`
bytes; both the PNG datastream and decoded RGBA resource are bounded to 64 MiB.

PNG decoding is a daemon-host effect. Before invoking ImageIO, the host checks
the PNG signature and IHDR, rejects zero or over-limit dimensions, and proves
that `width * height * 4` fits the existing 64 MiB decoded-resource bound.
ImageIO must report the same dimensions. It renders every valid PNG color
type, bit depth, palette, transparency, and interlace form into an sRGB
premultiplied RGBA8 bitmap. The host then converts that bitmap to the
renderer/store's existing straight-alpha RGBA8 contract, using top-to-bottom
row order. Invalid, truncated, or oversized data fails without replacing an
existing resource or committing a placement.

This native decoder is intentional: Boring Terminal is macOS-only, ImageIO is
already the platform's maintained PNG implementation, and keeping it behind
the host boundary preserves `src/vt/` purity. Tests cover a multi-row PNG with
transparency, PNG dimensions overriding control values, direct chunking,
outer zlib, file transport, malformed data, and oversized IHDR rejection.

#### Graphics phase 2e placement amendment (2026-08-17)

Phase 2e completes direct cursor-anchored image placement against the published
Kitty graphics protocol retrieved 2026-08-17. Transmission (`a=t`), transmission
and placement (`a=T`), and placement of a retained resource (`a=p`) are
distinct operations. An explicit image id (`i`) replaces that resource and
removes all of its old placements before an optional new placement is
committed. An image number (`I`) is mutually exclusive with `i`; transmission
allocates a fresh nonzero id even when the number already exists, while later
put and delete commands using that number resolve only its newest retained
resource. A transmission with neither creates an internal id and emits no
acknowledgement. Put requires an id or number. A nonzero placement id names the
pair `(image id, placement id)` and atomically replaces that placement;
placement id zero remains anonymous and may occur more than once.

Physical placement metadata retains source `x,y,w,h`, within-cell pixel
offsets `X,Y`, requested cell rectangle `c,r`, signed `z`, and the cursor
policy `C`. The source is intersected with the decoded image. With neither
`c` nor `r`, it retains native source pixels; with both, it fills exactly that
cell rectangle; with one, the other pixel dimension is derived from the
clipped source aspect ratio. Pixel offsets must be smaller than the current
backing-pixel cell. Effective grid dimensions use ceiling division and
bounded saturating arithmetic. Placements retain the phase-1 terminal-row
anchoring and viewport clipping behavior and are bounded to 256 retained
records per session. Exact clipping at partial scroll margins is not expanded
by this phase.

Successful placement moves the cursor down by the effective row count using
normal index/scroll semantics and right from the original anchor by the
effective column count. `C=1` suppresses both movements. Since decoded PNG
dimensions and retained-resource lookup are host-owned, a graphics action is
a synchronous parsing barrier: the daemon completes it and commits any cursor
movement before feeding later PTY bytes from the same kernel read. This keeps
the pure VT replayable without allowing delayed host work to reorder terminal
semantics.

Every published delete selector is parsed: visible physical placements,
image id with optional placement id, newest image number with optional
placement id, cursor/cell/cell-plus-z intersection, id range, column, row,
z-index, and animation frames. Lowercase removes matching placements while
retaining decoded data; uppercase additionally frees every newly unreferenced
matching resource. `f/F` is a successful no-op until animation resources
exist. A delete aborts an unfinished direct upload. Virtual placements are
deliberately deferred to phase 2f and therefore excluded from the physical
location selectors; relative placements and animation remain later protocol
slices.

Rendering follows the protocol's three strata. Placements below
`INT32_MIN / 2` draw before non-default cell backgrounds, other negative
z-indices draw after backgrounds but before text/decorations, and nonnegative
placements draw above cells. Within a stratum, ascending z then image id draws
lower first. Source UVs and destination pixel sizes travel through the private
snapshot; Metal performs scaling and viewport clipping in one textured quad.
These rules follow the published specification and are cross-checked against
Ghostty's independent MIT implementation; no Kitty source is ported.

#### Graphics phase 2f Unicode-placeholder amendment (2026-08-17)

Phase 2f implements the published Unicode-placeholder protocol retrieved
2026-08-17. `U=1` on `a=p` or `a=T` creates an invisible virtual placement
prototype rather than a cursor-anchored placement. A prototype retains its
image id/number resolution, optional placement id, requested `c,r` grid, and
resource generation, never moves the cursor, and counts toward the existing
256-placement quota. `U=0` retains physical behavior. Retransmission and
named-placement replacement remain atomic across both placement kinds.

U+10EEEE is stored as ordinary one-cell text. Its foreground color supplies
the low image-id bits (8 for indexed color, 24 for RGB); SGR 58 underline
color supplies an optional placement id; its first three suffix codepoints are
decoded against the protocol's pinned 297-entry row/column diacritic table as
row, column, and the high image-id byte. Invalid or out-of-range values are
treated as absent. Missing fields inherit only through the specification's
left-to-right, same-color adjacency rules. Placeholder cells are never sent
to font fallback or the glyph atlas, but their real background and every other
text operation remain unchanged.

At snapshot capture the daemon coalesces compatible adjacent placeholder
cells into one-row runs. An explicit nonzero placement id resolves the exact
virtual prototype; zero chooses the oldest matching virtual prototype for the
image. The complete image is aspect-fit and centered inside the prototype's
`c,r` grid; an omitted dimension derives the minimum native-pixel cell span.
Each run becomes a clipped source/destination quad using integer backing-pixel
geometry, following Ghostty's independent MIT implementation. Destination
edges use nearest-integer rounding. Source intervals conservatively round
outward (floor the start and ceil the end), so every non-empty placeholder
fragment samples at least one source pixel; this is required when a one-pixel
image spans multiple placeholder rows or columns.
The quad uses z=-1, above cell backgrounds and below text/decorations, so
transparent pixels reveal the placeholder cell's actual background. Grid
edits, scrollback, reflow, and erasure relocate or remove the display solely
by relocating or removing its placeholder text.

Only deletion by image id, newest image number, or inclusive image-id range
(`i/I`, `n/N`, `r/R`) may remove virtual prototypes. Physical-location,
visible-all, and z selectors ignore them. Uppercase deletion frees the image
only when no physical or virtual prototype still references it. The real
images derived from placeholder cells are not protocol placements and cannot
be targeted by graphics deletion commands. Relative placements, usage hints,
and animation remain later phases.

#### Graphics phase 2g relative-placement and usage-hint amendment (2026-08-19)

Phase 2g completes the remaining placement controls from the published Kitty
graphics protocol retrieved 2026-08-19. A nonzero parent image id `P` makes a
new or replacement placement relative. `Q` selects that image's nonzero client
placement id; zero selects its oldest retained placement, including an
anonymous placement. The pure VT assigns every placement a separate monotonic
internal identity so a zero-`Q` edge remains attached to the placement it
originally resolved rather than changing when another anonymous placement is
added. `H` and `V` are signed cell offsets from the parent's top-left origin.
A relative placement never moves the cursor, regardless of `C`.

Relative edges form an acyclic placement graph with at most eight parent
edges, matching the protocol's required minimum and the pinned reference
behavior. Missing parents fail with `ENOPARENT`, a cycle with `ECYCLE`, and a
longer chain with `ETOODEEP`. A virtual placement cannot itself be relative
(`EINVAL`), but it may be a parent. Replacing a named parent placement updates
that node in place, preserving its internal identity and descendants. Deleting
a parent, clearing its screen-owned physical placement, retransmitting its
image, or pruning it from retained history recursively deletes every relative
descendant. A descendant image that loses its final placement through this
cascade is freed even for a soft deletion, as required by the protocol.

Snapshot capture resolves a physical parent from its retained row/column. A
virtual parent uses the minimum row and column of all currently visible
Unicode-placeholder runs derived from that exact prototype. Descendant offsets
accumulate through the graph with checked signed arithmetic; a virtual parent
with no current placeholder run makes its descendants invisible without
deleting them. Ordinary viewport/scissor clipping remains the final visibility
boundary. Parent graph state stays daemon-owned and never crosses into the
renderer as a second placement model.

`N` is accepted only while transmitting an image or animation frame. Bit zero
is the published transient hint; unknown bits are consumed and ignored. It does
not change placement semantics. Under storage pressure an unplaced transient
resource is evicted before an otherwise equivalent ordinary resource, while
age remains the tie-breaker. A composed animation frame is transient when any
source, destination, or transmitted delta involved in its pixels is transient.

#### Graphics phase 3 frame and animation amendment (2026-08-19)

Phase 3 implements frame loading (`a=f`), animation control (`a=a`), frame
composition (`a=c`), and `d=f/F` against the published protocol retrieved
2026-08-19. The pure VT only parses bounded commands and emits typed actions.
Decoded pixels, the frame store, monotonic time, and scheduling remain in the
daemon host layer, preserving `src/vt/` purity and viewer-independent session
lifetime.

Each retained image has one-based frames: frame 1 is the transmitted root and
later frames append in arrival order. Frame data uses every already-supported
format, compression, and transmission medium. Direct continuations repeat
`a=f` and `m`, with optional `q`; no partial frame becomes visible. For a new
frame, `x,y,s,v` locate and size the transmitted delta, `c` selects an existing
background frame, and absent `c` starts from the `Y` RGBA background (default
transparent black). `X=0` performs straight-alpha source-over composition and
`X=1` overwrites. Nonzero `r` edits that existing frame in place instead of
appending. Every committed frame is stored as a complete top-down straight-
alpha RGBA8 canvas, deliberately trading delta-storage complexity for bounded,
deterministic reads; frames share the existing 128 MiB per-session decoded
graphics budget and fail atomically with `ENOSPC`.

New non-root frames default to a 40 ms gap. Positive `z` replaces that gap,
zero leaves the applicable default or existing value unchanged, and negative
`z` creates a gapless frame. The root starts gapless and can be assigned a gap
through animation control. `c` in `a=a` selects the current one-based frame
immediately. `r,z` changes one frame's gap. `s=1` stops and resets the loop
counter; `s=2` runs until the end and waits for newly appended frames; `s=3`
runs and wraps. `v=1` loops indefinitely and larger values permit `v-1`
wraps, matching the reference behavior. A daemon-owned one-shot kqueue timer
uses the awake monotonic clock, advances every due animation in a session,
skips gapless frames, coalesces missed deadlines without replaying stale
frames, and emits the ordinary grid invalidation used by viewer refresh. No
AppKit timer owns protocol state, and an absent or background viewer cannot
pause an animation.

For `a=c`, `r` is the source frame and `c` the destination. The published
worked example and reference behavior make `X,Y` the source origin and `x,y`
the destination origin; one adjacent prose sentence describes those origins
in reverse. Omitted `w,h` mean the full canvas. `C=0` blends and `C=1`
overwrites. Missing frames return `ENOENT`; out-of-bounds rectangles and
overlapping source/destination rectangles within the same frame return
`EINVAL`. Editing or composing the current frame publishes a fresh render
generation immediately. Frame render generations travel through the existing
descriptor-only snapshot and `SCM_RIGHTS` staging path, while placements retain
the root generation as their resource identity.

`d=f/F` targets the image by id or newest image number and frame by `r`, with
frame 1 as the default and out-of-range values clamped to the final frame.
Deleting the root promotes the first extra frame; deleting the current frame
selects the nearest surviving frame and publishes it. With no extra frame,
lowercase `f` is a no-op and uppercase `F` frees the image. All frame mutations
recompute scheduling and decoded-byte accounting before they acknowledge
success.

## Acceptance gates

- A recorded Codex startup/composer fixture produces the same cell attributes,
  cursor state, and capability exchange as the selected reference terminal.
- OSC color query tests cover BEL and ST termination, chunk-split input, exact
  reply bytes, and agreement with the renderer's effective theme.
- Renderer goldens cover backgrounds independently of glyph rasterization and
  cover the font/fallback matrix above.
- `terminal-browser open terminal-browser.com` passes its terminal capability
  check and displays its first page image in Boring Terminal (phase 1).
- The final Kitty compliance matrix has a fixture and an explicit pass status
  for every graphics action/control key and every keyboard protocol flag in the
  pinned specifications; unsupported applicable entries are release blockers.
- Every fixed byte stream lands in `tests/corpus/`; the esctest ratchet never
  shrinks and `docs/references/escape-sequences.md` stays current.

## Non-goals

- Application-specific Codex or terminal-browser integrations.
- Claiming visual pixel identity across different configured fonts.
- Ligatures, arbitrary text shaping, video outside Kitty graphics, sixel, or
  iTerm2 images.
- Expanding the control socket or deciding the future plugin mechanism.

## Prior art and licensing

Sequence behavior follows the lookup order in
`docs/references/prior-art.md`. Xterm ctlseqs is the OSC dynamic-color oracle;
Ghostty and Alacritty are behavioral and implementation references. Kitty's
published graphics protocol is a specification and may be implemented, but
Kitty source is GPLv3 and must never be ported.
