# RFC 0015: Shared graphics transport across the daemon boundary

Status: accepted

## Decision

Boring Terminal keeps RFC 0012's process boundary: `boringterminald` owns
PTYs, VT state, scrollback, and decoded Kitty resources, while the AppKit
process remains a replaceable viewer. Sustained graphics must not weaken that
session-survival guarantee merely to recover single-process rendering speed.

The existing version-10 attach protocol therefore gains an optional **local
shared-memory staging transport** for newly fetched image generations. The
viewer negotiates it on a disposable bulk connection: a daemon that does not
recognize the extension closes only that connection, after which the viewer
reattaches an ordinary version-10 bulk connection and latches byte transport
for that attachment. Existing sessions never require a daemon restart merely
to gain an optional graphics optimization.

On a negotiated connection, the daemon copies an
authoritative RGBA resource into one of three bounded staging slots, passes a
file descriptor for each slot over the existing Unix-domain socket with
`SCM_RIGHTS`, and sends only identity and geometry metadata for subsequent
uses of that slot. The viewer maps the slot, wraps it in a no-copy Metal buffer,
and GPU-copies it into the existing immutable texture cache. It releases the
slot only after that copy completes.

The ordinary version-10 byte-response image fetch remains the correctness fallback.
Snapshots, terminal cells, input, attention, and every Kitty command continue
to use RFC 0012's existing protocol and authority model.

## Why this exists

The phase-2a Kitty transport already removes the child-to-daemon pixel stream
for a local client: terminal-browser selects Kitty's POSIX shared-memory medium,
and the daemon maps and validates those bytes. That improvement does not cover
the independent daemon-to-viewer boundary.

A 2026-08-18 sustained 720p terminal-browser profile isolated that second
boundary after the renderer pipeline itself was corrected:

- AppKit performs no daemon request or full-frame upload while presenting;
- display-link coalescing and the three-slot Metal frame ring remain responsive;
- GPU completion is normally around one millisecond and frame slots do not
  starve;
- each 120-generation batch nevertheless spends about 2.4 seconds in viewer
  refresh, approximately 20 ms per generation;
- one representative generation is about 5.7 MiB, so the batch moves roughly
  684 MiB of pixels at about 285 MiB/s before counting repeated userspace and
  kernel copies;
- under sustained system pressure the refresh worker has reached about 57 ms
  per generation, limiting visible presentation to roughly 17 fps even while
  the UI and GPU remain healthy.

The current byte fetch allocates a daemon response, copies it through the
socket, allocates the viewer frame payload, and then duplicates the RGBA slice
during decode before preparing a Metal texture. Caching is correct for static
generations, but video intentionally produces a new generation for every
frame, so that repeated transfer is the steady state rather than a cache miss
outlier.

This is a transport defect, not a reason to remove the daemon. The product's
one-line test requires long-running agent sessions to survive closing or
crashing the GUI. The correct optimization is to make the process boundary
carry capabilities and metadata instead of serializing millions of pixels.

## Goals

- No full RGBA payload crosses the attach socket on the normal local path.
- No viewer heap allocation or CPU RGBA copy is required for a shared
  generation.
- PTY readers and the interactive input connection never wait for a staging
  slot, GPU completion, or bulk copy.
- The daemon remains authoritative for image identity, bytes, placement,
  deletion, animation state, quotas, and Kitty acknowledgements.
- Every published viewer texture is immutable and coherent with one exact
  `(session id, image id, generation)`.
- Transport memory and outstanding leases are bounded and recover after either
  process disconnects or crashes.
- Updating the viewer never requires terminating sessions held by an older
  daemon merely because that daemon lacks shared graphics.
- Byte transport remains available when shared-memory or Metal setup fails.
- Ten sessions without changing graphics allocate no staging memory and no GPU
  resources merely because they exist.

## Non-goals

- Sharing the VT, grid, scrollback, or allocator-owned object graphs between
  processes.
