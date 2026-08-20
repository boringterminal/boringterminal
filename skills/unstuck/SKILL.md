---
name: unstuck
description: Use when stuck on Boring Terminal work — an ambiguous behavior question, a subsystem you don't know how to approach (rendering, fonts, IME, PTY, scrollback, daemon), a bug you can't localize, or uncertainty about whether a feature belongs in the project at all. Maps every subsystem to its prior art, oracle, and doc.
---

# Getting unstuck

Three moves, in order: (1) is it a *scope* question — check the vision;
(2) is it a *behavior* question — find the oracle; (3) is it a *how do I
build this* question — read the named prior art for that subsystem.

## 1. Scope: does this belong in Boring Terminal?

`docs/rfcs/0000-vision.md` — apply the one-line test: *does it help someone
run ten agents and know which one needs them?* The cut list there is
binding. If genuinely new territory, it needs a new RFC in `docs/rfcs/`, not
ad-hoc code. Rejected alternatives are recorded in RFC 0000/0001 — don't
re-propose gpui, alacritty_terminal, in-process plugins, splits, or image
protocols without new information.

## 2. Behavior: what is correct here?

Follow the lookup ritual in `docs/references/prior-art.md` (ctlseqs →
terminalguide → Ghostty tests → Alacritty blame → empirical). Escape-sequence
work: load the **vt-impl** skill. Test failures: load the **conformance**
skill. Never resolve behavior by intuition.

## 3. Subsystem map: who solved this before

Reference checkouts live in `~/Projects/reference/` (clone commands in
prior-art.md). Paths are landmarks — verify with grep, files move.
**License gate: Ghostty/Alacritty/WezTerm/xterm logic may be ported with
attribution; kitty is GPL — read-only, reimplement from its specs.**

| Stuck on | Read first | Prior art |
|----------|-----------|-----------|
| Parser states, cancellation, params | references/vt-parser-state-machine.md | vte crate; ghostty `src/terminal/Parser.zig` |
| A sequence's semantics / edge case | references/escape-sequences.md | ghostty `Terminal.zig` tests; terminalguide |
| Wrap/margins/origin weirdness | conformance doc §pending-wrap | ghostty tests; xterm empirically; vttest menus 1–2 |
| Width, emoji, VS16, graphemes | references/unicode-width.md (policy is fixed) | ghostty `src/unicode/`; zg library |
| Scrollback storage, pins, eviction | rfcs/0003 | ghostty `PageList.zig`, `page.zig` |
| Reflow algorithm | rfcs/0003 | alacritty `grid/resize.rs` (most readable anywhere) |
| Metal pipeline, atlas, glyph draw | rfcs/0004 | our `src/render/`; ghostty `src/renderer/` |
| CoreText fallback, font discovery | rfcs/0004 | our `src/render/font.zig`; ghostty `src/font/` |
| IME, dead keys, marked text | references/macos-ime.md (incl. gotchas + test checklist) | ghostty `macos/Sources/Ghostty/` NSView surface |
| Key encoding (legacy + kitty proto) | references/escape-sequences.md §keyboard | kitty protocol spec (doc, not source); ghostty `input/` |
| PTY, resize, paste deadlock, reaping | references/pty.md | that doc is self-sufficient; ghostty `src/os/` second |
| Daemon/attach design | rfcs/0006 | tmux concepts only at design level (don't mimic internals) |
| Control socket verbs | rfcs/0007 | kitty remote-control docs; `wezterm cli` |

## 4. Still stuck: localize empirically

- Screen looks wrong → capture bytes, minimize, `tools/vtdiff`, replay in
  Ghostty (recipes: references/conformance-testing.md). Verdict decides:
  our bug / app's bug / correct-but-surprising.
- Render vs. state confusion → dump the grid snapshot as text (vtdiff). If
  the text is right and pixels are wrong, it's `render/`; else it's `vt`.
  The purity boundary (rfcs/0001) exists precisely so you can make this cut.
- Input bugs → determine the lane first (text lane vs control lane,
  rfcs/0005): log what reaches insertText vs doCommandBySelector before
  touching encoding code.
- Heisenbug → it can't be one in `vt`: it's pure, so any bug reproduces
  from its byte stream. Get the bytes; if you can't reproduce from bytes
  alone, the bug is in the shell/PTY layer by elimination.

## 5. Write down what unstuck you

If the answer wasn't already in `docs/references/`, add it there (new
section or new file + link from CLAUDE.md). The next agent starts where you
finished, not where you started.
