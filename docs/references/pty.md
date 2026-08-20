# PTY plumbing on macOS — field notes

Small subsystem, famous traps. Reference when implementing RFC 0005/0006.

## Opening

- `posix_openpt(O_RDWR | O_NOCTTY)` → `grantpt` → `unlockpt` → `ptsname_r`
  (macOS: `ptsname` + immediate copy; not thread-safe) — or just
  `openpty(3)` from `<util.h>`, which does all of it. Use `openpty`.
- Child after fork: `login_tty(slave_fd)` (`<util.h>`) — does setsid,
  TIOCSCTTY, dup2 to stdio, closes fd. Use it; hand-rolling this is where
  "no job control" bugs come from.
- Exec the user's shell from `dscl`/`getpwuid` (`pw_shell`), argv[0]
  prefixed with `-` **or** `-l` flag for a login shell (macOS convention:
  every new terminal tab is a login shell — profiles expect it).
- Environment: inherit app env minus our noise; set `TERM=xterm-256color`,
  `COLORTERM=truecolor`, `TERM_PROGRAM=boringterminal`, `TERM_PROGRAM_VERSION`,
  `LANG` if unset (from NSLocale — shells misbehave in C locale).
  Preserve `NO_COLOR`: its [canonical convention](https://no-color.org/)
  assigns the decision to the child application, while the terminal remains
  capable of rendering any SGR colors it receives. A development runner that
  inherits injected policy from an automation harness must clean its own
  launch environment before the app starts; PTY creation must not contain
  agent-specific exceptions.
  Normalize inherited Linux-only `LC_ALL=C.UTF-8`/`C.utf8` on macOS by
  removing `LC_ALL`, rewriting the same alias in `LANG` to `en_US.UTF-8`, and
  ensuring `LC_CTYPE=UTF-8`; otherwise zsh's editor exposes each pasted UTF-8
  byte as a meta character. Preserve valid locales and an intentional
  `LC_ALL=C`.
  Do NOT set `TERM_SESSION_ID`-style vars beyond our own documented one.
- macOS quirk: GUI apps don't inherit a login environment; that's *why* the
  login-shell convention exists. Don't try to be clever with launchctl env.

## The event loop

- kqueue: `EVFILT_READ` on master fd. Read into a big buffer (≥64 KiB);
  loop until EAGAIN (edge-ish draining keeps syscall count down under
  `yes`-style floods).
- **EIO/HUP on master read = child side gone** → treat as EOF, reap, mark
  session exited. On macOS you may get `EVFILT_READ` with `EV_EOF` flag —
  check both paths.
- Write side (keystrokes, paste, `pty_write` actions from vt): master fd is
  non-blocking; kernel pty buffer is small (~KBs). A large paste MUST queue
  in userspace and drain on `EVFILT_WRITE`, else you deadlock: child blocked
  writing output we're not reading while we block writing input. Never
  blocking-write to the pty from the read thread. Paste is one semantic
  viewer request: encode it from daemon-authoritative mode-2004 state and
  admit the whole encoded buffer atomically, then let normal write readiness
  drain it without timers or line pacing.
- Flow control: if `vt` parsing ever falls behind (it shouldn't), prefer
  letting the kernel pty buffer backpressure the child naturally — do not
  buffer unbounded output in userspace.

## Resize

- `ioctl(master, TIOCSWINSZ, &winsize{ws_col, ws_row, ws_xpixel, ws_ypixel})`
  — fill the pixel fields too (some TUIs use them for image sizing; costs
  nothing). Kernel delivers SIGWINCH to the foreground process group.
- During live resize: settle-debounce (send on cell-size change, coalesced
  per frame), and call `vt.resize` in the same step so grid and winsize
  never disagree (apps repaint against the CPR/winsize they can query).

## Child lifecycle

- SIGCHLD via kqueue `EVFILT_SIGNAL` (signal-handler-free; we're not the
  only thread). `waitpid(pid, &st, WNOHANG)` loop — reap all.
- Closing a session: `SIGHUP` to the child's process *group* (kill(-pgid)),
  grace period, then SIGKILL. The daemon (RFC 0006) makes "window closed"
  ≠ "SIGHUP" — that's the whole point; only explicit `term close`/row-close
  hangs up.
- Report exit status in the sidebar state (RFC 0006 attention table).

## Misc

- utmpx registration (`login`-style entries for `w`/`who`): skip. Modern
  macOS terminals mostly don't bother; revisit only on a real complaint.
- `ioctl(TIOCPKT)` packet mode: skip; complicates reads for flow-control
  info we don't use.
- Working directory of new sessions: default = focused session's child cwd
  via `proc_pidinfo(PROC_PIDVNODEPATHINFO)` on its foreground pid — the
  "new tab inherits cwd" behavior everyone expects; OSC 7 (when shells emit
  it) overrides the guess.
- Foreground process name (for the sidebar subtitle / "running: cargo"):
  `tcgetpgrp(master)` → `proc_name`. Poll lazily (on 133 C, on focus), never
  on a timer.
