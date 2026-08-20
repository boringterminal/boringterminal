---
title: Philosophy
description: The one-line test, the principles behind it, and what we refuse to build.
---

## The one-line test

Every proposed feature must pass:

> Does it help someone run ten agents and know which one needs them?

If no, it doesn't go in. This test is the product.

## Principles

1. **Mac-only, Metal-only, forever.** No portability layer, no abstraction
   over a second platform that will never exist. This is a feature: every line
   of the app can assume AppKit, CoreText, Metal, and kqueue.
2. **Agents talk through standards, not integrations.** The entire "agent
   support" surface is escape sequences that already exist. They are
   implemented impeccably; there is no per-agent adapter and no "agent SDK".
   Nothing has to fight this terminal because there is nothing to fight.
3. **Opinions, not configuration.** One config file, hot-reloaded, short.
   Where a choice exists, it is made once. The sidebar is vertical and can be
   hidden; there is no horizontal tab mode.
4. **Remove before adding.** Speed and sleekness come from absence.
5. **Determinism.** A frame is a pure function of terminal state. The VT core
   is a pure function of its input bytes. Same bytes, same state, same pixels.

## What we deliberately do not build

- Profiles, settings UI, or a themes gallery: there is one config file
- Horizontal tabs and general splits. The sidebar is the layout; the only
  exception is a single, non-nesting, two-session side-by-side pair
- tmux integration or control mode
- Ligatures: no text shaping at all, which keeps rendering simpler and faster
- Sixel, iTerm2 images, or a general media layer. Kitty graphics is the one
  exception, because it is an open protocol used by real agent workflows
- Broadcast input, triggers, per-agent UI, AI features of any kind
- In-process plugins: they are how terminals get slow and crashy

## On speed

Boring Terminal does not try to out-benchmark Alacritty or Ghostty, and does
not need to: every serious terminal is already fast enough that speed is table
stakes. It competes on the workflow instead.

## Design records

Every non-trivial decision is written down before it is built. The RFCs live
in [`docs/rfcs`](https://github.com/boringterminal/boringterminal/tree/main/docs/rfcs)
in the repository, including the rejected alternatives and why.
