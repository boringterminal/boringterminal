//! Uninstalled subprocess entrypoint for deterministic activation race tests.
const std = @import("std");
const store_mod = @import("daemon/recovery_store.zig");
var store_kill_point: ?[]const u8 = null;
var store_kill_target: ?[]const u8 = null;

pub fn main(init: std.process.Init) !void {
    if (init.environ_map.get("BT_TEST_STORE_KILL_POINT")) |point| {
        const home = init.environ_map.get("HOME") orelse return error.MissingTestHome;
        if (!std.mem.startsWith(u8, home, "/tmp/btr-")) return error.UnsafeTestHome;
        var store = try store_mod.Store.open(init.gpa, init.io, home);
        defer store.deinit();
        try store.commit(.{ .current = .{
            .entries = &.{ .{ .id = 1 }, .{ .id = 2 } },
            .items = &.{.{ .left = 1, .right = 2, .focus_right = true, .zoomed = true }},
            .selected = 2,
        } }, false);
        store_kill_point = point;
        store_kill_target = init.environ_map.get("BT_TEST_STORE_KILL_TARGET").?;
        try store.commit(.{}, init.environ_map.get("BT_TEST_STORE_SCRUB") != null);
        return error.KillPointNotReached;
    }
    try @import("daemon_main.zig").main(init);
}

pub fn storePublicationPoint(_: std.Io, name: [*:0]const u8, point: store_mod.Fault) void {
    const wanted = store_kill_point orelse return;
    if (!std.mem.eql(u8, wanted, @tagName(point)) or
        !std.mem.eql(u8, std.mem.span(name), store_kill_target.?)) return;
    _ = std.c.kill(std.c.getpid(), .KILL);
    std.process.exit(99); // Test must observe SIGKILL, never normal unwinding.
}

pub fn activationGate(io: std.Io, env: *const std.process.Environ.Map, stage: []const u8, pid: ?std.c.pid_t) !void {
    const requested = env.get("BT_TEST_ACTIVATION_STAGE") orelse return;
    if (!std.mem.eql(u8, requested, stage)) return;
    const home = env.get("HOME") orelse return error.MissingTestHome;
    if (!std.mem.startsWith(u8, home, "/tmp/btr-")) return error.UnsafeTestHome;
    var directory = try std.Io.Dir.openDirAbsolute(io, home, .{});
    defer directory.close(io);
    if (pid) |child| {
        var buf: [32]u8 = undefined;
        try directory.writeFile(io, .{ .sub_path = "activation-child", .data = try std.fmt.bufPrint(&buf, "{d}", .{child}) });
    }
    try directory.writeFile(io, .{ .sub_path = "activation-ready", .data = stage });
    for (0..1000) |_| {
        directory.access(io, "activation-release", .{}) catch {
            try io.sleep(.fromMilliseconds(10), .awake);
            continue;
        };
        return;
    }
    return error.ActivationGateTimeout;
}

pub fn activationFinished(io: std.Io, env: *const std.process.Environ.Map) void {
    if (env.get("BT_TEST_ACTIVATION_STAGE") == null) return;
    const home = env.get("HOME") orelse return;
    if (!std.mem.startsWith(u8, home, "/tmp/btr-")) return;
    var directory = std.Io.Dir.openDirAbsolute(io, home, .{}) catch return;
    defer directory.close(io);
    directory.writeFile(io, .{ .sub_path = "activation-finished", .data = "" }) catch {};
}
