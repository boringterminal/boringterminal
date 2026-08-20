# RFC 0023: Frame-pipelined graphics uploads

Status: accepted

## Decision

Materialize daemon-staged image generations as part of the Metal frame that
first displays them. The viewer will encode all required buffer-to-texture
blits before the render pass in the frame's existing command buffer, submit
that work without a CPU wait, and hold each exact daemon staging lease until
Metal reports completion.

The production path remains an ordinary GPU-optimized RGBA texture. Directly
sampling a linear texture over daemon staging memory remains an experiment,
not the default. It saves one copy but extends the daemon lease through every
frame that samples the image, performs device-dependent texture reads, and
measured only a modest advantage on the initial M1 laboratory sweep.

This RFC selects candidate B from RFC 0022. It does not change Kitty graphics
semantics, the daemon-owned session model, or the byte-transport fallback in
RFC 0015.

## Why this exists

RFC 0015 removed repeated multi-megabyte socket payloads by staging decoded
pixels in three daemon-owned shared-memory slots. Its initial viewer path is
deliberately conservative:

1. wrap the slot mapping in a no-copy `MTLBuffer`;
2. create an ordinary Metal texture;
3. submit a buffer-to-texture blit;
4. call `waitUntilCompleted` on the refresh worker;
5. release the daemon lease and publish the prepared texture.

That preserves a simple lifetime boundary, but it serializes display refresh
with GPU materialization. A live 20-second profile in RFC 0022 found the
refresh worker blocked for about 3.44 seconds in this wait while the AppKit
thread remained about 97.7% idle. Approximately 127 generations were observed,
or roughly 27 ms of blocked worker time per published generation. The cost
scales with pixel area, which explains why a graphics-heavy full-width pane is
less fluid than the same client at half width.

The custom Metal renderer already owns a three-slot in-flight frame ring,
retains every texture referenced by a submitted frame, and receives an exact
GPU-completion callback. The missing optimization is not a new renderer or a
special video path. It is carrying the staging capability through that
existing lifetime instead of resolving it synchronously before the renderer
can see it.

## Scope

This RFC owns:

- the handoff of a staged generation from the refresh worker to the renderer;
- ordering its materialization before the draw that first samples it;
- staging-slot, mapping, buffer, texture, cache, and frame ownership;
- completion-driven release without socket I/O in a Metal callback;
- coalescing generations that have not been submitted;
- bounded destination-texture reuse;
- failure, disconnect, shutdown, and memory-pressure behavior;
- automated and measured acceptance gates.

It does not own:

- Kitty decoding, placement, animation, acknowledgement, or deletion rules;
- child-to-daemon graphics transport;
- browser layout or rasterization after `SIGWINCH`;
- display-link cadence or live-resize transaction policy;
- a process, title, or application-specific rendering branch;
- IOSurface or a second IPC authority surface.

## Prior art

### Apple Metal

Apple's command-organization guide describes one command buffer containing the
work for a frame, including multiple command encoders. Buffers committed to a
single long-lived command queue execute in order. Boring Terminal can therefore
encode a tracked blit pass followed by its render pass without a CPU wait or a
second queue synchronization primitive.

Apple's CPU/GPU synchronization sample uses three instances of a mutable
resource, commits one command buffer per frame, and returns a resource to the
pool from the command-buffer completion handler. Its stated purpose is to let
CPU and GPU work overlap without either processor overwriting an in-flight
resource. This is the same scheduling rule as RFC 0004's frame ring; the new
resource here is an exact daemon staging lease.

Apple also advises creating expensive shared objects once and reusing them.
The destination texture recycle pool below follows that rule, but remains a
bounded optimization rather than a correctness dependency.

Primary references, retrieved 2026-08-20:

- Apple, *Command Organization and Execution Model*:
  https://developer.apple.com/library/archive/documentation/Miscellaneous/Conceptual/MetalProgrammingGuide/Cmd-Submiss/Cmd-Submiss.html
