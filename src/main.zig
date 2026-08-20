//! Boring Terminal viewer entry point. The AppKit/Metal process attaches to
//! daemon-owned PTY/VT sessions through src/shell/daemon_client.zig.

const std = @import("std");
const window = @import("shell/window.zig");

pub fn main(init: std.process.Init) !void {
    try window.run(init.gpa, init.io, init.environ_map);
}
