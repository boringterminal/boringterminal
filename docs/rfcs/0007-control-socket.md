# RFC 0007: Control socket and CLI

Status: draft

This is the automation and inspection surface for sessions, not a plugin
mechanism. The core stays small, crash-isolated, and language-agnostic, and
agents themselves can drive the terminal ("open a session and run the tests
there"). Any future plugin model is a separate design; no in-process plugins
(RFC 0000).

Implementation starts only after RFC 0013's Codex cell/TUI fixture is green.
The phased Kitty graphics work in that RFC may continue independently after
the terminal-browser baseline is documented.

Prior art: kitty's remote control (`kitty @`) proves the model; wezterm's
`wezterm cli` likewise. We ship a much smaller verb set.

## Transport

- Unix socket, `~/Library/Application Support/boringterminal/control.sock`,
  mode 0600, owned by the daemon (RFC 0006). No TCP, no network story, ever.
- Protocol: newline-delimited JSON requests/responses. Versioned with a
  `v` field. Human-debuggable with `nc -U`.
- Auth = filesystem permissions. A config kill-switch (`control: off`)
  and an off-by-default `control_from_sessions` flag deciding whether
  processes *inside* sessions may use the socket (an agent driving its own
  terminal is the point — but it's consent, so it's a flag; the socket path
  is only exported into session env when enabled).

## The `term` CLI

Thin client over the socket:

```
term list [--json]                # sessions: id, title, state, cwd, attention
term open [--cwd DIR] [--group G] [--title T] [-- cmd args...]
term focus <id|title>
term close <id>                   # SIGHUP discipline, like closing the row
term set-title <id> <title>
term send <id> --text "..."       # write to the session's PTY (flag-gated,
                                  #   same consent story as control_from_sessions)
term get <id> [--lines N|--all]   # scrollback capture (agent reads a build log)
term notify <id> --message "..."  # raise attention as if OSC 9
term wait <id> --until idle|needs-you|exited   # block until state; THE verb
                                  #   that makes shell-script orchestration work
```

`term wait` deserves emphasis: with `open`, `get`, and `wait`, a shell script
is an orchestrator. That's the "bring your own agent" promise kept with four
verbs.

## Events

`term events [--json]` streams state changes (attention, title, open/close,
exit) as NDJSON until killed. Pull-based scripts use `wait`; dashboards and
tooling use `events`. No callback registration, no subscriptions to manage —
a stream you filter yourself.

## Non-goals

- No RPC into the UI beyond the verbs above (no "draw a panel", no menus,
  no keybinding registration). If a capability can't be expressed as a verb
  on sessions, it doesn't belong here.
- No stability promise before 1.0; after 1.0, verbs are append-only.
