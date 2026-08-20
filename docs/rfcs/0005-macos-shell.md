# RFC 0005: macOS shell — window, input, IME, PTY

Status: draft

The shell is deliberately thin: NSApplication, one window class, one
Metal-backed NSView per surface, event translation, PTY plumbing. All in Zig
via hand-written objc (`objc.zig` pattern). "Mac-native" is earned here, not
in the renderer.

## Window

- NSWindow + our NSView subclass hosting a CAMetalLayer (RFC 0004).
- Native fullscreen, `NSWindowTabbingModeDisallowed` (the sidebar is our
  tabbing), standard traffic lights, titlebar shows the focused session title.
- Minimum content size: 20 cols × 4 rows (`setContentMinSize:`) — smaller
  grids are degenerate for every party involved (shell repaint math,
  reflow, the user).
- Live resize: snap to cell grid, overlay showing `cols×rows`,
  `presentsWithTransaction` + synchronous in-transaction presentation
  during the drag (design: RFC 0009).
- Titles: OSC titles longer than a codepoint budget display
  middle-ellipsized ("…" — the Finder/Cursor convention; NSWindow also
  middle-truncates natively to the title bar width). Note: some shells
  pre-truncate before sending (oh-my-zsh's default
  `ZSH_THEME_TERM_TITLE_IDLE="%15<..<%~%<<"` produces "..oringterminal");
  that is upstream user config, not the terminal's to undo.
- OSC title payloads are untrusted byte strings. The session boundary replaces
  malformed UTF-8 with U+FFFD and applies its byte cap only between complete
  codepoints; the viewer repeats that validation defensively. AppKit is never
  called with a null `NSString`, so hostile or malformed child output cannot
  terminate the viewer.
- Drag-and-drop onto the view: local Finder file URLs insert their decoded,
  absolute filesystem paths through the same semantic-paste command as ⌘V.
  Multiple items retain pasteboard order and are joined by one ASCII space;
  no trailing space or newline is added, so a drop never executes a command.
  Shell-safe paths remain bare. Other paths use POSIX single-quote syntax,
  including the standard close/escaped-quote/reopen form for an embedded
  apostrophe. A drop over a visible member of a pair focuses and targets that
  member; the divider and exited sessions reject it.

  Only `public.file-url` items with local absolute paths participate. Text,
  remote URLs, file promises without a resolved local URL, malformed UTF-8,
  and paths containing terminal-control bytes are rejected rather than
  interpreted. The complete, space-joined drop is capped at 1 MiB and accepted
  or rejected atomically. Failure leaves terminal input and pair focus
  untouched and uses the native rejection cursor/beep. The view advertises a
  copy drag operation because Finder retains ownership of the filesystem
  objects; the terminal inserts text only.

## Keyboard input — the two-lane rule

`keyDown:` forwards to `interpretKeyEvents:` and then lanes split:

- **Text lane:** NSTextInputClient callbacks (`insertText:`, marked text)
  produce characters → encoded to the PTY. This lane gives us IME, dead keys
  (⌥e e → é), the emoji picker, and press-and-hold for free — *if* we
  implement NSTextInputClient honestly. Full protocol notes, gotchas, and the
  manual test checklist: docs/references/macos-ime.md.
- **Paste:** the viewer encodes the native pasteboard string once as UTF-8 and
  submits one bounded semantic-paste command. The daemon holds the active
  terminal lock, consults its authoritative mode 2004 state, encodes the
  complete paste once, and atomically queues that encoded buffer. The viewer
  never infers paste framing from a render snapshot, and neither process paces
  or splits a paste at line boundaries.

  Before framing, the daemon follows xterm's default paste-safety policy:
  NUL, BS, ENQ, EOT, ESC, DEL, and the default tty signal/editing controls
  (`VINTR`, `VQUIT`, `VKILL`, `VSUSP`, `VSTART`, `VSTOP`, `VWERASE`,
  `VLNEXT`, `VREPRINT`, `VDISCARD`) become ASCII spaces. Tabs remain tabs.
  With mode 2004 enabled, the filtered UTF-8 payload is enclosed by
  `CSI 200 ~` and `CSI 201 ~`, with newlines intact. Without mode 2004, each
  LF becomes CR so a pasted newline has the same terminal input meaning as
  Return; an existing CR is not collapsed. This matches xterm/Ghostty paste
  behavior independently rather than inventing an application-specific rule.
  All other bytes, including Unicode scalar, combining, variation-selector,
  modifier, regional-indicator, and ZWJ sequences, remain unchanged and are
  never split by the terminal.
