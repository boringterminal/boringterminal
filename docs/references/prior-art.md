# Prior art map — where to look when stuck

Reference implementations are documentation, not dependencies. Keep local
checkouts and read them like literature. File paths below are landmarks from
2026 — **verify with grep before trusting them**; repos move files.

```sh
mkdir -p ~/Projects/reference && cd ~/Projects/reference
git clone https://github.com/ghostty-org/ghostty
git clone https://github.com/alacritty/alacritty
git clone https://github.com/alacritty/vte
git clone https://github.com/kovidgoyal/kitty       # GPL — read-only! see below
git clone https://github.com/wez/wezterm
```

## ⚠️ Licensing rules for porting logic

| Project | License | May we port code? |
|---------|---------|-------------------|
| Ghostty | MIT | Yes, with attribution |
| Alacritty / vte | Apache-2.0 | Yes, with attribution + NOTICE |
| WezTerm | MIT | Yes, with attribution |
| xterm | MIT/X11-style | Yes, with attribution |
| **kitty** | **GPLv3** | **No. Read for understanding only; reimplement from behavior/spec, never from its source.** Kitty's *protocol docs* (keyboard, shell integration) are specs and fine to implement. |

## Who is best at what

### Ghostty (`~/Projects/reference/ghostty`) — Zig, closest idiom match
- `src/terminal/Parser.zig` — the state machine in Zig
- `src/terminal/stream.zig` — dispatch from parser actions to handlers
- `src/terminal/Terminal.zig` — semantics; its inline tests are an
  encyclopedia of edge cases (pending wrap, margins, wide-char interactions).
  When esctest fails us, grep here for the sequence name first.
