# RFC 0004: Metal renderer

Status: draft

## Components

The renderer is organized around these macOS-specific components:

- `metal.zig` — device/queue/pipeline setup, quad + text + image pipelines
- `coretext.zig`, `font.zig` — CoreText rasterization, font services
- `atlas.zig` — glyph atlas
- `shape_cache.zig`, `measure_cache.zig` — shaping/measure caches
- `objc.zig` — hand-written objc bindings
- `app.zig` — headless host owning device + font services + caches

The code has no external runtime dependency and is specialized for the
terminal's monospace cell fast path.

## What changes

- **Delete cross-cell shaping.** No ligatures → no HarfBuzz and no shaping
  across terminal cells. A single-codepoint cell keeps the direct
  `CTFontGetGlyphsForCharacters` fast path. A multi-codepoint grapheme is the
  necessary narrow exception: CoreText shapes exactly that one cluster into
  one atlas entry so combining placement and ZWJ/variation sequences are not
  decomposed into overlapping guesses. The shaped run is constrained to its
  one- or two-cell box and can never consume neighboring cells. CoreText font
  fallback remains per codepoint/cluster.
- **Atlas keying** becomes either (font id, glyph id, style variant) for the
  scalar fast path or (cluster content, style variant) for cluster-local
  shaped runs. Bold/italic
  prefer real faces; synthesize (embolden/skew) only when the family lacks
  them. Add atlas eviction: a terminal is long-lived, so use LRU pages or
  generation clearing on pressure/font change.
- **Presentation:** CAMetalLayer on our NSView; drawable size in pixels
  (backing scale);
  `presentsWithTransaction = true` during live resize so grid and window
  never tear apart, normal presentation otherwise.

## Font and theme fidelity (amended 2026-08-16)

The renderer and the VT's capability replies consume one effective theme.
OSC 10/11/12 must never report colors that differ from the colors used for
default cells and the cursor. Font configuration likewise feeds one
`FontSet`: family, size, and style-face resolution are inputs, while CoreText
fallback remains per codepoint/cluster.

The no-ligature decision remains. Fidelity here means stable cell metrics,
real bold/italic faces where available, correct fallback baseline alignment,
color emoji, combining/grapheme rendering, and widths matching the policy in
`docs/references/unicode-width.md`; it does not mean general text shaping.

Style completion is per requested axis. An exact real face wins. When a
bold-italic face is absent, a real bold or italic face is retained as the base
and only its missing axis is synthesized; otherwise the regular face supplies
both. Synthetic italic is a 15-degree CoreText affine skew. Synthetic bold
draws mask glyph outlines with fill-and-stroke using a line width of
`max(font_size / 14, 1)` points, and expands scalar raster bounds by half that
width on every edge so the stroke is not clipped. The regular face remains the
sole authority for cell advance, height, and baseline. These constants and the
partial-real-face preference follow Ghostty's MIT-licensed CoreText style
completion. Embedded color glyph artwork and renderer-owned box/block glyphs
are never skewed or emboldened.

Color glyphs use a second atlas and draw path. Ordinary text and built-in cell
rasters remain one-byte R8 coverage masks tinted by the cell foreground in the
glyph shader. A CoreText run backed by a color-glyph face instead rasterizes
through CoreGraphics into an RGBA8, premultiplied-alpha bitmap, uploads to a
dedicated RGBA atlas, and is composited by a premultiplied-alpha pipeline
without applying the cell foreground. Dim opacity applies to all four sampled
channels so the premultiplication invariant is retained. Scalar and
cluster-shaped glyphs share this routing; the latter is classified from its
actual CoreText runs rather than guessed from Unicode codepoints. Atlas growth,
UV rescaling, and cap clearing are independent per texture, while cache keys
remain content/font based. Color glyphs are still terminal glyphs: they occupy
their VT-declared one- or two-cell box and are unrelated to Kitty graphics.
Before atlas upload, the non-transparent bounds of every scalar or clustered
color glyph are uniformly scaled to cover as much of that box as possible
without crossing it, centered on both axes, and given 2.5% inset on each
horizontal edge. This follows Ghostty's MIT-licensed emoji constraint policy:
preserve aspect ratio, do not trust Apple Color Emoji's raw bitmap bounds as
terminal geometry, and never stretch or crop artwork at a cell edge.