- A public, remote, cross-platform, or RFC 0007 control protocol.
- Moving VT parsing into the viewer or Metal rendering into the daemon.
- Changing Kitty graphics semantics or adding an application-specific video
  path.
- Eliminating the one host-owned copy required to retain child-provided data
  after the Kitty client relinquishes its file or shared-memory object.
- Guaranteeing that every intermediate generation is presented. Protocol state
  is never skipped; display-link presentation may continue to coalesce obsolete
  complete generations as RFC 0004 already permits.

## Prior art and the boundary we are keeping

WezTerm is the closest architectural precedent. Its multiplexer manages
running programs independently of a GUI, and its documented daemon options
place that mux server in the background. iTerm2's tmux control-mode integration
uses the same ownership split through a separate project: tmux retains the
sessions when iTerm2 quits, and a later client reconstructs native windows.
These precedents establish that a replaceable terminal viewer is a legitimate
architecture, not an accidental complication.

Ghostty and Kitty optimize a different boundary. Ghostty documents dedicated
read, write, and render threads per terminal, and Kitty separates interaction
with child programs from rendering, but terminal state and rendering remain in
one address space. They do not need to transport decoded image resources to a
replaceable local viewer. Their threaded scheduling remains relevant to RFC
0004, but adding another thread in Boring Terminal would only move the existing
copy rather than remove it.

Kitty's published graphics protocol explicitly provides POSIX shared memory
for local pixel transfer and reserves direct escape-code payloads for clients
that cannot share a filesystem or memory object. Boring Terminal already
implements that standard at the child-to-daemon edge. This RFC applies the
same design principle, not the public Kitty wire format, to its private local
edge.

tmux demonstrates the right backpressure policy, but not a graphics transport
we can copy. Its server owns PTYs and terminal state, then redraws an attached
client by emitting ordinary terminal escape sequences. That is compact for
text, and control-mode clients can pause when behind and resynchronize from an
authoritative capture. Kitty graphics support remains open work in tmux as of
this decision: passthrough gives the outer terminal image state that tmux
cannot reliably reconstruct across scrolling, pane changes, multiple clients,
or reattach. Boring Terminal adopts the bounded pause/coalesce/resynchronize
lesson, not passthrough ownership.

cmux avoids the local boundary rather than solving it. Its local Ghostty
surface owns the PTY, terminal state, decoded images, and Metal renderer inside
the GUI process. Its documented restore rebuilds layouts and may resume
supported agents, but does not preserve arbitrary live local processes. Its
remote persistent-daemon work does not yet define decoded Kitty graphics
transport. Boring Terminal deliberately promises both arbitrary PTY survival
and authoritative Kitty state, so it must transport image resources without
pretending either precedent already does so.

Primary references, retrieved 2026-08-18:

- WezTerm mux module and daemon configuration:
  https://wezterm.org/config/lua/wezterm.mux/index.html and
  https://wezterm.org/config/lua/config/daemon_options.html
- iTerm2 tmux integration:
  https://iterm2.com/documentation-tmux-integration.html
- Ghostty architecture:
  https://github.com/ghostty-org/ghostty/blob/main/README.md
- Kitty performance and graphics transport:
  https://sw.kovidgoyal.net/kitty/performance/ and
  https://sw.kovidgoyal.net/kitty/graphics-protocol/#the-transmission-medium
- tmux server/client model, control-mode flow control, and current Kitty work:
  https://github.com/tmux/tmux/wiki/Getting-Started,
  https://github.com/tmux/tmux/wiki/Control-Mode, and
  https://github.com/tmux/tmux/issues/4902
- cmux architecture and restore contract:
  https://github.com/manaflow-ai/cmux and
  https://github.com/manaflow-ai/cmux/blob/main/docs/remote-daemon-spec.md

## Why shared memory first, not IOSurface first

