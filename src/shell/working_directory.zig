//! Host policy for untrusted OSC 7 reports (RFC 0020).

const std = @import("std");
const pty = @import("pty.zig");
const vt = @import("../vt.zig");

pub const Report = union(enum) {
    clear,
    path: []const u8,
    invalid,
};

pub fn decode(uri_bytes: []const u8, local_hostname: []const u8, out: *[pty.max_path_len]u8) Report {
    if (uri_bytes.len == 0) return .clear;
    if (uri_bytes.len > vt.terminal.max_cwd_uri_bytes or
        !validPercentEscapes(uri_bytes)) return .invalid;

    const uri = std.Uri.parse(uri_bytes) catch return .invalid;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "file") or
        uri.user != null or uri.password != null or uri.port != null or
        uri.query != null or uri.fragment != null) return .invalid;

    const colon = std.mem.indexOfScalar(u8, uri_bytes, ':') orelse return .invalid;
    if (!std.mem.startsWith(u8, uri_bytes[colon + 1 ..], "//")) return .invalid;
    if (uri.host) |host_component| {
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = host_component.toRaw(&host_buf) catch return .invalid;
        if (host.len != 0 and !std.ascii.eqlIgnoreCase(host, "localhost") and
            !std.ascii.eqlIgnoreCase(host, local_hostname)) return .invalid;
    }

    const path = uri.path.toRaw(out) catch return .invalid;
    if (path.len == 0 or path[0] != '/') return .invalid;
    for (path) |byte| if (byte == 0 or byte < 0x20 or byte == 0x7f) return .invalid;
    return .{ .path = path };
}

fn validPercentEscapes(bytes: []const u8) bool {
    var index: usize = 0;
    while (index < bytes.len) : (index += 1) {
        if (bytes[index] != '%') continue;
        if (index + 2 >= bytes.len or !std.ascii.isHex(bytes[index + 1]) or
            !std.ascii.isHex(bytes[index + 2])) return false;
        index += 2;
    }
    return true;
}

pub fn isDirectory(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

test "OSC 7 accepts only local absolute file URIs" {
    var out: [pty.max_path_len]u8 = undefined;
    try std.testing.expectEqualStrings("/tmp/a", decode("file:///tmp/a", "my-mac", &out).path);
    try std.testing.expectEqualStrings("/tmp/a b", decode("file://localhost/tmp/a%20b", "my-mac", &out).path);
    try std.testing.expectEqualStrings("/tmp/a", decode("FILE://my-mac/tmp/a", "MY-MAC", &out).path);
    try std.testing.expect(decode("", "my-mac", &out) == .clear);
    try std.testing.expect(decode("file://remote/tmp/a", "my-mac", &out) == .invalid);
    try std.testing.expect(decode("file:/tmp/a", "my-mac", &out) == .invalid);
    try std.testing.expect(decode("https://localhost/tmp/a", "my-mac", &out) == .invalid);
    try std.testing.expect(decode("file://user@localhost/tmp/a", "my-mac", &out) == .invalid);
    try std.testing.expect(decode("file:///tmp/a?x", "my-mac", &out) == .invalid);
    try std.testing.expect(decode("file:///tmp/a%0Aevil", "my-mac", &out) == .invalid);
    try std.testing.expect(decode("file:///tmp/%", "my-mac", &out) == .invalid);
}

test "OSC 7 directory validation rejects files and missing paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file", .data = "x" });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var file_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = file_buf[0..try tmp.dir.realPathFile(std.testing.io, "file", &file_buf)];
    try std.testing.expect(isDirectory(std.testing.io, dir_path));
    try std.testing.expect(!isDirectory(std.testing.io, file_path));
    try std.testing.expect(!isDirectory(std.testing.io, "/definitely/not/a/boring-terminal-directory"));
}
