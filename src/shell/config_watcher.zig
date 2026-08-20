//! macOS vnode watcher for RFC 0013 config hot reload. The current file inode
//! catches in-place writes; its directory catches atomic rename-based saves.

const std = @import("std");
const c = std.c;

pub const Callback = *const fn (?*anyopaque) void;
const stop_event_ident: usize = 1;

pub const Watcher = struct {
    alloc: std.mem.Allocator,
    directory_fd: c.fd_t,
    file_fd: c.fd_t,
    kq: c.fd_t,
    config_path: [:0]u8,
    callback: Callback,
    context: ?*anyopaque,
    thread: std.Thread,

    pub fn create(
        alloc: std.mem.Allocator,
        directory_path: []const u8,
        config_path: []const u8,
        context: ?*anyopaque,
        callback: Callback,
    ) !*Watcher {
        const path_z = try alloc.dupeZ(u8, directory_path);
        defer alloc.free(path_z);
        const directory_fd = c.open(path_z.ptr, .{ .EVTONLY = true, .CLOEXEC = true });
        if (directory_fd < 0) return error.ConfigWatchOpenFailed;
        errdefer _ = c.close(directory_fd);
        const config_path_z = try alloc.dupeZ(u8, config_path);
        errdefer alloc.free(config_path_z);

        const kq = c.kqueue();
        if (kq < 0) return error.ConfigWatchCreateFailed;
        errdefer _ = c.close(kq);
        if (c.fcntl(kq, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0)
            return error.ConfigWatchCreateFailed;

        const changes = [_]c.Kevent{
            makeKevent(
                @intCast(directory_fd),
                c.EVFILT.VNODE,
                c.EV.ADD | c.EV.ENABLE | c.EV.CLEAR,
                c.NOTE.WRITE | c.NOTE.EXTEND | c.NOTE.ATTRIB | c.NOTE.RENAME | c.NOTE.DELETE,
            ),
            makeKevent(stop_event_ident, c.EVFILT.USER, c.EV.ADD | c.EV.ENABLE | c.EV.CLEAR, 0),
        };
        if (!submit(kq, &changes)) return error.ConfigWatchCreateFailed;

        const file_fd = openWatchedFile(config_path_z);
        errdefer {
            if (file_fd >= 0) _ = c.close(file_fd);
        }
        if (file_fd >= 0 and !submit(kq, &.{fileEvent(file_fd)}))
            return error.ConfigWatchCreateFailed;

        const self = try alloc.create(Watcher);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .directory_fd = directory_fd,
            .file_fd = file_fd,
            .kq = kq,
            .config_path = config_path_z,
            .callback = callback,
            .context = context,
            .thread = undefined,
        };
        self.thread = try std.Thread.spawn(.{}, watchLoop, .{self});
        return self;
    }

    pub fn destroy(self: *Watcher) void {
        _ = submit(self.kq, &.{makeKevent(
            stop_event_ident,
            c.EVFILT.USER,
            0,
            c.NOTE.TRIGGER,
        )});
        self.thread.join();
        if (self.file_fd >= 0) _ = c.close(self.file_fd);
        _ = c.close(self.kq);
        _ = c.close(self.directory_fd);
        const alloc = self.alloc;
        alloc.free(self.config_path);
        alloc.destroy(self);
    }

    fn watchLoop(self: *Watcher) void {
        var events: [4]c.Kevent = undefined;
        while (wait(self.kq, &events)) |count| {
            for (events[0..count]) |event| {
                if (event.flags & c.EV.ERROR != 0) return;
                if (event.filter == c.EVFILT.USER and event.ident == stop_event_ident) return;
                if (event.filter != c.EVFILT.VNODE) continue;
                if (event.ident == @as(usize, @intCast(self.directory_fd))) {
                    self.rearmFile();
                    self.callback(self.context);
                } else if (self.file_fd >= 0 and event.ident == @as(usize, @intCast(self.file_fd))) {
                    self.callback(self.context);
                    if (event.fflags & (c.NOTE.DELETE | c.NOTE.RENAME | c.NOTE.REVOKE) != 0)
                        self.rearmFile();
                }
            }
        }
    }

    /// Thread-owned. Closing the old descriptor also removes its kqueue
    /// registration; the replacement inode, if present, gets a fresh one.
    fn rearmFile(self: *Watcher) void {
        if (self.file_fd >= 0) _ = c.close(self.file_fd);
        self.file_fd = openWatchedFile(self.config_path);
        if (self.file_fd >= 0 and !submit(self.kq, &.{fileEvent(self.file_fd)})) {
            _ = c.close(self.file_fd);
            self.file_fd = -1;
        }
    }
};

fn openWatchedFile(path: [*:0]const u8) c.fd_t {
    return c.open(path, .{ .EVTONLY = true, .CLOEXEC = true });
}

fn fileEvent(fd: c.fd_t) c.Kevent {
    return makeKevent(
        @intCast(fd),
        c.EVFILT.VNODE,
        c.EV.ADD | c.EV.ENABLE | c.EV.CLEAR,
        c.NOTE.WRITE | c.NOTE.EXTEND | c.NOTE.ATTRIB | c.NOTE.RENAME | c.NOTE.DELETE | c.NOTE.REVOKE,
    );
}

fn makeKevent(ident: usize, filter: i16, flags: u16, fflags: u32) c.Kevent {
    return .{
        .ident = ident,
        .filter = filter,
        .flags = flags,
        .fflags = fflags,
        .data = 0,
        .udata = 0,
    };
}

fn submit(kq: c.fd_t, changes: []const c.Kevent) bool {
    var ignored: [1]c.Kevent = undefined;
    while (true) {
        const rc = c.kevent(kq, changes.ptr, @intCast(changes.len), &ignored, 0, null);
        if (rc >= 0) return true;
        if (c.errno(rc) != .INTR) return false;
    }
}

fn wait(kq: c.fd_t, events: []c.Kevent) ?usize {
    var ignored: [1]c.Kevent = undefined;
    while (true) {
        const rc = c.kevent(kq, &ignored, 0, events.ptr, @intCast(events.len), null);
        if (rc >= 0) return @intCast(rc);
        if (c.errno(rc) != .INTR) return null;
    }
}

test "watcher observes atomic replacement and in-place config writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);

    const config_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..path_len], "config" });
    defer std.testing.allocator.free(config_path);

    const State = struct {
        changes: std.atomic.Value(usize) = .init(0),

        fn notify(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            _ = self.changes.fetchAdd(1, .acq_rel);
        }
    };
    var state: State = .{};
    const watcher = try Watcher.create(
        std.testing.allocator,
        path_buf[0..path_len],
        config_path,
        &state,
        State.notify,
    );
    defer watcher.destroy();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.tmp", .data = "font-size=14\n" });
    try tmp.dir.rename("config.tmp", tmp.dir, "config", std.testing.io);
    var attempts: usize = 0;
    while (state.changes.load(.acquire) == 0 and attempts < 100) : (attempts += 1)
        try std.testing.io.sleep(.fromMilliseconds(10), .awake);
    try std.testing.expect(state.changes.load(.acquire) > 0);

    // Let the atomic-save event burst settle before proving the separate file
    // descriptor observes a write that does not alter the directory entries.
    try std.testing.io.sleep(.fromMilliseconds(50), .awake);
    const before = state.changes.load(.acquire);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config", .data = "font-size=15\n" });
    attempts = 0;
    while (state.changes.load(.acquire) == before and attempts < 100) : (attempts += 1)
        try std.testing.io.sleep(.fromMilliseconds(10), .awake);
    try std.testing.expect(state.changes.load(.acquire) > before);
}