IOSurface is designed to share image storage across processes, and Metal can
create a texture whose backing store is an IOSurface. It is a plausible final
fast path. Secure IOSurface transfer, however, uses a Mach port or XPC object.
Apple explicitly recommends `IOSurfaceCreateMachPort` when a surface must pass
atomically or securely without becoming globally discoverable. A plain
Unix-domain socket can transfer file descriptors with `SCM_RIGHTS`, but it
cannot transfer a Mach send right. Using deprecated globally visible
IOSurface IDs would widen access to the whole system and is rejected.

Adding XPC or a registered Mach service solely for pixels would create a second
discovery, authentication, framing, and lifecycle mechanism beside the already
working private Unix socket. It is not justified before measuring the simpler
path.

The simpler path is still Metal-native:

1. `mmap(MAP_SHARED)` supplies one shared, page-aligned VM region per slot.
2. `newBufferWithBytesNoCopy:length:options:deallocator:` wraps that existing
   allocation without another storage allocation.
3. `MTLBlitCommandEncoder` copies the aligned rows directly from that buffer
   into the viewer's ordinary immutable texture before the slot is
   reused.

The initial path deliberately does not manufacture a linear source texture.
That object is unnecessary for a buffer-to-texture blit, adds another Metal
resource lifetime, and risks the layout restrictions Apple documents for
buffer-backed textures. RFC 0022 profiles direct sampling and fused
materialization for transient generations. RFC 0023 selects fused upload/draw
for production: the blit and first sampling draw share one frame command
buffer, and the exact staging lease is released only from GPU completion.
Direct linear sampling remains outside production until its portability and
application-soak gates justify it.

Apple references, retrieved 2026-08-18:

- Unix-domain descriptor passing with `SCM_RIGHTS`:
  https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/recvmsg.2.html
- Metal no-copy buffers:
  https://developer.apple.com/documentation/metal/mtldevice/makebuffer%28bytesnocopy%3Alength%3Aoptions%3Adeallocator%3A%29
- Metal buffer-backed textures and their alignment/performance constraints:
  https://developer.apple.com/documentation/metal/mtlbuffer/maketexture%28descriptor%3Aoffset%3Abytesperrow%3A%29
- Metal IOSurface-backed textures:
  https://developer.apple.com/documentation/metal/mtldevice/maketexture%28descriptor%3Aiosurface%3Aplane%3A%29
- Secure IOSurface Mach-port transfer:
  https://developer.apple.com/documentation/iosurface/iosurfacecreatemachport%28_%3A%29

## Transport model

### Connection and framing

The existing refresh/bulk command connection owns the staging ring. It remains
independent of the interactive connection, so keys, paste, focus, mouse, and
resize never queue behind graphics work. The viewer first opens that connection
and sends one version-10 `graphics_attach` command. A supporting daemon replies
`graphics_ready` and thereafter accepts the ordinary bulk commands plus staged
image commands on that connection. An older daemon treats the unknown tag
exactly as version 10 already specifies and closes the sacrificial connection;
the viewer immediately opens a normal version-10 bulk connection and does not
retry the extension until its next complete attachment.

The negotiated connection adds two commands to the existing bulk surface:

```text
stage_image(session_id, image_id, generation, row_alignment)
  -> staged_image(slot_index, lease_token,
                  image identity, width, height, bytes_per_row, byte_length,
                  optional slot fd)

release_staged_image(slot_index, lease_token)
  -> ok

fetch_image_bytes(session_id, image_id, generation)
  -> existing validated descriptor + RGBA bytes
```

The existing image fetch becomes the explicitly named fallback rather than
silently sharing a response tag with a descriptor-bearing result.

### Stale-generation response amendment (2026-08-20)

Every `stage_image` request receives the descriptor envelope before its
versioned response frame, including `graphics_busy` and `protocol_error`
responses that carry no descriptor. The envelope is part of the staged-image
reply framing, not merely a prefix for successful descriptor transfer.