- **Control lane:** keys the text system doesn't consume (`doCommandBySelector:`
  fallthrough, plus modified keys) → terminal key encoding: legacy xterm
  sequences by default, kitty keyboard protocol when the app negotiates it
  (docs/references/escape-sequences.md).

Control-lane keys cross the viewer/daemon boundary as semantic key, modifier,
and press/repeat/release events. The daemon encodes them under the active
screen's authoritative Kitty/DECCKM state; the viewer never caches negotiated
keyboard flags. `keyUp:` is forwarded for Kitty event-type reporting and is a
no-op in legacy mode. `flagsChanged:` continues to drive native shortcut hints;
standalone modifier events are deferred until Kitty's report-all phase.

Marked (pre-edit) text renders inline at the cursor with an underline —
renderer overlay, never written into the grid.

### Correlated native input amendment (2026-08-19)

One `keyDown:` is one native input transaction. After application key
equivalents are removed, the view records the original event, calls
`interpretKeyEvents:` exactly once, and accumulates the ordered committed text
from `insertText:replacementRange:` plus the final marked-text state. It then
submits semantic key/text events to the daemon; NSTextInputClient callbacks do
not independently race raw PTY writes against control-lane events. A callback
outside `keyDown:` (character palette, dictation, Services) submits a pure text
event. A key that begins, edits, cancels, or confirms active composition is not
also replayed into the terminal unless AppKit committed text for it. This keeps
dead keys and Korean/Japanese composition from double-inserting or leaking
Backspace/Escape.

The viewer retains the complete marked NSString as bounded UTF-8 plus AppKit's
selected UTF-16 range. The renderer draws it as an ephemeral overlay starting
at the live cursor of the focused pane: opaque terminal background, normal
foreground, a one-pixel underline per occupied cell, and a narrow composition
caret at the selected offset. It follows ordinary Unicode grapheme width and
wraps within that pane, but never changes grid cells, scrollback, cursor state,
selection, search, or daemon snapshots. Switching sessions, losing focus, or
committing/unmarking clears the overlay. `markedRange`, `selectedRange`,
`attributedSubstringForProposedRange:`, and
`firstRectForCharacterRange:actualRange:` describe that same retained state so
the candidate window and the visible pre-edit cannot disagree.

Known menu shortcuts are still consumed before this path. The former blanket
rule that Command never reaches a PTY is narrowed: an AppKit-owned key
equivalent never reaches it, while an unclaimed Command event may be represented
only after the foreground program explicitly negotiates Kitty report-all.

Implemented app shortcuts (⌘T new session, ⌘W close, ⌘K clear, ⌘1..9 session
jump, ⌘B sidebar, and ⌘, open the config file) are consumed before the lanes.
RFC 0016 reserves ⌘F/⇧⌘F for focused/all-session search and ⌘G/⇧⌘G
for result navigation. RFC 0014 reserves ⌘D for a new session beside the
current single, ⌥⌘←/→ for pair-member focus, ⇧⌥⌘←/→ for moving a
member to that side, ⌥⌘↑/↓ for display-item focus, ⇧⌥⌘↑/↓ for moving a
complete display item, and ⇧⌘Return for pane zoom. Bindings are advertised
only once their owning feature ships, at which point they appear in both the
menu and shortcut reference. RFC 0013 additionally owns the conventional
temporary text-size bindings ⌘+/⌘−/⌘0; they affect terminal cells only and
never rewrite configuration. “Open Configuration” also appears in the
application menu. It explicitly creates a
comment-only starter file when none exists, then asks `NSWorkspace` to open
the extensionless file with the user's default application for
`public.plain-text`. Resolving the content type explicitly avoids an unrelated
handler for extensionless files. Merely launching Boring Terminal never
creates the optional file. ⌘ never reaches the PTY.

The Help menu exposes **Keyboard Shortcuts** at ⌘?. It opens one non-modal,
native, read-only panel listing only shortcuts that are actually implemented,
grouped into Sessions, Terminal, and Application. The list includes the
hold-⌘ sidebar hint behavior and the positional ⌘1…⌘9 range. It does not list
menu-only pair operations as if they had keys, and it does not advertise
reserved future bindings. As each RFC 0014/0016 action ships, its menu item and
help-panel row land in the same change. Shortcuts are deliberately
non-configurable: the menu, panel, and responder actions are one fixed product
vocabulary rather than another preferences subsystem.

The panel has a fixed 492-by-520-point content viewport. Its sections live in
a native vertical scroll view whose document height grows with the implemented
shortcut list. Adding a shortcut therefore never stretches the help window or
pushes its last rows outside the screen; ordinary wheel and trackpad scrolling
reaches every entry, with no horizontal scroller.

