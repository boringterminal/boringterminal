//! Single-writer, crash-consistent recovery storage. No terminal contents.
const std = @import("std");
const model = @import("recovery.zig");
const c = std.c;

pub const Fault = enum { none, before_write, after_partial_write, after_write, after_file_sync, after_rename };
const temporary_name = ".recovery-write.tmp";
pub const Store = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    directory: c.fd_t,
    lock: c.fd_t,
    document: model.Document,
    fault: Fault = .none,

    /// Caller also owns the daemon socket before loading/mutating records.
    /// This lock is acquired before bind to serialize new daemon contenders;
    /// an older live socket owner still wins even though it has no file lock.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, directory: []const u8) !Store {
        const path = try gpa.dupeZ(u8, directory);
        defer gpa.free(path);
        const dir = c.open(path.ptr, .{ .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true });
        if (dir < 0) return error.RecoveryOpen;
        errdefer _ = c.close(dir);
        var stat: c.Stat = undefined;
        if (c.fstat(dir, &stat) != 0 or stat.uid != c.getuid() or stat.mode & 0o077 != 0)
            return error.RecoveryPermissions;
        const lock = c.openat(dir, "recovery.lock", .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
        }, @as(c.mode_t, 0o600));
        if (lock < 0) return error.RecoveryOpen;
        errdefer _ = c.close(lock);
        try checkFile(lock);
        if (c.flock(lock, c.LOCK.EX | c.LOCK.NB) != 0) return error.RecoveryWriterBusy;
        return .{
            .gpa = gpa,
            .io = io,
            .directory = dir,
            .lock = lock,
            .document = try model.Document.init(gpa),
        };
    }

    pub fn deinit(self: *Store) void {
        self.document.deinit();
        _ = c.close(self.lock);
        _ = c.close(self.directory);
        self.* = undefined;
    }

    /// Future formats and unsafe paths are preserved, never treated as an
    /// empty workspace. A corrupt primary may fall back to one known-good copy.
    pub fn load(self: *Store) !void {
        const primary = self.readDocument("recovery.json") catch |err| switch (err) {
            error.UnsupportedRecoveryVersion, error.RecoveryPermissions, error.RecoveryOpen => return err,
            else => null,
        };
        if (primary) |doc| {
            self.document.deinit();
            self.document = doc;
            return;
        }
        if (try self.readDocument("recovery.previous.json")) |doc| {
            self.document.deinit();
            self.document = doc;
        } else {
            // If neither copy exists this is a first launch. A malformed
            // primary without a backup is an error, not permission to erase it.
            if (try self.exists("recovery.json")) return error.InvalidRecovery;
        }
    }

    pub fn commit(self: *Store, state: model.State, scrub_previous: bool) !void {
        var next = try model.Document.copy(self.gpa, state);
        var next_owned = true;
        defer if (next_owned) next.deinit();
        next.state.revision = std.math.add(u64, self.document.state.revision, 1) catch
            return error.RecoveryRevisionOverflow;
        const bytes = try next.encode(self.gpa);
        defer self.gpa.free(bytes);
        if (!scrub_previous) {
            const previous = try self.document.encode(self.gpa);
            defer self.gpa.free(previous);
            try self.replace("recovery.previous.json", previous, false);
        }
        try self.replace("recovery.json", bytes, true);
        // Keep the in-memory transaction unchanged until both writes succeed.
        // If sync fails after rename, disk may hold old or new intent; either
        // becomes pending on next startup. The caller can safely retry here.
        if (scrub_previous) try self.replace("recovery.previous.json", bytes, false);
        self.document.deinit();
        self.document = next;
        next_owned = false;
    }

    fn readDocument(self: *Store, name: [*:0]const u8) !?model.Document {
        const fd = c.openat(self.directory, name, .{ .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true });
        if (fd < 0) {
            if (c.errno(fd) == .NOENT) return null;
            return error.RecoveryOpen;
        }
        defer _ = c.close(fd);
        try checkFile(fd);
        var stat: c.Stat = undefined;
        if (c.fstat(fd, &stat) != 0 or stat.size < 0) return error.RecoveryRead;
        if (stat.size > model.max_file_bytes) return error.RecoveryLimit;
        const bytes = try self.gpa.alloc(u8, @intCast(stat.size));
        defer self.gpa.free(bytes);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = c.read(fd, bytes[offset..].ptr, bytes.len - offset);
            if (n < 0 and c.errno(n) == .INTR) continue;
            if (n <= 0) return error.RecoveryRead;
            offset += @intCast(n);
        }
        var extra: [1]u8 = undefined;
        if (c.read(fd, &extra, 1) != 0) return error.RecoveryRead;
        return try model.Document.decode(self.gpa, bytes);
    }

    fn exists(self: *Store, name: [*:0]const u8) !bool {
        var stat: c.Stat = undefined;
        if (c.fstatat(self.directory, name, &stat, c.AT.SYMLINK_NOFOLLOW) == 0) return true;
        if (c.errno(-1) == .NOENT) return false;
        return error.RecoveryRead;
    }

    fn replace(self: *Store, name: [*:0]const u8, bytes: []const u8, inject_fault: bool) !void {
        // Existing symlinks/non-regular files are an error, even though rename
        // would replace the directory entry rather than following its target.
        if (try self.exists(name)) {
            const existing = c.openat(self.directory, name, .{ .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true });
            if (existing < 0) return error.RecoveryOpen;
            defer _ = c.close(existing);
            try checkFile(existing);
        }
        // Sole writer ownership makes one reserved temporary sufficient. A
        // process kill may leave it behind; never treat it as a saved generation.
        if (try self.exists(temporary_name)) {
            const abandoned = c.openat(self.directory, temporary_name, .{ .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true });
            if (abandoned < 0) return error.RecoveryOpen;
            defer _ = c.close(abandoned);
            try checkFile(abandoned);
            if (c.unlinkat(self.directory, temporary_name, 0) != 0) return error.RecoveryWrite;
        }
        const fd = c.openat(self.directory, temporary_name, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .NOFOLLOW = true,
            .CLOEXEC = true,
        }, @as(c.mode_t, 0o600));
        if (fd < 0) return error.RecoveryWrite;
        defer _ = c.close(fd);
        defer _ = c.unlinkat(self.directory, temporary_name, 0);
        try self.inject(.before_write, inject_fault);
        self.killPoint(name, .before_write);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const remaining = bytes.len - offset;
            const write_len = if (comptime @hasDecl(@import("root"), "storePublicationPoint")) @min(remaining, 32) else remaining;
            const n = c.write(fd, bytes[offset..].ptr, write_len);
            if (n < 0 and c.errno(n) == .INTR) continue;
            if (n <= 0) return error.RecoveryWrite;
            offset += @intCast(n);
            if (offset < bytes.len) self.killPoint(name, .after_partial_write);
        }
        try self.inject(.after_write, inject_fault);
        self.killPoint(name, .after_write);
        // fsync alone does not flush a disk's own write cache on Darwin.
        while (c.fcntl(fd, c.F.FULLFSYNC) != 0) {
            if (c.errno(-1) == .INTR) continue;
            return error.RecoverySync;
        }
        try self.inject(.after_file_sync, inject_fault);
        self.killPoint(name, .after_file_sync);
        if (c.renameat(self.directory, temporary_name, self.directory, name) != 0)
            return error.RecoveryWrite;
        try self.inject(.after_rename, inject_fault);
        self.killPoint(name, .after_rename);
        while (c.fsync(self.directory) != 0) {
            if (c.errno(-1) == .INTR) continue;
            return error.RecoverySync;
        }
    }

    fn inject(self: *Store, point: Fault, enabled: bool) !void {
        if (enabled and self.fault == point) return error.RecoveryInjectedFailure;
    }

    fn killPoint(self: *Store, name: [*:0]const u8, point: Fault) void {
        if (comptime @hasDecl(@import("root"), "storePublicationPoint"))
            @import("root").storePublicationPoint(self.io, name, point);
    }
};