Box-drawing and block-element codepoints (`U+2500`–`U+259F`) are renderer-owned
built-in glyphs rather than trusted to the configured font. Their raster canvas
is the exact terminal cell, so strokes reach cell edges and remain contiguous
across adjacent cells regardless of font bearings or advance rounding. The VT
continues to store and copy the original Unicode codepoint; this is a rendering
choice, not character substitution. Coverage may land in fixture-driven
increments, falling back to the configured font for codepoints the built-in
rasterizer does not yet implement. Alacritty's built-in box font is the
behavioral precedent; Boring Terminal's rasterizer remains an independent
implementation.

Complete coverage preserves the distinctions encoded by Unicode: light and
heavy strokes use one- and two-unit weights; double strokes use separated
parallel rules; dashed variants preserve their two-, three-, or four-segment
rhythm; arcs and diagonals are antialiased; fractional blocks are rounded to
pixel boundaries while always keeping a non-zero fraction visible; shades use
25%, 50%, and 75% coverage; and quadrant elements fill exact cell quadrants.
Every connector, including each rule of a double line, reaches its cell edge.
The built-in range is exhaustive once landed: `supports()` must accept every
codepoint from `U+2500` through `U+259F` and reject adjacent codepoints.

## Frame pipeline

Frame = pure function of (grid snapshot, cursor, selection, viewport). Two
instanced draws over cell quads:

1. **Background pass** — cell bg colors (most cells: default bg → skip via
   clear color), selection tint, cursor block.
2. **Glyph pass** — instanced textured quads sampling the atlas; fg color per
   instance. Underline/strikethrough/undercurl as primitives in this pass
   (undercurl in the shader, not the atlas). Bar/underline cursors here too.

Kitty graphics adds a separately testable image-placement pass after cell
backgrounds and before/after glyphs according to placement z-order. Physical
placements do not turn cells into image fragments. Unicode placeholders are
the specified exception: the daemon scans the authoritative visible grid and
derives renderer-ready image quads from contiguous U+10EEEE runs, while the
placeholder itself is suppressed from the glyph atlas. The image pixels still
remain in the dedicated image pass and never enter either glyph atlas. The
phased transport, placement, deletion, animation, scrolling, and resource
work is specified by RFC 0013. Captured terminal-browser traffic defines the
first interoperability gate, not the final supported surface.

The phase-1 image pass uploads validated host-owned straight-alpha RGBA8 data
to dedicated Metal textures. Default z-index placements render after cell
content, as required for terminal-browser's full-surface frame; they are not
batched into the glyph instance buffer or cached in either glyph atlas.
Protocol pixel dimensions are backing pixels and are converted to point-space
quad dimensions using the renderer's current backing scale.

Attach protocol v6 makes each decoded image generation an immutable viewer
resource. A render snapshot carries only its session-scoped identity,
dimensions, and placements. The viewer fetches RGBA bytes only when that exact
`(session id, image id, generation)` is absent from its bounded CPU cache; the
renderer uploads it only when the matching Metal texture is absent. Repainting
an unchanged generation performs neither operation. The renderer's texture key
must include the session id because daemon sessions allocate generations
independently. CPU resources remain cached per session while referenced by its
latest snapshot; GPU textures not referenced by the active snapshot may be
released, so ten background sessions cannot multiply unbounded VRAM.

A full 80×220-ish 5K grid is ~O(20k) instances — trivial for any Metal GPU;
per-cell damage tracking is an *optimization for power*, not for speed:

- **Redraw policy:** dirty flag per row (vt sets it on mutation). No dirty
  rows → no frame encoded → idle sessions cost ~0 GPU/CPU. This is the
  mechanism behind "ten idle agents are free".