- `src/terminal/PageList.zig`, `page.zig` — paged scrollback storage,
  pins/tracked references (RFC 0003's main prior art)
- `src/terminal/osc.zig`, `sgr.zig`, `modes.zig`, `csi.zig` — sequence lore
- `src/font/` — CoreText discovery, rasterization, atlas, fallback cascade
- `src/renderer/` — Metal cell renderer (instancing, damage, display link)
- `macos/Sources/Ghostty/` — Swift AppKit layer; the NSView surface here
  implements NSTextInputClient — best real-world IME reference for RFC 0005
- `src/os/` — macOS process/pty details
- Also: https://ghostty.org/docs — VT reference pages with per-sequence
  behavior notes.

### Alacritty (`~/Projects/reference/alacritty`) — battle-tested semantics
- `alacritty_terminal/src/term/mod.rs` — a decade of real-world fixes; git
  blame on a confusing line often links an issue explaining *why*
- `alacritty_terminal/src/grid/resize.rs` — the most readable reflow
  implementation anywhere; RFC 0003's reflow-algorithm reference
- `alacritty_terminal/src/grid/storage.rs` — ring-buffer alternative design
- Parser + ANSI definitions live in the separate `vte` crate (`vte/src/`,
  including `ansi.rs` sequence definitions)

### Live-resize scheduling landmarks

- Ghostty: `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`
  forwards backing-pixel size changes; `src/Surface.zig` queues the PTY resize
  to I/O; `src/renderer/Thread.zig` owns renderer resize and display cadence.
- Alacritty: `alacritty/src/event.rs` stores `Resized` as a pending display
  update and coalesces repeated dimensions; `alacritty/src/display/mod.rs`
  applies renderer resize immediately before drawing so an old back buffer is
  not presented at new geometry.

The Boring Terminal application analogue is RFC 0009: AppKit publishes the
latest desired size to the session worker, while the main thread keeps
presenting the last coherent snapshot clipped to the current drawable.

### Metal image-transport landmarks

- Apple: `MTLBuffer.newTextureWithDescriptor:offset:bytesPerRow:` exposes a
  linear texture view over buffer storage, subject to
  `minimumLinearTextureAlignmentForPixelFormat:`. Apple explicitly notes that
  buffer-backed textures may not receive ordinary texture-layout
  optimizations; measure copy removal against sampling cost.
- Ghostty: `src/renderer/Metal.zig` selects shared resources when
  `hasUnifiedMemory` is true and managed resources for a discrete GPU. Its
  image textures are shader-read resources in the renderer's address space;
  it does not solve Boring Terminal's replaceable-viewer lease boundary.
- Boring Terminal: RFC 0015 owns daemon-to-viewer shared staging. RFC 0022 is
  the measurement record for synchronous blit, fused blit/draw, and direct
  linear sampling. RFC 0023 specifies the production frame-pipelined ownership
  and release lifecycle. Do not infer an M1 result is a universal macOS policy.

### Metal frame-pipeline landmarks

- Apple, *Command Organization and Execution Model*: one command buffer may
  contain the encoders for a complete frame, and command buffers committed to
  one queue execute in order. This is the primary ordering basis for an upload
  blit followed by the image draw that first samples it.
- Apple, *Synchronizing CPU and GPU work*: cycle a bounded set of resource
  instances through frames in flight and return each instance from command-
  buffer completion rather than stalling CPU and GPU on each other. Its sample
  uses three instances, matching Boring Terminal's existing frame ring.
- Ghostty: `src/renderer/metal/Frame.zig` creates one command buffer per frame,
  uses an asynchronous completion callback normally, and waits only for an
  explicitly synchronous frame. This is scheduling prior art only; Ghostty has
  no replaceable-viewer staging lease.
- Boring Terminal: RFC 0023 extends RFC 0004's frame slot with the exact RFC
  0015 staging capability. Completion must retire the no-copy source before a
  bulk worker releases the slot; no Metal callback performs socket I/O.

### kitty (read-only) — protocol design
- Keyboard protocol spec: https://sw.kovidgoyal.net/kitty/keyboard-protocol/
- Shell integration design: https://sw.kovidgoyal.net/kitty/shell-integration/
- Remote control model (RFC 0007 prior art):
  https://sw.kovidgoyal.net/kitty/remote-control/

### WezTerm (`~/Projects/reference/wezterm`) — the escape encyclopedia
- `termwiz/src/escape/` — the most complete typed catalogue of escape
  sequences in existence; when you meet an unknown sequence, look it up here
- Its docs site has good "what do other terminals do" survey pages

### xterm — the behavioral gold standard
- ctlseqs: https://invisible-island.net/xterm/ctlseqs/ctlseqs.html — THE
  sequence reference; keep a local copy (`docs/references/ctlseqs.txt`,
  fetch when network available)
- When terminals disagree, xterm's behavior usually defines "correct"

### OSC 22 pointer-shape landmarks

- xterm `ctlseqs`: `OSC 22 ; Pt ST` changes the pointer shape; an empty or
  unknown name falls back to the `xterm` resource default.
- Ghostty (MIT), `src/terminal/mouse.zig`,
  `src/terminal/osc/parsers/mouse_shape.zig`, and
  `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`: accepts CSS
  cursor names plus xterm aliases, stores the shape as terminal state, and
  maps supported values to native AppKit cursors.
- Alacritty does not currently implement OSC 22; its pointing-hand cursor is
  tied to its separate hyperlink-hint surface, so it is not an OSC 22 oracle.

## Cross-terminal behavior comparison

- **https://terminalguide.namepad.de/** — per-sequence pages documenting what
  xterm/urxvt/konsole/etc. *actually do*, including quirks tables. The
  first stop for "the spec is ambiguous, what does the world expect?"
- vt100.net — scanned DEC manuals (VT100/VT220/VT510 programmer refs) for
  original semantics of DEC private modes.

## The lookup ritual (use in this order)

1. **ctlseqs** — what is this sequence, what does xterm do
2. **terminalguide** — do terminals disagree; which behavior do apps expect
3. **Ghostty source + tests** — how does a modern Zig implementation handle
   it, what edge cases did they encode
4. **Alacritty git blame** — why is there a weird special case (issue links)
5. **Empirical**: run the bytes in xterm/Ghostty and observe
   (docs/references/conformance-testing.md, vtdiff)

Never resolve a behavior question by intuition. The answer exists; find it.
