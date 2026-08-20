---
title: Configuration
description: One short config file, hot-reloaded. Currently two keys.
---

Boring Terminal has one configuration file:

```
~/Library/Application Support/boringterminal/config
```

Press <kbd>⌘,</kbd> (**Boring Terminal › Open Configuration**) to open it. If
it doesn't exist yet, the app writes a commented starter file first.

## Format

Plain `key = value` lines. `#` starts a comment; blank lines are ignored;
values may be quoted.

```ini
# ~/Library/Application Support/boringterminal/config
font-family = "SF Mono"
font-size = 14
```

## Keys

| Key | Type | Default | Notes |
|---|---|---|---|
| `font-family` | string | system monospace (SF Mono) | must be a monospaced family |
| `font-size` | number | 13 | 6–72 |

That is the whole surface, on purpose. Bold, italic, and bold-italic faces are
picked from the family where they exist and synthesized where they don't;
per-character fallback (emoji, CJK, symbols) is automatic and never changes
the cell size. There are no theme, opacity, padding, or cursor keys today.

## Hot reload

The file is watched. Save it and every open session re-renders with the new
font immediately. No restart, no reload command.

## Strictness

The file is validated as a whole:

- An **unknown key** or invalid value rejects the entire file.
- At launch, a rejected file is logged and ignored; the app starts with
  defaults rather than refusing to start.
- On reload, a rejected file keeps the current settings.
- A `font-family` that isn't installed or isn't monospaced falls back to the
  system monospace font.

## Not in the file

Sidebar visibility (<kbd>⌘B</kbd>) and sidebar width (drag the edge) are
remembered automatically as app state. They are direct manipulations, not
configuration.

Text size works the same way: <kbd>⌘+</kbd>, <kbd>⌘−</kbd>, and <kbd>⌘0</kbd>
scale the terminal font temporarily, within the same 6–72 point bounds, and
never rewrite the file. Changing `font-size` in the file resets the temporary
scale to the new value.