- **Scheduling:** PTY reads mark damage and request a frame; frames are
  drawn on the display link (CVDisplayLink), coalescing arbitrarily many
  reads per vsync. Never render more than once per vsync; never let
  rendering backpressure the PTY reader (RFC 0001 threading).

## Sustained graphics pipeline amendment (2026-08-18)

A sustained 720p Kitty-graphics workload exposed three implementation debts
that violate the scheduling contract above: the AppKit callback performs
synchronous daemon snapshot/image requests, dirty events dispatch rendering
directly rather than through a display link, and the live Metal path waits for
every command buffer because all frames share one mutable instance buffer.
These are pipeline defects, not Kitty protocol semantics.

Before changing the pipeline, a temporary diagnostics build recorded generic
graphics boundaries: daemon graphics commits, viewer snapshot/image fetches
and bytes, refresh duration, image upload bytes and duration, display-link
ticks, submitted/presented/coalesced frames, unavailable frame slots, and GPU
completion latency. The Debug-only, explicit-opt-in instrumentation contained
no terminal-browser or application-specific branch and was removed after the
sustained benchmark identified and verified the bottlenecks; it never became
a product telemetry surface.

Viewer refresh is single-flight per session and runs away from the AppKit
event thread. A worker fetches one complete daemon snapshot and every missing
immutable image generation, validates the set, and publishes it atomically
under the existing session lock. The main/display-link path consumes only the
last coherent published snapshot and never waits for daemon I/O. Dirty state
arriving during a refresh remains set and schedules a subsequent refresh; it
cannot be erased by completion of the older request. Failed or stale fetches
preserve the last coherent frame.
If the initial attach races an image generation replacement before any frame
has been published, the window stays on its empty background and retries on
the refresh worker; a recoverable stale resource never terminates the viewer.

Bulk snapshot/image requests use a dedicated request/response connection.
They never hold the interactive command connection's mutex, so a multi-megabyte
immutable image fetch cannot queue a key, mouse event, paste, focus transition,
or resize behind it. Refresh requests remain serialized on their own lane;
this is transport isolation, not concurrent mutation of a session or relaxation
of the daemon's authoritative input ordering.

The refresh worker also prepares the Metal resource wrapper for each newly
fetched immutable image generation before publishing that generation.
`MTLDevice` resource creation and the byte fallback's initial `replaceRegion`
copy are allowed off the AppKit thread. RFC 0015's mapped staging resource is
different: RFC 0023 publishes an unsubmitted no-copy-buffer/texture pair with
the coherent snapshot, then the first displaying frame encodes its blit before
the ordinary image draw in that frame's existing command buffer. There is no
refresh-worker GPU wait. The published viewer resource owns one retain, the
renderer cache owns another while active, and in-flight frame slots retain what
they bind. Preparation failure preserves the previous coherent resource set.
Hiding a session drops its prepared-resource retain on the worker.
Byte-fallback resources may keep their bounded adopted socket backing; staged
resources have no viewer CPU copy and are removed from the local cache, then
staged again from the authoritative daemon generation when reactivated. Thus
background sessions multiply neither VRAM nor transport mappings by resource.

Damage wakes display-link-driven presentation. At most one frame is submitted
per display refresh, and arbitrarily many daemon events may collapse into that
frame. Coalescing applies only to presentation: the daemon still parses every
PTY byte and applies every Kitty command, acknowledgement, resource mutation,
placement, and deletion in order. The viewer presents the newest complete
state available at a tick and retains damage if no frame resource is
available. Idle sessions submit nothing.

The live Metal path owns a bounded ring of mutable frame resources (normally
three). A slot contains every CPU/GPU buffer and resource retention needed by
one in-flight command buffer. Metal completion handlers release slots and the
textures/resources referenced by that frame. The AppKit thread never removes
`waitUntilCompleted` while reusing a single buffer; the wait disappears only
after the ring proves that no in-flight data can be overwritten. If every slot
is busy, presentation is skipped and damage remains pending rather than
blocking UI input. Exact offscreen readback continues to wait synchronously,
and live resize may use its separately documented scheduling boundary.