⌘K follows the native macOS terminal convention: clear the active primary
screen's scrollback, return its viewport to the live bottom, and send form
feed (`^L`) to the foreground application so it clears/repaints its mutable
screen without desynchronizing the PTY application's cursor model. On the
alternate screen there is no history to discard, so only `^L` is sent.

## Mouse

Selection (char/word/line by click count), scroll wheel → viewport (or arrow
keys on alt screen — mode-dependent, standard behavior), OSC 8 hyperlinks
⌘-clickable, mouse-report modes forwarded when apps enable them,
option-click to bypass mouse reporting (users expect iTerm's escape hatch).

The viewer sends zero-based cell events rather than escape bytes; RFC 0002's
daemon-side encoder owns tracking/format policy. Left press/drag/release,
right and middle buttons, motion, and vertical/horizontal wheel steps are
forwarded only at the live viewport when tracking is enabled. A left-button
gesture that begins with Option bypasses reporting for its full lifetime and
uses the normal local selection path. Trackpad deltas accumulate to complete
cell steps and are capped per callback to keep event bursts bounded.

## PTY

- `posix_openpt`/`openpty`, fork/exec the user's shell as a login shell
  (`-l`); set `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM`.
- Preserve `NO_COLOR` exactly as inherited. A non-empty value is user policy
  for applications to suppress default ANSI color; it does not reduce the
  terminal's color capability or authorize the terminal to ignore SGR colors
  that applications do emit. Development launchers must remove environment
  policy they injected before starting the application rather than teaching
  PTY creation about a particular agent or build harness.
- Preserve valid user locale choices, including an explicit plain `C` locale.
  macOS does not provide Linux's `C.UTF-8`/`C.utf8` locale aliases, however;
  inherited use of either silently collapses `LC_CTYPE` to `C` and makes
  shells expose pasted UTF-8 as individual meta bytes. Before spawning a PTY,
  remove that invalid `LC_ALL` override, rewrite the same alias in `LANG` to
  `en_US.UTF-8`, and ensure `LC_CTYPE=UTF-8`. Existing valid values remain
  authoritative. This is an alias correction, not a general override of the
  user's locale policy.
- Resize: `TIOCSWINSZ` + the kernel sends SIGWINCH; send once per settled
  cell size during live resize, not per-point. Always populate `ws_xpixel` and
  `ws_ypixel` from the backing-pixel cell geometry, including the initial
  same-row/column update and backing-scale-only changes. The daemon supplies
  the same geometry to the pure VT for truthful XTWINOPS 14/16 reports.
- Read loop: kqueue on the fd, large reads (≥64 KiB buffer), feed `vt`,
  coalesce damage (RFC 0004). Write side: non-blocking with a bounded queue —
  paste can be bigger than the kernel buffer; never deadlock on a full pty
  while the child is also writing. The whole encoded paste, including both
  mode-2004 delimiters, is accepted or rejected as one queue operation; a
  partial request can never strand bracketed-paste state in the child.
- Child exit: SIGCHLD → reap → session enters "exited" state (sidebar shows
  it; config decides keep-or-close). Details and traps:
  docs/references/pty.md.
- In the daemon model (RFC 0006) this whole section lives in the daemon
  process; the shell just renders and forwards input. Build it as a module
  with that boundary in mind from day one.

## Mac-native checklist (the "doesn't feel like Alacritty" list)

- [ ] IME: Japanese, Chinese, Korean input with candidate window positioned
      at the cursor (`firstRectForCharacterRange:`)
- [ ] Dead keys and press-and-hold accents
- [ ] Emoji & Symbols picker (⌃⌘Space) inserts at cursor
- [ ] Secure Keyboard Entry (`EnableSecureEventInput`) as a manual menu item
      first; automatic detection during password prompts is a later maybe
- [ ] Services menu / dictation receive selected text (NSTextInputClient
      done right gives most of this)
- [ ] Standard clipboard incl. ⌘V of file → path; OSC 52 policy: write
      allowed, read requires config opt-in (security)
- [ ] System appearance: respond to light/dark for chrome; cell colors come
      from the theme in config
- [ ] Quit confirmation only when sessions would actually die (daemonized
      sessions → quit is silent and instant). During in-process ownership,
      the red close control and ⌘Q show one consolidated warning only when at
      least one session has a foreground job. Cancel keeps the window open;
      idle shells close silently; a final-session close already confirmed by
      the user never prompts twice.
