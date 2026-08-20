//! PTY plumbing per docs/references/pty.md: openpty + login_tty + the
//! user's login shell. The reader is a plain blocking thread in iteration 0
//! (one session, one fd); kqueue arrives with multi-session work.
//!
//! Syscalls go through std.c (the stdlib's libc layer). Only openpty and
//! login_tty are hand-declared: they live in util.h, which std.c does not
//! cover.

const std = @import("std");
const c = std.c;
const version = @import("../version.zig");

extern "c" fn openpty(
    master: *c.fd_t,
    slave: *c.fd_t,
    name: ?[*]u8,
    termp: ?*const anyopaque,
    winp: ?*const c.winsize,
) c_int;
extern "c" fn login_tty(fd: c.fd_t) c_int;
// Zig 0.16's std.posix.tcgetpgrp references a declaration missing from its
// Darwin std.c surface. Keep this beside openpty/login_tty, the other narrow
// util/termios declarations absent from std.c.
extern "c" fn tcgetpgrp(fd: c.fd_t) c.pid_t;
extern "c" fn proc_pidinfo(
    pid: c_int,
    flavor: c_int,
    arg: u64,
    buffer: *anyopaque,
    buffer_size: c_int,
) c_int;

pub const max_path_len = 1024;
const proc_pidvnodepathinfo = 9;
const VnodeInfoPath = extern struct {
    // `struct vnode_info` from <sys/proc_info.h>. Its contents are irrelevant
    // here, but its stable Darwin ABI fixes the following path's offset.
    vnode_info: [152]u8,
    path: [max_path_len]u8,
};
const ProcVnodePathInfo = extern struct {
    current_dir: VnodeInfoPath,
    root_dir: VnodeInfoPath,
};
comptime {
    std.debug.assert(@offsetOf(VnodeInfoPath, "path") == 152);
    std.debug.assert(@sizeOf(ProcVnodePathInfo) == 2352);
}

/// _IOW('t', 103, struct winsize) from <sys/ttycom.h> — absent from
/// std.c's darwin T constants. @bitCast because the value overflows c_int
/// and ioctl wants the bit pattern.
const TIOCSWINSZ: c_int = @bitCast(@as(u32, 0x80087467));

pub const SpawnOptions = struct {
    /// Override the command (argv[0] must be an absolute path — we exec
    /// via execve, no PATH search); null runs the user's login shell.
    argv: ?[]const []const u8 = null,
    /// Parent environment to inherit (the app passes main's
    /// init.environ_map). null starts the child from an empty environment
    /// plus the terminal vars — what the hermetic tests want.
    env: ?*const std.process.Environ.Map = null,
    /// Best-effort initial cwd. If it disappears between lookup and fork,
    /// the child keeps the daemon's `$HOME` cwd.
    cwd: ?[]const u8 = null,
    cols: u16 = 80,
    rows: u16 = 24,
};