After these bounded changes, re-profile before adding a daemon-to-viewer
shared-resource, staging-buffer, or IOSurface protocol. A new private transport
requires its own lifetime and quota amendment; it is not inferred merely from
high copy bandwidth. That re-profile isolated the remaining full-frame transfer
cost; draft RFC 0015 owns the resulting shared-memory staging decision and its
lifetime, quota, fallback, and crash contracts.

## Latency stance

Target: keypress→pixel within one frame under normal load. Measure before
optimizing (Typometer or ghostty's methodology). Do not chase sub-vsync
tricks (no `presentAfterMinimumDuration` games) until a measurement says so.

## Synchronized output (amended 2026-08-16)

DEC private mode 2026 is a presentation boundary. Between BSU
(`CSI ? 2026 h`) and ESU (`CSI ? 2026 l`), the VT continues parsing and
mutating its grid normally, but the shell keeps the last presented frame;
it must not expose intermediate clears, cursor moves, or partially repainted
rows. ESU schedules one frame from the newest complete state.

The boolean mode and a monotonically increasing BSU epoch live in the pure VT
state. Timing stays in the shell: each BSU arms/re-arms a one-second watchdog,
matching Ghostty's fail-safe, so a crashed or malicious child cannot freeze
the window forever. Watchdog expiry and a successful terminal resize reset the
mode and schedule a frame. Bell/title effects are not screen frames and remain
deliverable while presentation is held.

Codex's inline TUI is the motivating fixture: it hides the cursor, moves it
through status/output/composer repaint positions, restores it at the composer,
then emits ESU. Only that final cursor position may become visible.

## Testing

Golden-image tests construct grid states in code and render offscreen (the
webmotion offscreen path already exists). Renderer-owned pixels are compared
exactly. CoreText and Apple Color Emoji raster bytes are exact only on the
reference OS/font stack: Apple may change system font artwork and antialiasing
between macOS releases without changing terminal geometry. The default local
suite therefore retains whole-buffer hashes, while an explicit portable CI
mode asserts dimensions, bearings, style/fallback selection, premultiplication,
visible raster content, and non-uniform Metal output without pinning those
OS-owned bytes. Corpus: SGR matrix, wide chars, cursor styles, selection,
underline styles, fallback fonts (emoji, Devanagari, CJK).

The harness renders through the production pipelines into a shared-storage
`BGRA8Unorm` Metal texture—never a `CAMetalLayer` or window—waits for command
completion, and reads back tightly packed top-to-bottom rows. Fixture viewport
dimensions remain in points while the texture dimensions encode the pinned
backing scale, matching live presentation. Reference-host goldens compare the
complete byte buffer exactly (a pinned whole-buffer hash is an acceptable
compact encoding of that comparison) and report dimensions separately so
geometry changes cannot hide behind a new hash. Portable CI never replaces an
exact renderer-owned fixture with a perceptual comparison; its relaxed path
applies only to fixtures containing system-font pixels.

Flat backgrounds, selection, and block cursor form one glyph-independent
fixture. Mask glyphs plus underline/strike decorations form a second fixture;
color emoji and the mixed fallback matrix remain separate so a CoreText or
color-atlas change cannot obscure a quad-composition regression. Tests skip
only when no Metal device exists; they do not silently fall back to a CPU
renderer that the product does not use. Portable mode weakens only the
system-owned byte comparison and is selected explicitly by the build, never by
ambient CI environment variables.

## Reference when stuck

Ghostty `src/renderer/` (Metal renderer with the same cell-instancing shape)
and its `src/font/` (CoreText discovery/rasterization/atlas). See
docs/references/prior-art.md for how to read it without importing its
complexity.

For synchronized output specifically, Ghostty commit
`9009122953f59d4900143aad587202a70c2136f4` is the consulted oracle:
`src/renderer/generic.zig` suppresses frames while mode 2026 is set and
`src/termio/Thread.zig` releases it after a one-second watchdog.
