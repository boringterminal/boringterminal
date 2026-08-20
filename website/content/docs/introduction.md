---
title: Introduction
description: What Boring Terminal is, who it is for, and what it refuses to be.
---

Boring Terminal is a macOS terminal built around long-running sessions. It
keeps agents, shells, and builds together, and makes it easy to see which one
needs you.

That is the whole product. You run many long-lived sessions (coding agents,
builds, shells) and you need to know which one wants you, instantly, without
the terminal ever getting in the way.

## What that looks like

- **Sessions survive the window.** An agent forty minutes into a task does not
  die because you closed a window. Reopen the app and it is where you left it.
- **A vertical session sidebar** shows every open session. Sessions that need
  attention are marked there.
- **Agents talk through standards, not integrations.** Attention, titles,
  progress, and links all arrive through escape sequences that already exist:
  OSC titles, notifications, semantic prompts, hyperlinks. Nothing has to
  integrate with Boring Terminal, so everything already works with it.
- **Mac-native everywhere it matters:** real IME input, dead keys, emoji,
  secure input, drag-and-drop paths. GPU-rendered with Metal.

## What it deliberately is not

There are no horizontal tabs, no general pane splitting, no tmux control mode,
no plugins, no settings UI, no AI features. One config file, opinions instead
of options. The reasoning is on the [philosophy](/docs/philosophy/) page.

## Where to go next

- [Install](/docs/install/) it, then read [Sessions](/docs/sessions/) to learn
  the core workflow.
- Running agents? [Agents & attention](/docs/agents/) explains how sessions
  ask for you.
- Wondering whether your favorite TUI will work?
  See [Compatibility](/docs/compatibility/).
