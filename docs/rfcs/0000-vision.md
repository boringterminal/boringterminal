# RFC 0000: Vision and product principles

Status: accepted

## One sentence

A macOS-only, Metal-only terminal that is a **session switchboard for agents** —
and refuses to be anything else.

Not an orchestrator with a terminal inside. A terminal whose one opinion is
that you run many long-lived sessions — coding agents, builds, shells — and
need to know which one wants you, instantly, without the terminal ever getting
in the way.

## Name (amended 2026-08-16)

The product is **Boring Terminal** and its canonical site is
`boringterminal.com`. Machine-facing identifiers use `boringterminal`
(executable, `TERM_PROGRAM`, application-support directory) and the future
daemon is `boringterminald`. “newterm” was the development codename and is not
part of the shipped product surface.

The canonical source repository is
`https://github.com/boringterminal/boringterminal`.

## The one-line test

Every proposed feature must pass:

> Does it help someone run ten agents and know which one needs them?

If no: it doesn't go in. This test is the product.

## Principles

1. **Mac-only, Metal-only, forever.** No portability layer, no abstraction over
   a second platform that will never exist. This is a feature: every line can
   assume AppKit, CoreText, Metal, kqueue.
2. **Agents talk through standards, not integrations.** The entire "agent
   support" surface is escape sequences that already exist: OSC 0/2 (title),
   OSC 9/777 + BEL (notification/attention), OSC 133 (semantic prompts →
   idle/working/waiting-for-input for free), OSC 8 (hyperlinks), OSC 52
   (clipboard). Implement them impeccably; never ship a per-agent adapter or an
   "agent SDK". Nothing has to fight this terminal because there is nothing to
   fight.
3. **Opinions, not configuration.** One config file, hot-reloaded, short. Where
   a choice exists, we make it once: the session sidebar is vertical and can
   be hidden, but there is no horizontal tab mode. RFC 0014's bounded
   two-session side-by-side pair is the only split exception; it is a
   switchboard item, not a configurable pane system.
4. **Remove before adding.** Speed and sleekness come from absence.
5. **Determinism.** A frame is a pure function of terminal state. The VT core
   is a pure function of its input bytes. Same bytes, same state, same pixels.

## What we build

- **Own VT emulator** (see RFC 0002). Decision recorded: we do *not* depend on
  `alacritty_terminal`, `libghostty-vt`, or gpui. Rationale: gpui is a
  cross-platform framework moving at Zed's pace; alacritty_terminal drags a
  cross-platform crate; both discard our existing Zig/Metal/CoreText renderer.
  Reference implementations are documentation, not dependencies
  (docs/references/prior-art.md).
- **Own renderer** using Metal pipelines, CoreText rasterization, glyph
  atlases, and hand-written objc bindings (see RFC 0004).
- **Vertical session sidebar** with attention states (RFC 0006).
- **Session daemon**: PTYs survive the window. An agent 40 minutes into a task
  must not die because a window closed (RFC 0006).
- **Control socket + `term` CLI**: a small automation and inspection surface
  for sessions (RFC 0007). It is not the product's plugin mechanism; that
  mechanism remains deliberately unspecified until its requirements are
  designed.
- **Scrollback with search and resize reflow.** Agents produce oceans of
  output; search is how you use them. Non-negotiable (RFC 0003 storage,
  RFC 0016 interaction and daemon search).
- **Real mac-native input**: NSTextInputClient IME, dead keys, emoji, secure
  input, drag-and-drop paths (RFC 0005). This — not rendering — is what makes
  a terminal feel native.
- **Fidelity against real agent workflows**: Codex is the cell/TUI benchmark;
  terminal-browser is the inline-graphics benchmark. Protocol and renderer
  gaps found by those fixtures gate automation work (RFC 0013).

## What we deliberately do not build

- Profiles, settings UI, themes gallery (one config file)
- Horizontal tabs and general splits/panes. The sidebar remains the layout;
  RFC 0014 permits only one non-nesting, two-session side-by-side pair.
- tmux integration or control mode
- Ligatures (no text shaping at all → simpler and faster; CoreText is used
  for rasterization and font fallback only)
- Sixel, iTerm2 images, and a general media layer. Kitty graphics is the one
  exception because it is an open terminal protocol used by agent workflows;
  full protocol compliance is the target, delivered in phases (RFC 0013).
- Broadcast input, triggers, per-agent UI, AI features of any kind
- In-process plugins (they are how terminals get slow and crashy)

## Non-goals as identity

We will not out-benchmark Alacritty/Ghostty and don't need to: every serious
terminal is already fast enough that speed is table stakes. We compete on the
workflow. Built for the author first, open-sourced so anyone can use it.

## Milestones

1. **Glass teletype** — PTY → parser → grid → renderer in a real window;
   zsh echoes. *Shipped* (RFC 0008).
2a. **Conformance oracle** — DECRQCRA plus a working esctest harness
   (smoke run, not yet the formal ratchet). Pulled ahead of everything
   else so the storage rewrite in milestone 3 happens under an external
   oracle, not just our own tests. *Shipped.*
3. **Scrollback storage + reflow + viewport** (RFC 0003) — the grid's
   final storage model. *Shipped* (storage/reflow/viewport; the formal
   ratchet file and search remain open). esctest before/after the swap:
   99→100 passed, only reasoned exclusions failing.
2b. **Input/protocol completions** — kitty keyboard protocol, mouse
   reporting, DECRQM, marked-text (IME) rendering, focus reporting.
   Independent of storage; deliberately after it so the migration surface
   stays small.
2c. **Terminal fidelity** — capability replies, font/Unicode correctness,
   renderer goldens, and phased full Kitty graphics compliance.
   Codex and terminal-browser are named early acceptance fixtures (RFC 0013).
4. **The product** — sidebar, OSC 8/9/133 attention states, session daemon.
5. **Control socket + CLI.**

Milestones 1–3, 2b, and 2c are the credibility work; 4–5 are the
differentiators and are comparatively cheap. Fidelity regressions take
priority over milestone 5: automation around a terminal that renders an
agent incorrectly compounds the wrong foundation.

**Reordering note (2026-08, was 2 → 3):** ratchets are most valuable on
stable foundations. Establishing the conformance ratchet before replacing
the grid's storage would ratchet hundreds of passes against a foundation
known to be rewritten, then churn them. Instead the oracle (2a) is borrowed
early — cheap, and it externally checks the migration — while the ratchet
waits for the storage it will guard. The rest of old milestone 2 (2b) has
no dependency on storage in either direction; its only cost is that TUIs
wanting those protocols degrade gracefully a while longer.