pub const Pty = struct {
    master: c.fd_t,
    child: c.pid_t,

    pub const ReadResult = union(enum) {
        bytes: usize,
        would_block,
        eof,
    };

    pub const WriteResult = union(enum) {
        bytes: usize,
        would_block,
        closed,
    };

    pub fn spawn(alloc: std.mem.Allocator, opts: SpawnOptions) !Pty {
        // Everything that allocates happens before fork; the child only
        // execs from prebuilt buffers.
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var env = if (opts.env) |parent|
            try parent.clone(arena)
        else
            std.process.Environ.Map.init(arena);
        try env.put("TERM", "xterm-256color");
        try env.put("COLORTERM", "truecolor");
        try env.put("TERM_PROGRAM", "boringterminal");
        try env.put("TERM_PROGRAM_VERSION", version.semantic);
        try normalizeMacOSUtf8Locale(&env);
        if (env.get("LANG") == null) try env.put("LANG", "en_US.UTF-8");
        const envp = try env.createPosixBlock(arena, .{});
        const cwd_z = if (opts.cwd) |path| try arena.dupeZ(u8, path) else null;

        var exe_path: [:0]const u8 = undefined;
        var argv_z: [][*:0]const u8 = undefined;
        if (opts.argv) |argv| {
            exe_path = try arena.dupeZ(u8, argv[0]);
            argv_z = try arena.alloc([*:0]const u8, argv.len);
            for (argv, 0..) |a, i| argv_z[i] = try arena.dupeZ(u8, a);
        } else {
            const shell = userShell(&env);
            exe_path = try arena.dupeZ(u8, shell);
            // Login-shell convention: argv[0] is "-<basename>".
            const base = std.fs.path.basename(shell);
            const argv0 = try std.fmt.allocPrintSentinel(arena, "-{s}", .{base}, 0);
            argv_z = try arena.alloc([*:0]const u8, 1);
            argv_z[0] = argv0;
        }
        const argv_null = try arena.allocSentinel(?[*:0]const u8, argv_z.len, null);
        for (argv_z, 0..) |a, i| argv_null[i] = a;

        var master: c.fd_t = 0;
        var slave: c.fd_t = 0;
        const ws: c.winsize = .{ .row = opts.rows, .col = opts.cols, .xpixel = 0, .ypixel = 0 };
        if (openpty(&master, &slave, null, null, &ws) != 0) return error.OpenPtyFailed;
        errdefer _ = c.close(master);

        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            // Child. login_tty does setsid + TIOCSCTTY + stdio dup + close.
            _ = c.close(master);
            if (login_tty(slave) != 0) c._exit(127);
            if (cwd_z) |path| _ = c.chdir(path.ptr);
            _ = c.execve(exe_path.ptr, argv_null.ptr, envp.slice.ptr);
            c._exit(127);
        }

        _ = c.close(slave);
        return .{ .master = master, .child = pid };
    }

    /// Blocking read; EOF (or the EIO a dead child side reads as) is 0.
    pub fn read(self: *const Pty, buf: []u8) usize {
        while (true) {
            const rc = c.read(self.master, buf.ptr, buf.len);
            if (rc >= 0) return @intCast(rc);
            switch (c.errno(rc)) {
                .INTR => continue,
                else => return 0,
            }
        }
    }

    pub fn setNonBlocking(self: *const Pty) !void {
        const flags = c.fcntl(self.master, c.F.GETFL);
        if (flags < 0) return error.FcntlFailed;
        // O_NONBLOCK is 0x0004 on Darwin. This project is macOS-only.
        if (c.fcntl(self.master, c.F.SETFL, flags | 0x0004) < 0) return error.FcntlFailed;
        if (c.fcntl(self.master, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0)
            return error.FcntlFailed;
    }

    pub fn readNonBlocking(self: *const Pty, buf: []u8) ReadResult {
        while (true) {
            const rc = c.read(self.master, buf.ptr, buf.len);
            if (rc > 0) return .{ .bytes = @intCast(rc) };
            if (rc == 0) return .eof;
            switch (c.errno(rc)) {
                .INTR => continue,
                .AGAIN => return .would_block,
                .IO => return .eof,
                else => return .eof,
            }
        }
    }

    pub fn writeNonBlocking(self: *const Pty, bytes: []const u8) WriteResult {
        while (true) {
            const rc = c.write(self.master, bytes.ptr, bytes.len);
            if (rc > 0) return .{ .bytes = @intCast(rc) };
            if (rc == 0) return .would_block;
            switch (c.errno(rc)) {
                .INTR => continue,
                .AGAIN => return .would_block,
                else => return .closed,
            }
        }
    }

    /// The standalone conformance host owns a blocking PTY and has no GUI
    /// request path. Daemon sessions must use writeNonBlocking via Session.
    pub fn writeBlockingForTestHost(self: *const Pty, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) {
            const rc = c.write(self.master, rest.ptr, rest.len);
            if (rc < 0) {
                if (c.errno(rc) == .INTR) continue;
                return;
            }
            if (rc == 0) return;
            rest = rest[@intCast(rc)..];
        }
    }

    pub fn resize(self: *const Pty, cols: u16, rows: u16, px_w: u16, px_h: u16) void {
        const ws: c.winsize = .{ .row = rows, .col = cols, .xpixel = px_w, .ypixel = px_h };
        _ = c.ioctl(self.master, TIOCSWINSZ, @intFromPtr(&ws));
    }

    pub fn hangup(self: *const Pty) void {
        // The session-close discipline (SIGHUP the child's group) — see
        // docs/references/pty.md.
        self.signalProcessGroups(.HUP);
    }

    pub fn kill(self: *const Pty) void {
        self.signalProcessGroups(.KILL);
    }

    fn signalProcessGroups(self: *const Pty, signal: std.posix.SIG) void {
        // Job control moves a running command into its own foreground process
        // group. Signal that group as well as the login shell's group so an
        // ignored SIGHUP cannot leave the PTY reader alive forever.
        const foreground = tcgetpgrp(self.master);
        if (foreground > 0 and foreground != self.child) _ = c.kill(-foreground, signal);
        _ = c.kill(-self.child, signal);
        _ = c.kill(self.child, signal);
    }

    /// True when job control has handed the terminal to a process group
    /// other than the login shell. This is the precise condition for a
    /// destructive-close warning: background jobs do not own the terminal.
    pub fn hasForegroundJob(self: *const Pty) bool {
        const foreground = tcgetpgrp(self.master);
        return foreground >= 0 and foreground != self.child;
    }

    /// Resolve the focused process group's current directory using Darwin's
    /// documented libproc ABI. The pgrp leader is the shell while idle and
    /// the foreground job leader while a command/TUI is running.
    pub fn foregroundWorkingDirectory(
        self: *const Pty,
        out: *[max_path_len]u8,
    ) ?[]const u8 {
        const foreground = tcgetpgrp(self.master);
        if (foreground < 0) return null;
        var info: ProcVnodePathInfo align(8) = undefined;
        const written = proc_pidinfo(
            foreground,
            proc_pidvnodepathinfo,
            0,
            &info,
            @sizeOf(ProcVnodePathInfo),
        );
        if (written != @sizeOf(ProcVnodePathInfo)) return null;
        const path = std.mem.sliceTo(&info.current_dir.path, 0);
        if (path.len == 0 or path.len >= out.len) return null;
        @memcpy(out[0..path.len], path);
        return out[0..path.len];
    }

    pub fn wait(self: *const Pty) void {
        var status: c_int = 0;
        _ = c.waitpid(self.child, &status, 0);
    }

    /// Reap and return the child's exit code (128 for abnormal exit).
    pub fn waitStatus(self: *const Pty) u8 {
        var status: c_int = 0;
        _ = c.waitpid(self.child, &status, 0);
        if (status & 0x7f == 0) return @intCast((status >> 8) & 0xff); // WIFEXITED
        return 128;
    }

    pub fn closeFd(self: *const Pty) void {
        _ = c.close(self.master);
    }
};

