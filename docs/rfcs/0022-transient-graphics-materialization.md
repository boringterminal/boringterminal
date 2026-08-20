# RFC 0022: Transient graphics materialization

Status: draft

## Decision

Do not replace RFC 0015's synchronous staging blit by intuition. Keep the
production path unchanged while three standard Metal materialization paths are
measured against the same bytes, shader, output target, dimensions, and
resource-lifetime policy:

1. the current buffer-to-texture blit, completed before publication;
2. a blit and image draw encoded in one command buffer, with no CPU wait
   between them;
3. a linear texture view over the staging buffer, sampled directly.

`zig build graphics-transport-bench -Doptimize=ReleaseSafe` is the local
laboratory. It runs 720p, 1080p, 1440p, and 4K sweeps, reports p50, p95, and
maximum end-to-end GPU completion latency, and measures both resource reuse
and per-generation resource recreation. `--json` emits stable machine-readable
records; `--size`, `--warmup`, and `--frames` isolate a workload. These
timings are evidence, never CI pass/fail thresholds because Metal hardware,
power state, display load, and virtualization differ.

A path the selected Metal device cannot construct is omitted from the result,
not treated as failure of the portable baseline. The ordinary synchronous
path must remain available.

The ordinary test suite renders a deterministic padded-row RGBA pattern
through every candidate and both lifetime modes, then compares every output
pixel. Candidate primitives may exist in the renderer laboratory, but no
daemon, viewer cache, lease, or presentation behavior changes until this RFC
is accepted with a winning policy.

## Problem statement

RFC 0015 removed socket serialization of decoded Kitty graphics by staging
pixels in bounded shared memory. The viewer currently wraps the mapping in a
no-copy `MTLBuffer`, creates an ordinary texture, submits a blit, waits for the
command buffer, then releases the daemon slot and publishes the texture.

This is coherent and bounded, but it serializes the refresh worker with GPU
materialization. The cost is proportional to the backing-pixel area, so a
graphics-heavy full-width pane can become visibly less fluid than the same
application at half width. Terminal-browser also performs browser layout and
rasterization after every PTY resize; that work amplifies the symptom but does
not explain a viewer worker blocked inside Metal.

This RFC covers only the daemon-to-viewer materialization boundary. It does
not change Kitty semantics, invent an application-specific video path, or
weaken the daemon-owned session model.

## Observations before a production experiment

### Live process profile

A 20-second `sample` capture on 2026-08-20 while terminal-browser was
continuously presenting found:

- 13,176 of 13,488 main-thread samples in the AppKit run loop, so the main
  thread was about 97.7% idle;
- about 127 image-texture retirements on the main thread, consistent with only
  about 6.35 new graphics generations per second in that interval;
- 3,444 refresh-worker samples under
  `prepareStagedSessionImage -> copyBufferToTexture -> waitUntilCompleted`, or
  about 3.44 seconds blocked in the 20-second capture;
- about 127 observed uploads, implying roughly 27 ms of blocked worker time per
  published generation in that live workload.

The capture did not contain a live-resize callback, so it is not presented as
a resize trace. It establishes a sustained graphics materialization ceiling.
The complete local capture remains outside the repository at
`/tmp/boringterminal_2026-08-20_015829_tAh1.sample.txt`.

### Isolated Metal sweep

The initial controlled sweep used an Apple M1 7-core GPU on macOS 14.4.1,
20 warm-up iterations and 120 measured iterations per cell. Times include
sampling into and completing the same BGRA target. Representative p95 results
in milliseconds were:

| Lifecycle | Path | 720p | 1080p | 1440p | 4K |
|-----------|------|-----:|------:|------:|---:|
| reuse | synchronous blit | 2.14 | 4.24 | 8.90 | 15.25 |
| reuse | fused blit + sample | 2.00 | 4.05 | 7.42 | 15.43 |
| reuse | direct linear sample | 1.86 | 4.09 | 6.86 | 14.32 |
| recreate | synchronous blit | 2.68 | 6.22 | 9.22 | 17.90 |
| recreate | fused blit + sample | 2.44 | 5.41 | 8.63 | 18.05 |
| recreate | direct linear sample | 1.92 | 5.61 | 7.41 | 15.75 |

The raw JSON is `/tmp/boring-graphics-transport-2026-08-20.json`; it is not a
portable golden. Direct sampling wins this machine's 1440p and 4K p95 by about
12–20% under recreation, but the fused path is not consistently better at 4K
and direct sampling still consumes most of a 16.67 ms 4K frame budget. This is
not enough evidence to select a production policy by itself.

The isolated sweep also waits for the final draw, whereas the production main
thread submits presentation asynchronously. The live profile and isolated
sweep answer different questions and must not be collapsed into one number:
the former locates the CPU wait; the latter bounds total GPU work and compares
layout choices.

## Relevant platform constraints

Apple exposes a texture view over `MTLBuffer` through
`newTextureWithDescriptor:offset:bytesPerRow:`. It shares the buffer's storage,
requires the device's linear-texture alignment, and requires the buffer to
outlive every texture use. Apple also warns that Metal may not optimize a
buffer-backed texture as it does an ordinary texture. Linear sampling removes
the materialization copy but can trade it for repeated non-optimal reads.

Storage mode is hardware-dependent. Shared memory is native on Apple silicon;
macOS systems with a discrete GPU use managed or private resources differently.
Ghostty selects shared storage only on unified-memory devices and managed
storage otherwise. Boring Terminal therefore cannot make an M1-only result its
universal macOS policy. A direct path requires a capability-checked fallback,
and a fused private-texture path remains a first-class candidate for discrete
GPUs.

Primary references, retrieved 2026-08-20:

- Apple buffer-backed textures and documented layout caveat:
  https://developer.apple.com/documentation/metal/mtlbuffer/maketexture%28descriptor%3Aoffset%3Abytesperrow%3A%29
- Apple linear texture alignment:
  https://developer.apple.com/documentation/metal/mtldevice/minimumlineartexturealignment%28for%3A%29
- Apple resource storage modes:
  https://developer.apple.com/documentation/metal/setting-resource-storage-modes
- Apple texture layout optimization:
  https://developer.apple.com/documentation/metal/optimizing-texture-data
- Ghostty's unified/discrete Metal storage-mode selection:
  https://github.com/ghostty-org/ghostty/blob/main/src/renderer/Metal.zig

Kitty source is not an implementation reference. Only its published graphics
protocol defines the child-facing semantics, and this RFC does not change
those semantics.

## Candidate policies

### A. Synchronous immutable materialization

This is the current policy. It has the simplest lease: the staging slot is
released after the blocking blit and the ordinary texture is then independent.
It is the correctness baseline, not an acceptable default if the refresh
worker misses source cadence at realistic pane sizes.

### B. Fused asynchronous materialization

Encode the staging-buffer blit before the image draw in the same command
buffer. Publish a pending texture with the frame and release the exact staging
lease from GPU completion. This preserves an optimized ordinary texture and
avoids a CPU wait between copy and draw.

The GPU copy remains. The viewer must keep the mapping, `MTLBuffer`, texture,
bulk connection, and lease token alive through completion. A failed or
superseded command buffer must release exactly its own token and must never
publish partial pixels.

### C. Direct transient sampling

Create a linear texture view over the staging buffer and sample it in ordinary
image draws. This removes the GPU copy. The texture, buffer, mapping, connection
and exact daemon lease must remain alive until the final in-flight frame that
can sample them completes.

This cannot be the permanent cache representation for static images: three
daemon staging slots would otherwise remain leased by three old images. A
production policy would need one of these generic, client-agnostic rules:

- direct sampling only while a generation is actively being replaced, then
  asynchronous promotion to an ordinary texture after an idle boundary; or
- direct sampling for one presentation followed immediately by asynchronous
  promotion when the image remains referenced.

No rule may inspect a process name, title, command line, image contents, or
terminal-browser-specific metadata.

### D. IOSurface over authenticated XPC/Mach transport

IOSurface can expose a GPU-native cross-process texture and remains the likely
ceiling if A–C fail. It also adds a second IPC capability mechanism, Mach/XPC
lifecycle, authentication, and a new crash-recovery surface. RFC 0015's
rejection of globally visible IOSurface IDs stands. This candidate requires a
separate RFC and measurements showing that socket-passed shared memory plus
Metal cannot meet the gate.

## Correctness and lifetime gates

Before B or C can be accepted, automated tests must prove:

- active RGBA bytes survive non-tight, alignment-padded rows exactly;
- the source allocation cannot be unmapped while a buffer, texture view, or
  in-flight command buffer can reference it;
- a staging lease is released only after its exact GPU completion;
- stale completion for token N cannot release a slot already leased as N+1;
- a superseded generation remains valid for every already-submitted frame but
  is never published to a newer snapshot;
- graphics-busy remains bounded to RFC 0015's three slots and coalesces to the
  newest generation without blocking PTY input;
- disconnect and renderer failure drain pending leases without using revoked
  mappings;
- unsupported storage/layout combinations take the ordinary RFC 0015 path;
- static images eventually release staging and reuse the ordinary cache;
- paired panes cannot alias resource identity or staging ownership.

The current laboratory covers exact padded-row pixels and resource recreation.
Lease and disconnect tests land with the production lifetime object, not as a
mock that claims behavior no application code uses.

## Performance gate

A production candidate must pass both layers:

1. **Synthetic:** run the ReleaseSafe sweep three times after a quiet warm-up,
   save JSON with hardware/OS metadata, and compare p50/p95/max at the actual
   full-pane backing resolution. No regression larger than 5% is accepted at
   720p/1080p to buy a 4K-only win.
2. **Application:** run terminal-browser video for 20 minutes at full-pane and
   paired half-pane widths, with and without pointer motion, then exercise live
   resize. The viewer must present at least 95% of source cadence after warm-up,
   refresh p99 must stay within one source-frame interval, input must remain
   responsive, and viewer/daemon/staging memory must remain bounded.

An Instruments/System Trace or `sample` capture must verify that the selected
path removed the refresh-worker wait rather than moving it to AppKit. Temporary
Debug signposts/counters are permitted for the acceptance run and removed
before release. The benchmark stays because it is a maintenance tool, not
product telemetry.

## Security consequences

The candidates do not change RFC 0015's same-user trust boundary. Their new
risk is lifetime safety: a daemon may legitimately reuse a released slot, so a
GPU reference surviving release can display another generation and read memory
that no longer belongs to that frame. The lease must therefore be an owned
capability held by GPU/frame lifetime, never a `defer` tied to the refresh
stack.

No direct path may accept a child-selected mapping, stride, offset, storage
mode, or texture extent. Existing daemon-created objects, protocol bounds,
`fstat` validation, alignment checks, non-executable mappings, and aggregate
memory quotas remain mandatory.

## Relationship to existing RFCs

- RFC 0004 owns display cadence, the three in-flight frame slots, and texture
  retention through GPU completion.
- RFC 0009 owns coherent live-resize presentation and latest-only geometry.
- RFC 0013 owns Kitty resources and protocol semantics.
- RFC 0015 owns shared-memory staging, daemon leases, failure fallback, and
  quotas. This RFC may amend only viewer materialization after its gates pass.
- RFC 0023 specifies the accepted production lifecycle for candidate B. This
  RFC remains the measurement record and candidate laboratory.