- Apple, *Synchronizing CPU and GPU work*:
  https://developer.apple.com/documentation/metal/synchronizing-cpu-and-gpu-work
- Apple, *Setting up a command structure*:
  https://developer.apple.com/documentation/Metal/setting-up-a-command-structure
- Apple, `MTLCommandQueue`:
  https://developer.apple.com/documentation/metal/MTLCommandQueue
- Apple, `MTLCommandBuffer.addCompletedHandler(_:)`:
  https://developer.apple.com/documentation/metal/mtlcommandbuffer/addcompletedhandler%28_%3A%29

### Ghostty

Ghostty's Metal `Frame` creates one command buffer for a frame, registers a
completion handler for the normal asynchronous path, and calls
`waitUntilCompleted` only when the caller explicitly requests synchronous
completion. Its completion path reports frame health back to the renderer.
Ghostty's texture wrapper also gives reusable Metal textures explicit owned
lifetimes.

This is scheduling prior art, not transport prior art. Ghostty renders in the
process that owns its image bytes and does not solve Boring Terminal's
replaceable-viewer staging lease. No Ghostty lifetime rule is copied across
that missing boundary by assumption.

- Ghostty Metal frame:
  https://github.com/ghostty-org/ghostty/blob/main/src/renderer/metal/Frame.zig
- Ghostty Metal texture:
  https://github.com/ghostty-org/ghostty/blob/main/src/renderer/metal/Texture.zig

Kitty source is not an implementation reference. Its published graphics
protocol remains the child-facing specification, but this RFC is entirely
below that semantic boundary.

## Terms and identities

`ResourceKey`
: `(session_id, image_id, generation)`. A texture prepared for one key is never
  published for another.

`StagingKey`
: `(graphics_connection_epoch, slot_index, lease_token)`. This is the exact
  capability whose release permits the daemon to overwrite the slot. A token
  from an old connection is never replayed on a new connection.

`StagedUpload`
: An owned viewer object containing both keys, validated dimensions, row
  stride, mapping identity, the slot's no-copy `MTLBuffer`, and an unsubmitted
  destination texture. At most three can exist because RFC 0015 exposes only
  three leased slots. Resource construction may happen on the refresh worker;
  no GPU work happens until a displaying frame adopts it.

`submitted texture`
: A destination texture whose full blit has been committed on the renderer's
  one command queue but whose command buffer may not yet have completed.
  Later command buffers on that queue may sample it because queue ordering and
  default Metal hazard tracking preserve the dependency.

`ready texture`
: A submitted texture whose upload command buffer completed successfully.

`ReleaseRecord`
: The immutable `StagingKey` moved to the daemon client's bounded release
  mailbox after the renderer no longer owns any GPU reference to its source.

## Ownership state machine

Every successful `stage_image` response creates exactly one viewer-side owner
of its staging capability:

```text
fetched(worker)
    -> queued(renderer)
        -> submitted(frame slot)
            -> gpu_complete(completion drain)
                -> release_pending(bulk worker)
                    -> released
```

Branches are explicit:

```text
fetched | queued -> superseded -> release_pending -> released
fetched | queued -> preparation_failed -> release_pending -> released
submitted -> gpu_failed -> release_pending -> released + shared-path disabled
any state -> connection_revoked -> locally_retired
```

There is no borrowed staging lease and no `defer` tied to the refresh stack.
Moving between states transfers the only authority to release it. Invalid or
duplicate transitions are programmer errors in Debug tests and harmless
connection failure in ReleaseSafe; they never guess that a slot is reusable.

The connection epoch is part of every transition. If its graphics connection
closes, the daemon revokes all leases in that epoch. Later local cleanup may
destroy buffers and mappings, but it must discard rather than transmit their
old `ReleaseRecord`s.

## Atomic display handoff

The refresh worker continues to construct one coherent display update from an
authoritative daemon snapshot. The update now carries both:

- the snapshot's resource and placement identities; and
- up to three owned `StagedUpload`s required by those identities.