/// macOS has no `C.UTF-8` locale even though Linux development tools commonly
/// export it. libc silently collapses that alias to `C`, which makes shells
/// treat valid pasted UTF-8 as separate meta bytes. Correct only those known
/// aliases; deliberate `C` and every valid user locale remain untouched.
fn normalizeMacOSUtf8Locale(env: *std.process.Environ.Map) !void {
    var saw_alias = false;
    if (env.get("LC_ALL")) |value| {
        if (isLinuxCUtf8(value)) {
            _ = env.swapRemove("LC_ALL");
            saw_alias = true;
        }
    }
    if (env.get("LANG")) |value| {
        if (isLinuxCUtf8(value)) {
            try env.put("LANG", "en_US.UTF-8");
            saw_alias = true;
        }
    }
    if (env.get("LC_CTYPE")) |value| {
        if (isLinuxCUtf8(value)) {
            try env.put("LC_CTYPE", "UTF-8");
            saw_alias = true;
        }
    }
    if (saw_alias and env.get("LC_CTYPE") == null) try env.put("LC_CTYPE", "UTF-8");
}

fn isLinuxCUtf8(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "C.UTF-8") or
        std.ascii.eqlIgnoreCase(value, "C.utf8");
}

fn userShell(env: *const std.process.Environ.Map) []const u8 {
    if (c.getpwuid(c.getuid())) |pw| {
        if (pw.shell) |sh| {
            const s = std.mem.span(sh);
            if (s.len > 0) return s;
        }
    }
    if (env.get("SHELL")) |sh| {
        if (sh.len > 0) return sh;
    }
    return "/bin/zsh";
}

test "Linux C UTF-8 aliases are normalized for macOS PTY children" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("LANG", "C.UTF-8");
    try env.put("LC_ALL", "c.utf8");
    try env.put("LC_CTYPE", "C.UTF-8");
    try normalizeMacOSUtf8Locale(&env);
    try std.testing.expectEqualStrings("en_US.UTF-8", env.get("LANG").?);
    try std.testing.expect(env.get("LC_ALL") == null);
    try std.testing.expectEqualStrings("UTF-8", env.get("LC_CTYPE").?);
}

test "valid and deliberately non-Unicode locales are preserved" {
    var valid = std.process.Environ.Map.init(std.testing.allocator);
    defer valid.deinit();
    try valid.put("LANG", "en_GB.UTF-8");
    try valid.put("LC_ALL", "C");
    try normalizeMacOSUtf8Locale(&valid);
    try std.testing.expectEqualStrings("en_GB.UTF-8", valid.get("LANG").?);
    try std.testing.expectEqualStrings("C", valid.get("LC_ALL").?);
    try std.testing.expect(valid.get("LC_CTYPE") == null);
}