A generation may become stale between the snapshot and its staged fetch while
a client is replacing a video image. That race is ordinary resource churn, not
a transport failure. The viewer consumes the empty envelope and protocol-error
frame, abandons that refresh, and obtains a newer authoritative snapshot. It
does not retry the stale generation through byte transport and does not disable
shared graphics. Only malformed descriptor ancillary data, broken framing, or
an unusable mapping disables the negotiated staging connection under the
existing fallback rule.

The real-daemon regression must force a stale staged fetch, observe the empty
envelope and protocol error, then fetch a valid generation over the same
connection. This keeps a high-frame-rate client from turning a harmless
snapshot race into a permanent multi-megabyte socket-copy path.

File descriptors travel as `SCM_RIGHTS` ancillary data on the same AF_UNIX
stream. A staged-image response begins with one fixed envelope byte read by
`recvmsg`, optionally carrying exactly one descriptor, followed by an ordinary
versioned attach-protocol frame. This prevents a normal `read` from consuming
the byte associated with ancillary data. The bulk connection is serialized, so
the receiver always knows whether it is awaiting this envelope. Missing,
extra, truncated, or unexpected ancillary data closes only the bulk connection
and falls back after reconnect; it never reaches VT state.

The daemon sends a descriptor only when a slot is first created or replaced by
a larger allocation. Later leases name the already mapped slot and carry no
descriptor. The connection lifetime is the pool identity. Each successful
lease receives a monotonically unique, nonzero `lease_token`; a stale GPU
completion therefore cannot release a newer use of the same slot. Slot
replacement is permitted only while free, and its descriptor-bearing response
replaces the viewer's old mapping before the new lease is published. Pending
release work is discarded rather than replayed onto a reconnected bulk lane.

### Slot allocation and quotas

One negotiated bulk connection owns exactly three staging slots, matching the
live Metal frame ring without multiplying slots by session count. Slots are absent until
the first shared fetch. Each slot is an independent POSIX shared-memory object:

1. create with a cryptographically unpredictable name, `O_CREAT | O_EXCL`, and
   mode `0600`;
2. size it to a page-aligned capacity;
3. map it in the daemon;
4. immediately `shm_unlink` the name;
5. pass the still-open descriptor to the viewer.

The name is never accepted from a child and is not sent to the viewer. The
object exists only through the two processes' descriptors and mappings.

A slot grows only while free. Its capacity is the page-rounded next power of
two that can contain the aligned image rows, capped by RFC 0013's 64 MiB
single-image ceiling. The aggregate capacity of every live staging slot in the
daemon is capped at 128 MiB, not multiplied per connection or viewer. A slot
reserves capacity from that one daemon-global budget before allocation and
returns it on pool destruction. If growth would exceed the budget, or
allocation or descriptor passing fails, that attachment latches byte transport
after closing the graphics connection. Slots do not shrink during an
attachment; disconnect releases the entire pool. Typical 720p frames therefore
commit only the small capacities they use, while repeated or buggy clients
cannot multiply persistent shared allocations without bound. A later measured
4K workload may amend the fixed budget; it is not user configuration.

### Daemon publication

Each slot is daemon-owned and has one of four states:

```text
empty -> free -> writing -> leased -> free
```

The daemon first validates the requested identity against authoritative state.
Image resources become address-stable, reference-counted host objects: the
session lock retains the exact generation and claims a free slot, then releases
the lock before copying rows. No PTY reader, registry lock, or interactive
connection waits for the multi-megabyte copy.

The daemon writes tightly validated straight-alpha RGBA8 into rows aligned to
the Metal minimum supplied by the viewer. That alignment must be a nonzero
power of two no larger than the system VM page size; otherwise the shared path
is refused. Every active `width * 4` row byte is overwritten before
publication. Row padding and unused capacity are outside the declared texture
extent and are never sampled; they are not cleared on reuse because the same
trusted viewer can already fetch every resource and clearing them would add
bandwidth to the hot path. Only after the complete copy does the daemon publish
a fresh monotonically increasing `lease_token` in the response. Socket
ordering is the publication boundary; the viewer cannot observe a writing slot
through the protocol.

