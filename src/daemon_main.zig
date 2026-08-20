//! Standalone PTY/VT owner for RFC 0012.

const std = @import("std");
const server = @import("daemon/server.zig");

pub fn main(init: std.process.Init) !void {
    const ignore_hup: std.posix.Sigaction = .{
        .handler = .{ .handler = @ptrFromInt(1) }, // POSIX SIG_IGN
        .mask = 0,
        .flags = 0,
    };
    std.posix.sigaction(.HUP, &ignore_hup, null);
    const home = init.environ_map.get("HOME") orelse return error.HomeNotSet;
    try std.process.setCurrentPath(init.io, home);
    try server.run(init.gpa, init.io, init.environ_map);
}