test "PTY child preserves NO_COLOR user policy" {
    const alloc = std.testing.allocator;
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("NO_COLOR", "yes");

    var pty = try Pty.spawn(alloc, .{
        .argv = &.{ "/bin/sh", "-c", "printf '%s' \"$NO_COLOR\"" },
        .env = &env,
    });
    defer pty.closeFd();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var buf: [64]u8 = undefined;
    while (true) {
        const n = pty.read(&buf);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0..n]);
    }
    pty.wait();
    try std.testing.expectEqualStrings("yes", out.items);
}

test "PTY child receives the normalized macOS UTF-8 locale" {
    const alloc = std.testing.allocator;
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("LANG", "C.UTF-8");
    try env.put("LC_ALL", "C.UTF-8");
    try env.put("LC_CTYPE", "C.UTF-8");

    var pty = try Pty.spawn(alloc, .{
        .argv = &.{
            "/bin/sh",
            "-c",
            "printf '%s|%s|%s' \"$LANG\" \"${LC_ALL-unset}\" \"$LC_CTYPE\"",
        },
        .env = &env,
    });
    defer pty.closeFd();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var buf: [256]u8 = undefined;
    while (true) {
        const n = pty.read(&buf);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0..n]);
    }
    pty.wait();
    try std.testing.expectEqualStrings("en_US.UTF-8|unset|UTF-8", out.items);
}

test "pty end to end: spawn, env, read, reap" {
    const alloc = std.testing.allocator;
    var pty = try Pty.spawn(alloc, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'ok:%s:%s:%s' \"$TERM\" \"$TERM_PROGRAM\" \"$TERM_PROGRAM_VERSION\"" },
        .cols = 40,
        .rows = 10,
    });
    defer pty.closeFd();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pty.read(&buf);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0..n]);
    }
    pty.wait();
    try std.testing.expect(std.mem.indexOf(u8, out.items, "ok:xterm-256color:boringterminal:0.4.0") != null);
}

test "pty feeds terminal" {
    // The RFC 0008 integration test: real child process output through the
    // real parser into the real grid.
    const vt = @import("../vt.zig");
    const alloc = std.testing.allocator;

    var pty = try Pty.spawn(alloc, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'hi\\r\\n\\033[1;32mgreen\\033[0m'" },
        .cols = 20,
        .rows = 4,
    });
    defer pty.closeFd();

    var v = try vt.Vt.init(alloc, 20, 4);
    defer v.deinit();

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pty.read(&buf);
        if (n == 0) break;
        v.feed(buf[0..n]);
    }
    pty.wait();

    const dump = try v.term.dumpText(alloc);
    defer alloc.free(dump);
    try std.testing.expectEqualStrings("hi\ngreen\n\n", dump);
    try std.testing.expectEqual(vt.Color{ .indexed = 2 }, v.term.cellAt(1, 0).fg);
    try std.testing.expect(v.term.cellAt(1, 0).flags.bold);
}

test "pty child starts in requested working directory" {
    const alloc = std.testing.allocator;
    var pty = try Pty.spawn(alloc, .{
        .argv = &.{ "/bin/sh", "-c", "pwd -P" },
        .cwd = "/tmp",
    });
    defer {
        pty.hangup();
        pty.wait();
        pty.closeFd();
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(alloc);
    var buf: [256]u8 = undefined;
    while (true) {
        const n = pty.read(&buf);
        if (n == 0) break;
        try output.appendSlice(alloc, buf[0..n]);
    }
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/tmp") != null);
}

test "pty reports foreground process working directory" {
    const alloc = std.testing.allocator;
    var pty = try Pty.spawn(alloc, .{
        .argv = &.{ "/bin/sh", "-c", "cd /tmp && printf ready && sleep 30" },
    });
    defer {
        pty.hangup();
        pty.wait();
        pty.closeFd();
    }

    var ready: [5]u8 = undefined;
    var received: usize = 0;
    while (received < ready.len) {
        const n = pty.read(ready[received..]);
        if (n == 0) return error.ChildExitedEarly;
        received += n;
    }
    try std.testing.expectEqualStrings("ready", &ready);

    var cwd_buf: [max_path_len]u8 = undefined;
    const cwd = pty.foregroundWorkingDirectory(&cwd_buf) orelse
        return error.WorkingDirectoryUnavailable;
    try std.testing.expect(std.mem.endsWith(u8, cwd, "/tmp"));
}