If all slots are leased, `stage_image` returns a recoverable `graphics_busy`
result immediately. The viewer keeps its last coherent frame and retries from
the newest snapshot after a release. The daemon continues parsing every Kitty
command and may evict an obsolete generation under its existing resource
rules. A retry for such a generation follows RFC 0012's normal stale-resource
path and starts again from a newer authoritative snapshot.

### Viewer materialization and release

On receiving a new descriptor, the viewer validates its size with `fstat`, maps
exactly that size, closes the received descriptor after mapping, and records
the connection-local slot. It requests no executable mapping and rejects
unbounded lengths, mismatched capacities, dimensions, strides, and leases. A
read-only CPU mapping is preferred when compatible with the Metal no-copy
buffer API; requiring a second named/reopened descriptor merely to enforce it
is rejected because the viewer and daemon already mutually trust each other.

The mapping base and length are page aligned. The viewer wraps the mapping in
a `MTLBuffer` with shared storage and pairs it with the same ordinary immutable
texture type used by the existing image cache. RFC 0023 owns the materialization
lifetime: the refresh worker publishes that unsubmitted pair as one
`StagedUpload`; the first displaying frame encodes its aligned blit before the
ordinary draw in the frame's existing command buffer. No steady-state CPU path
waits for that upload.

After Metal completion RFC 0023's dedicated release worker sends
`release_staged_image`. The daemon
accepts the release only when the slot and lease token match the current lease;
duplicate and stale releases are harmless protocol errors and never free a
newer lease. The viewer destroys the no-copy buffer before unmapping or
replacing a slot. The ordinary cached texture and in-flight render-frame retains
remain governed by RFC 0004 and no longer depend on staging memory.

Releases share the bulk connection. They may wait behind another small staged
metadata response, but never behind pixel payloads on the normal path and never
behind interactive input. At most three leases can be outstanding, so the
release queue is structurally bounded.

## Failure and crash behavior

- **Viewer exits or crashes:** closing the pool-owning bulk connection revokes
  every lease, unmaps and closes daemon slots, and leaves PTYs/resources alive.
- **Bulk connection fails while the GUI remains:** the viewer stops using its
  mappings for new work, closes the failed connection, opens an ordinary
  version-10 bulk connection, and latches byte transport for that attachment.
  Existing mappings are unmapped only after every already-started GPU
  materialization drains; one worker's failure can never revoke memory another
  worker is reading. It does not reuse a lease whose release outcome is unknown
  or oscillate between fast and fallback paths frame by frame.
- **Daemon exits or crashes:** the GUI already enters RFC 0012's disconnected
  state; it releases Metal wrappers and mappings. Unlinked shared-memory objects
  disappear when the last references close.
- **GPU materialization fails:** the viewer releases the lease, preserves the
  previous coherent frame, closes the graphics lane, and latches byte transport
  before waiting for a newer invalidation.
- **No free slot:** recoverable `graphics_busy`; never wait in a PTY reader and
  never allocate an overflow queue and never send that obsolete generation
  through the byte fallback. The viewer preserves its last coherent texture
  and retries only the newest generation after a release.
- **Protocol or descriptor mismatch:** close the bulk connection, discard all
  unpublished resources, and retain the last coherent frame.
- **Memory pressure:** transport allocation failure selects byte fallback.
  Existing daemon resource and renderer-cache eviction remain authoritative;
  staging is never an additional image store.

## Security properties

The PTY child and its escape-sequence fields are untrusted. The bundled viewer
and daemon mutually trust each other; malicious software already executing as
the same user is outside this local protocol's boundary because it can already
connect to version 10, inspect sessions and image bytes, and submit input.
Other users remain excluded by the mode-`0700` support directory and
mode-`0600` socket/object permissions. The new security obligation is therefore
bounded resource use and memory-safe handling of child-influenced geometry,
not authenticating two components of the same application against each other.