The worker hands the complete update to the main/renderer owner in one
publication. It does not publish a snapshot and race a separate upload queue.
The renderer installs the resource references and their pending uploads
atomically. Existing byte-backed resources remain ready textures and need no
new state.

If a newer coherent update arrives before an upload is submitted, the renderer
may rebind the upload when the same `ResourceKey` is still referenced. If the
key is obsolete, it moves the old lease to `release_pending` without encoding
GPU work. It never discards terminal protocol state: only an unpresented image
generation is coalesced, as RFCs 0004 and 0015 already permit.

The renderer retains the last coherent presented update separately from a
new desired update containing queued uploads. Failure or temporary drawable
unavailability can therefore continue showing the last coherent frame rather
than a partial or blank one.

## Frame encoding and publication

For each display tick with a frame slot and drawable:

1. collect queued uploads referenced by the desired display update;
2. create the frame's one command buffer;
3. encode all full-region buffer-to-texture copies in one blit encoder;
4. end the blit encoder;
5. encode the ordinary image and terminal render passes, sampling those
   destination textures;
6. retain every source buffer, destination texture, and `StagingKey` in that
   frame slot;
7. register the normal completion handler and transfer the uploads to the
   submitted frame slot;
8. present and commit.

Metal's commit call has no recoverable return value. The ownership transition
therefore occurs after encoding and completion registration, immediately
before commit: at that point only the frame slot can retire the source,
including when Metal later reports failure.

Default Metal hazard tracking remains enabled. A blit write followed by a
render read in the same command buffer needs no CPU wait, second command queue,
or child-visible synchronization. Subsequent frames may use the submitted
texture on the same command queue; they are ordered after its materialization.

If there is no drawable or no available frame slot, the upload stays queued
and damage stays pending. No blit is submitted merely to empty the daemon's
staging ring. If command encoding fails before commit, no GPU owns the source;
the renderer may retry the same queued upload once or select RFC 0015's byte
fallback according to the failure class.

The cache owns the destination texture after commit, not the staging mapping.
Completion promotes it from submitted to ready. Static images therefore
release staging after their first successful frame and retain only the same
ordinary texture representation used today.

## Completion and release threading

Metal completion handlers must remain bounded and non-blocking. They do not:

- perform Unix-socket I/O;
- take the daemon client's refresh mutex;
- call AppKit;
- allocate; or
- unmap shared memory.

The callback records command-buffer status in its `FrameSlot`, atomically marks
the slot complete, and requests one coalesced `dispatch_async_f` hop to the
main queue. At most one such hop is outstanding, and the callback performs no
project-allocator operation. The completion drain runs even if no later display
tick occurs. It:

1. destroys per-frame source-buffer retains and other GPU-only references;
2. updates submitted texture entries to ready or failed;
3. moves each immutable `StagingKey` into the owning daemon client's
   fixed-capacity release mailbox; and
4. wakes that client's bulk/refresh worker.

Only after the no-copy buffer can no longer refer to an in-flight command may
the bulk worker send `release_staged_image`. The worker serializes the command
on the existing bulk connection, decrements its active-lease count, and then
may replace or unmap the connection-local slot mapping.

The release mailbox has capacity three, equal to the daemon staging ring. Its
capacity is structural, not a tunable queue. Overflow violates the ownership
invariant; the safe ReleaseSafe response is to close the graphics connection,
letting the daemon revoke every lease, latch byte fallback, and preserve the
last coherent frame. A release is never dropped while the connection remains
usable.

## Destination-texture reuse

New generations normally have the same dimensions and format as the generation
they replace. Recreating a destination texture for every frame is avoidable,
but reuse must never race an in-flight read.

A later renderer optimization may own a global recycle pool for unreferenced
image textures:

- exact match only: pixel format, width, height, mip count, usage, and storage
  mode must agree;
- no eager allocation;
- no texture enters the pool while owned by the active cache or retained by a
  frame slot;
- a reused texture receives a full validated-region blit before any draw;
- at most three textures and at most 64 MiB are retained, whichever limit is
  reached first;
