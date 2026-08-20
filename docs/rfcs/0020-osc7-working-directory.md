# RFC 0020: OSC 7 working-directory reports

Status: accepted

## Objective

A shell or terminal application can report its current working directory with
OSC 7. Boring Terminal uses that report as the authoritative cwd for session
metadata and for new sessions created from the reporting session.

This removes process inspection from the ordinary path without requiring shell
plugins. Programs that do not emit OSC 7 keep the existing macOS foreground-
process lookup and `$HOME` fallback.

## Sequence and pure-core boundary

The accepted form is `OSC 7 ; URI ST`; BEL termination is accepted as well.
The VT core parses the OSC selector, owns a bounded copy of `URI`, and emits a
`cwd_report` action. It does not parse URLs, inspect the hostname or filesystem,
or mutate session metadata. Empty `URI` is a real action that clears a previous
report.

The URI action is capped independently of the parser's general OSC buffer.
Oversized values are consumed and ignored. Action storage is released by the
same drain/clear lifecycle as titles and PTY replies, including allocation-
failure cleanup.

## Host validation

The daemon treats terminal output as untrusted. A non-empty report is accepted
only when all of these hold:

- the scheme is `file`, case-insensitively;
- user information, password, port, query, and fragment are absent;
- the authority is empty, `localhost`, or the local machine hostname;
- percent escapes decode exactly once into an absolute path;
- the decoded path contains no NUL, C0 control, or DEL byte, fits the PTY cwd
  bound.

The path is not normalized or resolved through symlinks. A remote-host report,
malformed URI, or oversized value is ignored and does not replace the last
accepted cwd. An empty report clears the accepted cwd. The PTY reader never
blocks on filesystem lookup: before inheriting a stored report, the create
command checks that it names a directory. A missing, non-directory, deleted, or
inaccessible path falls through to the existing process lookup.

## Ownership and inheritance

The daemon session owns the accepted decoded path independently of VT screen
state. It survives viewer replacement for as long as the daemon session does.
Changes mark session metadata dirty so attached viewers and future control-
socket clients observe one coherent value.

New-session cwd precedence is:

1. an explicit cwd in the create request;
2. the focused/source session's accepted OSC 7 cwd, if still usable;
3. the source session's foreground-process cwd from macOS process metadata;
4. `$HOME`.

This precedence applies to ordinary new sessions and sessions created beside a
specific member. OSC 7 never changes the cwd of an already-running process.

## Attach protocol

Attach dialect 16 appends an optional bounded absolute cwd to each metadata
record. `null` means that no accepted OSC 7 report is active. The cwd is not
part of the renderer snapshot: it does not affect cells and metadata
invalidations already have an independent lane.

The current viewer translates metadata from retained v13 and v10 daemons with
`cwd = null`; their daemon-side foreground-process inheritance remains honest.
Dialect 15 was development-only and receives no compatibility capsule.

## Verification

- pure VT tests cover ST, BEL, byte-split input, empty reset, and the action
  bound;
- host-policy tests cover local authorities, percent decoding, malformed and
  remote URIs, control bytes, and non-directory paths;
- daemon integration proves metadata updates and a child session inherits the
  report rather than the reporting process's real cwd;
- retained-dialect tests prove old metadata decodes to `cwd = null`.

## Rejected alternatives

- **Trust every `file://` URI.** Remote shells could make a local terminal
  expose or attempt arbitrary local paths.
- **Parse and validate in `src/vt/`.** Hostname and filesystem policy would
  violate the pure-core boundary.
- **Replace process inspection entirely.** Existing shells and applications
  that do not emit OSC 7 would regress.
- **Add cwd to renderer snapshots.** It would churn the large grid schema for
  state already carried by metadata.

## Prior art

- Ghostty OSC 7 documentation:
  https://ghostty.org/docs/features/shell-integration#working-directory
- Ghostty keeps URI/local-host policy outside its terminal parser:
  https://github.com/ghostty-org/ghostty/blob/main/src/termio/stream_handler.zig