- Shared objects are daemon-created, mode `0600`, randomly named, and unlinked
  before publication. There is no globally discoverable IOSurface id or stable
  filesystem path.
- Only a client already accepted on RFC 0012's user-private socket can receive
  a descriptor. The descriptor is data-only, mapped non-executable, and bounded
  before Metal sees it.
- Child-provided Kitty `t=s` names never select or alias viewer staging slots.
  The child-to-daemon and daemon-to-viewer transports have independent
  namespaces, ownership, and validation.
- Slot metadata is checked against the authoritative session/resource identity
  and against the actual mapped capacity. Integer overflow, stride mismatch,
  and stale generation fail before publication.
- Ancillary receipt accepts exactly one descriptor only when expected, rejects
  truncated or unexpected control messages, validates capacity with `fstat`,
  marks the received descriptor close-on-exec, and closes it on every failure
  path.
- Every graphics connection and slot draws from one daemon-global 128 MiB
  transport budget. Idle or repeated connections allocate no staging memory.
- A compromised viewer already has the authority to send input to its user's
  sessions; shared transport grants no cross-user or arbitrary-file capability.
- Unused slot capacity is not a separate confidentiality domain: it contains
  prior pixels visible to the same viewer, and validated texture geometry never
  samples it. Per-frame tail clearing and code-signature/token authentication
  are deliberately rejected as cost without protection in this trust model.

## Correctness and performance gates

Unit and real-daemon integration coverage must prove:

- descriptor transfer succeeds once and subsequent leases reuse the mapping;
- an old version-10 daemon rejects only the disposable graphics negotiation,
  while ordinary attach and byte graphics continue without terminating any
  session;
- unexpected/multiple ancillary descriptors and malformed slot metadata fail
  closed;
- a slot cannot be reused before its exact lease is released;
- stale lease tokens cannot free a replacement slot or newer lease;
- copying happens after an address-stable resource retain and outside the
  session lock;
- three leased slots produce `graphics_busy` without blocking PTY progress;
- `graphics_busy` coalesces to the newest generation and does not invoke byte
  transport for each skipped frame;
- multiple graphics connections cannot exceed the daemon-global transport
  budget;
- viewer, bulk-connection, and daemon crashes reclaim every slot;
- a free-slot grow/replacement installs its new mapping before publication and
  cannot be released by an older lease token;
- byte fallback renders identical pixels and adopts its received frame backing
  without a second RGBA allocation/copy;
- static generations still fetch/materialize once and reuse their ordinary
  cached texture;
- two visible paired sessions share the one viewer pool without resource-key
  aliasing.

The live acceptance workload is terminal-browser playing a 720p video for at
least 20 active minutes:

- terminal-browser selects Kitty shared memory without an override;
- the daemon parses every command and the viewer presents at least 95% of the
  source cadence after warm-up, excluding source/browser-reported stalls;
- shared-path image responses contain metadata only, not RGBA payloads;
- viewer refresh p99 remains below one source-frame interval and does not drift
  upward over the soak;
- AppKit main-thread frame preparation remains below one display interval with
  no beachball, input stall, or unavailable-frame-slot growth;
- viewer, daemon, and staging RSS remain bounded after repeated generation and
  slot replacement;
- killing and reopening the GUI during or after the run preserves the session
  and reestablishes the transport without stale pixels.

Temporary boundary counters may be reintroduced in Debug builds for these
gates, but must again be removed after the measurements; this RFC creates no
product telemetry surface.

## Rollout

1. **Byte-path ownership cleanup.** Let the fallback image resource adopt the
   received frame allocation as backing rather than duplicating its RGBA tail.
   Re-profile to preserve a clean baseline.
2. **Protocol and leases.** Add the disposable version-10 graphics negotiation,
   staged responses, `SCM_RIGHTS` framing, one global budget, bounded slots,
   resource retains, release validation, and
   real-daemon lifecycle tests while still copying staged bytes into an
   ordinary CPU allocation in the viewer test harness.