- memory pressure and viewer backgrounding may empty the pool immediately;
- allocation failure clears the unused pool once, then selects byte fallback
  without an unbounded retry loop.

Active cache textures remain governed by RFC 0004 and are not counted as
recyclable. The pool is an optional latency optimization; disabling it must
not change pixels, lease release, or protocol behavior. It is intentionally
disabled in the first accepted implementation: the live post-change profile
placed the removed GPU wait, not off-main texture construction, on the critical
path, and the isolated reuse/recreate sweep did not establish a stable
frame-time win.

Texture lookup and reuse remain renderer-owned and O(3). A pool miss may create
one texture on the main thread. Acceptance profiling must measure that miss;
if texture creation itself becomes a material main-thread stall, a dedicated
resource-preparation design requires a follow-up amendment rather than a
silent general-purpose render thread.

## Resize and paired panes

An image upload is keyed by content generation, not pane geometry. A pending
upload may survive a resize and be drawn at the new placement if the newer
coherent snapshot still references the same `ResourceKey`. It is released
without submission if the generation is no longer referenced.

RFC 0009 still owns live browser re-layout, transactional presentation, and
the clipped/padded last-coherent fallback. This RFC removes a viewer-side GPU
wait; it does not promise that a graphics application can rebuild a full-width
surface at arbitrary resize frequency.

Paired panes share the renderer command queue and destination pool but not
resource identity. `(session_id, image_id, generation)` remains the cache key.
One frame may encode uploads for both panes before drawing either. The global
three-slot staging bound and one release mailbox still apply; pairing does not
multiply them.

## Failure, disconnect, and shutdown

- **Superseded before commit:** release the exact lease without GPU work and
  return an unused destination texture to the recycle pool.
- **No frame resource:** keep only the newest coherent desired update and
  retry on a later tick; never block AppKit or a PTY reader.
- **GPU command-buffer error:** retire every source safely, invalidate every
  texture first materialized by that buffer, preserve the last coherent frame,
  close the graphics lane, and latch byte fallback before the next refresh.
- **Graphics connection closes:** stop submitting its queued uploads. Already
  submitted frames retain their local buffers/mappings until completion; the
  daemon has revoked the remote leases, and old release records are discarded.
- **Viewer closes normally:** drain or wait for the three live frame slots as
  part of teardown, destroy no-copy buffers, then unmap and close the graphics
  connection. A teardown-only wait is permitted; steady-state waits are not.
- **Viewer crashes:** process teardown closes the graphics socket, so the
  daemon revokes every lease while keeping sessions and PTYs alive.
- **Daemon crashes:** local frame resources may finish from their existing
  mappings; no new frame uses the dead epoch, and final cleanup releases all
  Metal wrappers before unmapping.
- **Bulk release fails:** close the lane and treat all its leases as revoked;
  never reconnect and replay a token.
- **Pool allocation or memory pressure:** clear unused recycled textures and
  use RFC 0015 byte transport if an ordinary destination still cannot be made.

No failure path presents a partly copied texture or converts `graphics_busy`
into an unbounded byte-transfer loop.

## Security consequences

The same-user authority boundary from RFC 0015 is unchanged. The new risk is
use-after-release across processors: releasing a staging slot before the GPU's
last read allows the daemon to overwrite memory still referenced by a command
buffer. The explicit state machine and completion-bound release are therefore
security properties, not only performance bookkeeping.

The daemon continues to choose the shared object, capacity, slot, and lease
token. Child-controlled dimensions and stride are checked against authoritative
resource metadata, mapped capacity, Metal alignment, overflow limits, and the
64 MiB single-image ceiling before an upload is queued. Mappings remain
non-executable. Neither a child nor a texture shader selects an offset outside
the validated active rows.

The completion mailbox contains capabilities but is process-local, fixed-size,
and never persisted. Connection epochs prevent an old completion from releasing
a newer connection's slot. The texture pool contains only viewer-owned Metal
objects after staging release and grants no daemon or child capability.