fn checkFile(fd: c.fd_t) !void {
    var stat: c.Stat = undefined;
    if (c.fstat(fd, &stat) != 0 or !c.S.ISREG(stat.mode) or
        stat.uid != c.getuid() or stat.mode & 0o077 != 0 or stat.nlink != 1)
        return error.RecoveryPermissions;
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    path: []u8,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.testing.allocator.dupe(u8, buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)]);
        const z = try std.testing.allocator.dupeZ(u8, path);
        defer std.testing.allocator.free(z);
        if (c.chmod(z.ptr, 0o700) != 0) return error.RecoveryPermissions;
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(self: *Fixture) void {
        std.testing.allocator.free(self.path);
        self.tmp.cleanup();
    }
};

const sample: model.State = .{
    .current = .{ .entries = &.{.{ .id = 1, .cwd = "/tmp" }}, .items = &.{.{ .left = 1 }} },
};

test "recovery writer exclusion and primary-empty precedence" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try Store.open(std.testing.allocator, std.testing.io, fixture.path);
    defer store.deinit();
    try store.load();
    try std.testing.expectError(error.RecoveryWriterBusy, Store.open(std.testing.allocator, std.testing.io, fixture.path));
    try store.commit(sample, false);
    try store.commit(.{}, false);
    try store.load();
    try std.testing.expectEqual(@as(usize, 0), store.document.state.current.entries.len);
}