3. **Metal materialization.** Wrap each mapped slot with a no-copy `MTLBuffer`,
   GPU-copy its aligned rows directly to the existing texture cache, and
   release only after command completion on the off-main refresh worker.
4. **Default and soak.** Prefer shared staging for local GUI fetches, preserve
   byte fallback, run the acceptance soak, and remove temporary diagnostics.
5. **Only if still measured.** Compare direct sampling of transient linear
   textures with secure IOSurface transfer. IOSurface/XPC gets a new amendment
   only if the staging blit or linear layout remains a demonstrated bottleneck.

The optional extension does not change RFC 0012's base version. RFC 0012 records
the sacrificial-connection negotiation exception in the same commit: old
daemons close an unknown graphics-attach tag exactly as they already close any
unknown tag, and the new viewer never sends it on a connection containing
session input or other stateful work. RFC 0013's Kitty compliance matrix does
not change because this is below the terminal protocol surface.

## Rejected alternatives

- **Remove the daemon.** Breaks session survival, the product's defining
  requirement, to optimize one transport.
- **Keep the GUI process alive with no windows.** Window closure survives, but
  a GUI/AppKit crash still kills every session and keeps unnecessary UI/GPU
  state resident.
- **Add another render or decode thread.** The work is already off AppKit; a
  thread moves the copy without eliminating it.
- **Render inside the daemon and send final window surfaces.** Couples the
  persistent owner to fonts, Metal, drawable geometry, backing scale, viewer
  count, and window lifetime. Ten background agents would no longer be a
  lightweight state problem.
- **Share `Terminal` memory directly.** Rejected by RFC 0012: allocator-owned
  object graphs, locks, and scrollback are not a stable cross-process ABI.
- **Compress daemon-to-viewer frames.** Trades memory bandwidth for CPU and
  latency, repeats work already avoided by local shared memory, and performs
  poorly for video noise. Byte fallback may retain protocol-level bounds but
  is not the fast path.
- **Unbounded socket queues or staging slots.** Hide backpressure by turning a
  frame-rate problem into a memory leak.
- **Bump the entire attach protocol for the optional fast path.** A surviving
  version-10 daemon may own hours-long sessions when the GUI is upgraded.
  Requiring a daemon restart to gain faster graphics contradicts the reason the
  daemon exists; a sacrificial capability connection gives old daemons a clean
  byte fallback instead.
- **Authenticate the bundled viewer as a distinct principal.** Filesystem
  permissions already enforce the same-user boundary, while a malicious
  same-user process can use the existing protocol. Code-signature checks,
  tokens, and per-frame read-only descriptor reopening add machinery without
  changing that authority.
- **Clear all unused staging capacity on every lease.** Old bytes are visible
  only to the same viewer that could fetch them directly, are outside the
  sampled texture extent, and clearing them would consume the bandwidth this
  transport exists to recover.
- **Global IOSurface IDs.** Apple's secure alternative exists; globally
  discoverable surfaces are unnecessary and deprecated.
- **XPC/Mach IOSurface transport now.** Technically sound but duplicates IPC
  infrastructure before the existing socket plus descriptor passing has been
  measured.
- **Sample the linear staging texture forever.** Holds scarce slots for static
  images and accepts Metal's documented layout penalty. The initial design
  materializes the ordinary cache texture and releases staging promptly.

## Relationship to existing RFCs

- RFC 0001 keeps pure VT state and the daemon/viewer threading model.
- RFCs 0004 and 0023 keep display-link coalescing, immutable image textures,
  and the three-slot in-flight render ring; a queued staging upload is
  published atomically with its coherent snapshot and completed inside the
  first frame that displays it.
- RFC 0012 remains the authority for process ownership and records the optional
  version-10 graphics-capability connection when implementation lands.
- RFC 0013 remains the authority for Kitty parsing, resources, placements,
  quotas, and compliance. Shared staging is private transport only.
- RFC 0014's pair remains one viewer with at most two visible sessions and one
  shared staging pool.