## Automated verification

The production lifetime object, not a test-only imitation, must support
deterministic injected completion so tests can prove:

- every legal state transition and rejection of every illegal transition;
- one and only one release for each successful stage response;
- exact `(epoch, slot, token)` preservation through completion;
- stale completion cannot release a new lease or new connection;
- no release becomes sendable before source-buffer GPU retirement;
- cancellation before commit performs no Metal upload;
- committed uploads are encoded before their first draw;
- padded rows and all active RGBA pixels match the synchronous reference;
- later frames on the same queue sample a submitted texture coherently;
- GPU failure invalidates dependent cache entries and selects fallback;
- three pending/submitted leases produce bounded backpressure, never a fourth
  queued capability;
- the release mailbox drains after the final frame even when rendering becomes
  idle;
- paired sessions cannot alias cache or lease identity;
- if texture reuse is enabled later, it waits for both cache eviction and final
  frame completion and obeys the exact compatibility, count, and byte limits;
- descriptor replacement releases the old no-copy buffer before unmapping;
- connection loss, normal shutdown, and injected release failure leave no
  live local mapping or remote lease.

The existing RFC 0022 padded-row Metal laboratory remains the pixel oracle.
A real-daemon integration test must additionally hold a slot through an
injected delayed completion, observe `graphics_busy`, complete the frame, and
then observe that the exact slot becomes reusable.

## Performance verification

Acceptance requires evidence from both the isolated laboratory and the real
application. Debug-only signposts/counters may record stage response, queue,
commit, GPU completion, release acknowledgement, pool hit/miss, refresh
duration, and presented generation. They are removed before release; this is
not product telemetry.

1. Run RFC 0022's ReleaseSafe sweep three times at 720p, 1080p, 1440p, and 4K
   with hardware, OS, lifecycle mode, and raw JSON recorded.
2. Profile the viewer while a graphics client continuously updates for 20
   minutes at full-pane and paired half-pane widths, both stationary and with
   pointer motion.
3. Exercise live resize, pane zoom/unzoom, tab switching, sidebar resizing,
   app hide/show, and viewer close/reopen during the run.
4. Verify with Instruments or `sample` that no refresh or AppKit path contains
   a steady-state `waitUntilCompleted` and that release IPC never runs in a
   Metal callback.
5. Confirm presented cadence reaches at least 95% of the complete source
   generations available after warm-up when the display refresh can represent
   that cadence. Coalesced generations above display cadence are counted
   separately, not as failures.
6. Confirm input and pointer handling remain responsive, frame slots do not
   starve, no frame stretches or blanks, and viewer/daemon memory reaches a
   stable plateau rather than growing with frame count.
7. Compare pool-on and pool-off runs. The pool ships only if it improves
   upload/commit p95 without raising frame-time p95 by more than 5% at smaller
   resolutions.

### Initial implementation evidence (2026-08-20)

The production fused path is covered by an exact-pixel offscreen test using
padded, read-only mapped rows. The test uses the production `StagedUpload`,
encodes the blit before the draw in one command buffer, validates the sampled
pixel, and observes the exact release capability only after GPU completion.
The real-daemon fixture holds all three transport leases, observes
`graphics_busy`, releases one exact capability, and verifies that slot alone is
reused with a new token.

A 10-second ReleaseSafe application sample against a continuously updating
full-pane graphics session contained no `waitUntilCompleted` under
`prepareStagedSessionImage` or the refresh worker. Frame submission contained
the blit followed by the ordinary draw, the main completion drain retired the
no-copy buffers, and release acknowledgement waits appeared only on the
dedicated release worker. The local capture is
`/tmp/boringterminal-rfc0023.sample.txt`; it is machine-local evidence, not a
repository fixture or portable timing golden.

