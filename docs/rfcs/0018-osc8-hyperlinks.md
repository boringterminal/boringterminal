# RFC 0018: OSC 8 semantic hyperlinks

Status: shipped

## Objective

Boring Terminal implements the terminal hyperlink standard and nothing wider:
applications may attach a URI to arbitrary painted text with OSC 8, and the
viewer makes that semantic range discoverable and openable without guessing
from its label.

This passes RFC 0000's one-line test because agents and their tools routinely
emit compact labels for files, diagnostics, commits, and documentation. The
terminal preserves that routing metadata across long-lived daemon sessions and
scrollback. It does not become a configurable text-matching or command-running
system.

## Wire semantics

The accepted form is the published convention:

```text
OSC 8 ; params ; URI ST
```

`BEL` is accepted in place of `ST`, consistently with the existing OSC parser.
The first semicolon after code 8 separates parameters; the next semicolon
separates parameters from the URI, so semicolons inside the URI remain data.
`params` is a colon-separated list of `key=value` assignments. Only the exact
lowercase key `id` is interpreted; unknown and malformed assignments are
ignored for forward compatibility.

`OSC 8 ; ; ST` closes the active hyperlink. A nonempty URI replaces any active
hyperlink without requiring a close first. An empty URI with nonempty
parameters is malformed and changes no state. An empty or absent `id` has
implicit identity.

For portability and bounded storage, parameter and URI bytes must be printable
ASCII (`0x20...0x7e`). URI length is capped at 2083 bytes and explicit `id` at
250 bytes, following the interoperable VTE/iTerm2 limits. Invalid or oversized
input is consumed without changing the active hyperlink.

Each accepted opening without a nonempty explicit `id` creates a fresh run
identity, even when its URI matches an older run. Cells with the same nonempty
explicit `id` and URI share identity across repaint, line breaks, and separated
screen regions. An `id` never joins different URIs.

## VT and grid ownership

Hyperlink state is terminal state, separate from SGR:

- every printed content cell receives the active hyperlink id;
- both cells of a wide glyph receive it, while wrap padding and erased blanks
  do not;
- grapheme suffixes retain the head cell's identity;
- insertion, deletion, scrolling, selection, search, and reflow move link ids
  with cells exactly as they move colors and text;
- SGR reset does not close a hyperlink;
- DEC save/restore cursor saves/restores the active hyperlink, matching the
  attribute-like OSC 8 model;
- DECSTR and RIS close it, and RIS also releases all retained link metadata.

The pure VT core owns a bounded table of `(explicit id, URI)` metadata. Cells
carry a compact nonzero `u32` table id; zero means no hyperlink. The table
allows at most 16,384 live identities and 8 MiB of URI/id bytes. Before refusing
a new entry, the terminal compacts metadata by tracing the primary ring,
alternate grid, active hyperlink, and saved cursors, then rewrites their ids.
If live retained history itself fills either bound, later openings degrade to
no active hyperlink until eviction makes room. Output processing never blocks,
performs I/O, or allocates without a bound.

Hyperlink metadata is not included in copied selection text or search text.
RFC 0016 continues to search the visible label only.

## Daemon snapshot

The daemon remains authoritative for hyperlink state. Attach protocol version
13 extends each encoded cell with a snapshot-local hyperlink id and appends a
bounded table containing only identities referenced by visible cells. The
capture step remaps terminal-local ids to dense snapshot-local ids; table order
has no semantic meaning.

The decoder validates printable ASCII, length limits, nonempty URIs, unique
snapshot identities, and every cell reference before publishing the snapshot.
Viewer detach/reattach therefore retains links and scrollback without copying
the retained grid into the viewer. A mixed v12/v13 viewer and daemon fail
closed through the existing frame-version check.

## Native interaction and rendering

OSC 8 links are not permanently recolored or underlined. Holding Command while
the pointer is over a linked cell:

- underlines every visible cell with the same semantic identity;
- uses the macOS pointing-hand cursor;
- does not mutate VT cells or the authoritative snapshot.

Moving the pointer, releasing Command, switching sessions, changing the
viewport, or receiving a replacement snapshot clears or recomputes that
viewer-local hover. This keeps a stale snapshot id from highlighting a
different link after repaint.

Command-click opens the URI and consumes the click before terminal mouse
reporting or local selection. A plain click retains existing selection/mouse
behavior, and Option-click remains the application-mouse-reporting escape
hatch from RFC 0005. The renderer receives only the hovered snapshot-local id
for each pane and adds the same one-pixel decoration used by ordinary
underlines; no hyperlink state enters Metal shaders.

There is deliberately no visible-URL regex, hint alphabet, configurable
matcher, or link command. Software that wants a link emits OSC 8.

## Opening policy

Terminal output is untrusted. A URI opens only after an explicit Command-click
and successful native URL parsing.

- `http`, `https`, `ftp`, and `mailto` open through `NSWorkspace` directly.
- `file` opens only with an empty host, `localhost`, or this Mac's current
  hostname, and only when its decoded path is absolute. A remote hostname is
  rejected rather than silently opening the same path on the wrong computer.
- other absolute schemes receive a native confirmation showing the exact URI;
  approval passes the unchanged URI to `NSWorkspace`, while cancel changes
  nothing.
- missing schemes, embedded controls, invalid encodings, and URLs rejected by
  Foundation are not opened. Failure gives the ordinary system beep and never
  reaches the PTY.

The terminal never executes a URI as a command, resolves a relative file path,
or decodes it into shell input.

## Testing and acceptance

Pure VT coverage must include ST and BEL termination, one-byte chunking,
explicit and implicit identity, replacement/close/malformed forms, SGR
independence, save/restore/reset, wide cells, erasure, scrolling, eviction,
and resize reflow. Protocol tests cover metadata round-trip and every invalid
reference/bound. Renderer tests prove hover decoration spans a wrapped link
without altering unrelated cells.

Native acceptance:

1. emit an OSC 8 link whose label is not itself a URL;
2. plain hover/click behaves like ordinary terminal text;
3. Command-hover underlines the full semantic range and shows a pointing hand;
4. Command-click opens an `https` link once;
5. a remote-host `file:` URI and malformed URI do not open;
6. close/reopen the viewer and verify the retained link still works.

## Prior art and attribution

- iTerm2/VTE OSC 8 convention: syntax, explicit-id grouping, implicit-run
  recommendation, file-host rule, and interoperable length bounds.
- Ghostty (MIT), `src/terminal/osc/parsers/hyperlink.zig` and terminal hyperlink
  storage: malformed-form behavior and bounded managed metadata.
- Alacritty (Apache-2.0), `alacritty_terminal/src/term/cell.rs`: implicit
  per-opening identity and rare per-cell hyperlink metadata.

No Kitty source is consulted or ported; Kitty graphics is an independent APC
image protocol and has no dependency relationship with OSC 8.

## Rejected alternatives

- **Regex-detect visible URLs.** It creates false positives, configuration,
  and a second semantic source. Applications already have OSC 8.
- **Wait for Kitty graphics.** OSC cell metadata and APC image resources are
  independent and neither simplifies the other.
- **Open on an ordinary click.** It conflicts with selection and mouse-report
  applications and weakens the intentional-action security boundary.
- **Store URI bytes in every cell.** It makes scrollback memory proportional
  to label length times URI length and bloats daemon snapshots.
- **Let the viewer own links.** Detach would lose semantics and duplicate the
  authoritative scrollback state.