test "abandoned temporary cleanup rejects symlinks and multiply linked files" {
    for ([_]bool{ false, true }) |hard_link| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        var store = try Store.open(std.testing.allocator, std.testing.io, fixture.path);
        defer store.deinit();
        try store.commit(sample, false);
        if (hard_link) {
            try std.testing.expectEqual(@as(c_int, 0), c.linkat(store.directory, "recovery.json", store.directory, temporary_name, 0));
        } else {
            try std.testing.expectEqual(@as(c_int, 0), c.symlinkat("recovery.json", store.directory, temporary_name));
        }
        try std.testing.expectError(if (hard_link) error.RecoveryPermissions else error.RecoveryOpen, store.commit(.{}, true));
        try std.testing.expect(try store.exists(temporary_name));
        try std.testing.expectEqual(@as(c_int, 0), c.unlinkat(store.directory, temporary_name, 0));
        try store.load();
        try std.testing.expectEqual(@as(usize, 1), store.document.state.current.entries.len);
    }
}

test "recovery failure at every publication stage leaves a complete generation" {
    inline for (.{ Fault.before_write, Fault.after_write, Fault.after_file_sync, Fault.after_rename }) |fault| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        var store = try Store.open(std.testing.allocator, std.testing.io, fixture.path);
        defer store.deinit();
        try store.commit(sample, false);
        store.fault = fault;
        try std.testing.expectError(error.RecoveryInjectedFailure, store.commit(.{}, false));
        try store.load();
        try std.testing.expectEqual(@as(usize, if (fault == .after_rename) 0 else 1), store.document.state.current.entries.len);
    }
}

test "failed backup scrub preserves memory intent and reconciliation repairs primary" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try Store.open(std.testing.allocator, std.testing.io, fixture.path);
    defer store.deinit();
    try store.commit(sample, false);
    // Primary replacement succeeds, but scrubbing the backup is rejected.
    try std.testing.expectEqual(@as(c_int, 0), c.unlinkat(store.directory, "recovery.previous.json", 0));
    try std.testing.expectEqual(@as(c_int, 0), c.symlinkat("/nonexistent-test-backup", store.directory, "recovery.previous.json"));
    try std.testing.expectError(error.RecoveryOpen, store.commit(.{}, true));
    try std.testing.expectEqual(@as(usize, 1), store.document.state.current.entries.len);
    var published = (try store.readDocument("recovery.json")).?;
    defer published.deinit();
    try std.testing.expectEqual(@as(usize, 0), published.state.current.entries.len);
    try std.testing.expectEqual(@as(c_int, 0), c.unlinkat(store.directory, "recovery.previous.json", 0));
    try store.commit(store.document.state, false);
    try store.load();
    try std.testing.expectEqual(@as(usize, 1), store.document.state.current.entries.len);
    var backup = (try store.readDocument("recovery.previous.json")).?;
    defer backup.deinit();
    try std.testing.expectEqual(@as(usize, 1), backup.state.current.entries.len);
}

test "recovery corrupt primary falls back but future format and unsafe files do not" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try Store.open(std.testing.allocator, std.testing.io, fixture.path);
    defer store.deinit();
    try store.commit(sample, true);
    const fd = c.openat(store.directory, "recovery.json", .{ .ACCMODE = .WRONLY, .TRUNC = true, .CLOEXEC = true });
    try std.testing.expect(fd >= 0);
    _ = c.write(fd, "{", 1);
    _ = c.close(fd);
    try store.load();
    try std.testing.expectEqual(@as(usize, 1), store.document.state.current.entries.len);
    const future = "{\"format_version\":999}";
    try store.replace("recovery.json", future, false);
    try std.testing.expectError(error.UnsupportedRecoveryVersion, store.load());
    _ = c.unlinkat(store.directory, "recovery.json", 0);
    try std.testing.expectEqual(@as(c_int, 0), c.symlinkat("recovery.previous.json", store.directory, "recovery.json"));
    try std.testing.expectError(error.RecoveryOpen, store.load());
}

test "durable dismissal scrubs backup and cannot be resurrected by primary corruption" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try Store.open(std.testing.allocator, std.testing.io, fixture.path);
    defer store.deinit();
    try store.commit(sample, true);
    try store.commit(.{}, true);
    try store.replace("recovery.json", "{", false);
    try store.load();
    try std.testing.expectEqual(@as(usize, 0), store.document.state.current.entries.len);
}
