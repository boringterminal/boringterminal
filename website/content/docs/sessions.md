---
title: Sessions
description: Persistent sessions, the sidebar, side-by-side pairs, and search.
---

A session is a long-lived shell: an agent, a build, a plain prompt. Sessions
are the unit everything else is built around.

## Sessions survive the window

Sessions run in a background service (`boringterminald`) that owns the shell
process, the terminal state, and the scrollback. Quitting the app, or the app
crashing, leaves every session running. Relaunch and everything reattaches:
output, titles, attention state, even your side-by-side layout and its zoom.

The service starts automatically the first time you open the app. Two limits
to know:

- Sessions do not survive **logout, reboot, or killing the service itself**.
- When you close a session (<kbd>⌘W</kbd>) while a command is still running in
  the foreground, the app asks for confirmation first.

## The sidebar

Every open session lives in a vertical sidebar. Toggle it with <kbd>⌘B</kbd>;
when hidden, the title-bar toggle shows a badge if any session needs you.

- <kbd>⌘T</kbd> opens a new session. It inherits the working directory of the
  current one when the shell reports it (see [Agents & attention](/docs/agents/)).
- <kbd>⌘1</kbd>–<kbd>⌘9</kbd> jump to a session by position; hold <kbd>⌘</kbd>
  to see the number badges.
- <kbd>⌘⇧[</kbd> / <kbd>⌘⇧]</kbd> step to the previous / next session.
- <kbd>⇧⌥⌘↑</kbd> / <kbd>⇧⌥⌘↓</kbd> reorder rows.

Sessions that need attention get an orange dot in the sidebar, and the Dock
icon badge counts them.

## Pairs: the one split

Two related sessions can share the window side by side. For example, an agent
and the dev server it keeps restarting. This is the only split: exactly two
sessions, one level, side by side. A pair occupies a single sidebar row and
moves as one item.

Create a pair:

- <kbd>⌘D</kbd> opens a new session beside the current one.
- Drag one sidebar row onto the **left or right half** of another.
- **Session › Pair With Previous / Next Session.**

Work with it:

- <kbd>⌥⌘←</kbd> / <kbd>⌥⌘→</kbd> focus a side; <kbd>⇧⌥⌘←</kbd> /
  <kbd>⇧⌥⌘→</kbd> move a member across the divider.
- <kbd>⇧⌘↩</kbd> zooms the focused side to full width; press again to
  restore both.
- The divider is draggable, and the ratio persists.
- **Separate Sessions** (Session menu or the row's context menu) turns the
  pair back into two ordinary rows; both sessions keep running.
- <kbd>⌘W</kbd> closes only the focused member; the survivor becomes a
  single row.

## Scrollback and search

Each session keeps 10,000 lines of scrollback. <kbd>⌘F</kbd> opens search in
the focused session; <kbd>⌘G</kbd> / <kbd>⇧⌘G</kbd> step through matches.
Select text and <kbd>⌘C</kbd> copies it; <kbd>⌘K</kbd> clears to the start.