The project owner subsequently completed and accepted the 20-minute
application soak at full and paired widths, including stationary and moving
pointer phases, live resize, pane zoom/restore, session switching, sidebar
hide/show, and viewer replacement. No return of the hover collapse, frame
stretching/blanking, input stall, frame-slot starvation, or growing-memory
behavior was observed. This closes the application acceptance gate; the
optional destination-texture pool remains disabled because no measurement
justifies its added lifecycle surface.

The acceptance claim is that Boring Terminal no longer serializes its refresh
worker with GPU upload. It is not a claim that browser layout, video decode,
or full-surface rasterization has become free.

## Rollout

1. Land the owned upload state machine, release mailbox, injected completion,
   and real-daemon delayed-release tests while production remains synchronous.
2. Teach the renderer to carry uploads in `FrameSlot` and encode blit then draw
   through its existing command queue. Keep the byte path unchanged.
3. Enable the asynchronous path in development builds, run the correctness and
   performance gates, and resolve every failure without app detection or queue
   growth.
4. Make the fused path the sole shared-staging production path. Remove the old
   refresh-worker wait; retain synchronous waits only for offscreen readback,
   tests, and orderly shutdown.
5. Enable the bounded recycle pool only after its separate pool-on/off gate.
   The initial accepted implementation stops after step 4.

There is no user-facing graphics-performance toggle. Unsupported or failed
shared transport already has RFC 0015's deterministic byte fallback.

## Rejected alternatives

### Move the wait to AppKit

This would trade choppy graphics for a frozen application and contradict the
renderer frame ring. Rejected.

### Keep a separate upload command buffer and wait elsewhere

An asynchronous upload-only buffer can remove the refresh-worker wait, but it
adds a publication boundary and either delays the first draw until completion
or needs cross-buffer dependency bookkeeping. The existing frame already has
the correct lifetime and ordering boundary. Rejected as the default shape.

### Use a second Metal command queue

It requires an explicit inter-queue event/fence before drawing and creates more
ways to outlive a staging lease. One ordered queue has enough parallelism for
the measured workload. Rejected until a profile proves queue serialization,
not pixel work, is the next bottleneck.

### Directly sample daemon staging forever

It consumes one of three staging slots for the lifetime of a static cache entry,
is less portable across unified and discrete GPUs, and measured only a modest
M1 advantage. It remains an RFC 0022 experiment, not this policy.

### Unbounded upload queue or per-session staging ring

Both turn display lag into memory growth and multiply daemon transport memory
with background sessions. The shared three-slot ring is deliberate. Rejected.

### Lower Kitty graphics cadence or detect terminal-browser

This hides a viewer pipeline stall by degrading a standards-compliant client
and violates the application-agnostic architecture. Rejected.

### Stretch the last image while resizing

It may appear smoother while presenting incorrect geometry and reintroduces
the rubber-sheet defect fixed by RFC 0009. Rejected.

### Release the staging slot after command-buffer commit

Commit is not GPU completion. The daemon could overwrite bytes before the blit
reads them. Rejected as unsafe.

### Send release IPC from the Metal completion callback

Socket I/O, mutex acquisition, allocation, and reconnection do not belong on a
Metal callback thread. The bounded completion drain and mailbox preserve the
same latency without that reentrancy. Rejected.

### IOSurface now

IOSurface may remove another copy, but introduces Mach/XPC capability transfer
and a new crash/compatibility surface before the ordinary Metal pipeline is
used correctly. RFC 0022 keeps it as a measured future escalation. Rejected for
this phase.

## Relationship to existing RFCs

- RFC 0004 owns display cadence, the one-command-buffer live frame, and the
  three in-flight frame slots extended here with upload ownership.
- RFC 0009 owns live-resize geometry and last-coherent fallback presentation.
- RFC 0013 owns public Kitty graphics semantics and resource identity.
- RFC 0015 owns shared staging, connection epochs, slot tokens, quotas, byte
  fallback, and crash recovery. Once accepted and shipped, this RFC replaces
  only its initial synchronous viewer-materialization paragraph.
- RFC 0022 remains the measurement record and candidate laboratory. This RFC
  records the accepted production selection and lifecycle.
