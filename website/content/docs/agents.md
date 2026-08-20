---
title: Agents & attention
description: How sessions ask for you, and the escape sequences Boring Terminal listens to.
---

There is no agent SDK, no plugin, and no per-agent integration. Boring
Terminal's entire agent surface is standard escape sequences that most agents
and shells already emit. If your tool works in other modern terminals, it
already works here.

## Attention states

Every session is in one of these states, driven only by its output:

| State | Set by | Shown as |
|---|---|---|
| needs you | `BEL`, an OSC 9 / OSC 777 notification, or a command finishing with a nonzero exit code | orange dot in the sidebar; counted on the Dock badge |
| working | OSC 133 `C` (command started, not yet finished) | tracked, deliberately not rendered |
| idle | prompt visible, or command finished successfully | nothing |
| exited | the shell process ended | an exited row |

Two deliberate details:

- The **focused** session never asks for attention; you are already looking
  at it. Focusing a session clears its dot.
- Boring Terminal never posts macOS notifications. Attention lives in the
  sidebar and the Dock badge, where it can't interrupt you or pile up in
  Notification Center. This is a product decision, not a missing feature.

## The sequences

Ring the bell, or send a notification the explicit way:

```sh
printf '\a'                                # BEL
printf '\033]9;build finished\033\\'       # OSC 9 (iTerm2-style)
printf '\033]777;notify;title;body\033\\'  # OSC 777
```

With **OSC 133 semantic prompts**, attention becomes automatic: a command that
exits nonzero marks the session, a successful one returns it to idle, and
Boring Terminal knows whether a session is working or waiting without the
agent doing anything. Most shell-integration scripts (and coding agents) emit
these already:

```sh
printf '\033]133;A\033\\'        # prompt starts
printf '\033]133;C\033\\'        # command starts → working
printf '\033]133;D;%d\033\\' $?  # command ends; nonzero → needs you
```

## Titles and working directory

- **OSC 0/2** set the session title shown in the sidebar.
- **OSC 7** reports the working directory. Shells that emit it get two things:
  the session's directory in its metadata, and <kbd>⌘T</kbd> opening new
  sessions in the same directory.

## Hyperlinks

**OSC 8** hyperlinks render as real links: hold <kbd>⌘</kbd> to highlight,
<kbd>⌘</kbd>-click to open. `http`, `https`, `ftp`, `mailto`, and local `file`
links open directly; other schemes prompt first; malformed URIs are rejected.

## Identifying the terminal

Sessions run your login shell with:

```
TERM=xterm-256color
COLORTERM=truecolor
TERM_PROGRAM=boringterminal
TERM_PROGRAM_VERSION=<version>
```

For the full protocol surface (Kitty keyboard and graphics, mouse modes,
queries), see [Compatibility](/docs/compatibility/).
