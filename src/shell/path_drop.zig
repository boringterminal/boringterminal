//! Pure Finder-path formatting for RFC 0005 drag and drop.

const std = @import("std");

pub const max_payload_bytes: usize = 1024 * 1024;

pub fn format(alloc: std.mem.Allocator, paths: []const []const u8) ![]u8 {
    if (paths.len == 0) return error.NoPaths;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (paths, 0..) |path, index| {
        try validate(path);
        if (index != 0) try appendBounded(&out, alloc, " ");
        if (isShellSafe(path)) {
            try appendBounded(&out, alloc, path);
            continue;
        }

        try appendBounded(&out, alloc, "'");
        var start: usize = 0;
        for (path, 0..) |byte, offset| {
            if (byte != '\'') continue;
            try appendBounded(&out, alloc, path[start..offset]);
            try appendBounded(&out, alloc, "'\\''");
            start = offset + 1;
        }
        try appendBounded(&out, alloc, path[start..]);
        try appendBounded(&out, alloc, "'");
    }
    return out.toOwnedSlice(alloc);
}

fn appendBounded(out: *std.ArrayList(u8), alloc: std.mem.Allocator, bytes: []const u8) !void {
    if (bytes.len > max_payload_bytes - out.items.len) return error.PayloadTooLarge;
    try out.appendSlice(alloc, bytes);
}

fn validate(path: []const u8) !void {
    if (path.len == 0 or path[0] != '/') return error.InvalidPath;
    if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidPath;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidPath;
}

fn isShellSafe(path: []const u8) bool {
    for (path) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '@', '%', '+', '=', ':', ',', '.', '/', '-' => {},
        else => return false,
    };
    return true;
}

test "safe dropped paths remain readable" {
    const paths = [_][]const u8{ "/Users/test/project", "/tmp/a-b_1.txt" };
    const result = try format(std.testing.allocator, &paths);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/Users/test/project /tmp/a-b_1.txt", result);
}

test "dropped paths quote shell metacharacters and apostrophes" {
    const paths = [_][]const u8{
        "/Users/test/my file (1).txt",
        "/tmp/$(touch nope);it's.txt",
        "/tmp/界.txt",
    };
    const result = try format(std.testing.allocator, &paths);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        "'/Users/test/my file (1).txt' '/tmp/$(touch nope);it'\\''s.txt' '/tmp/界.txt'",
        result,
    );
}

test "invalid dropped paths fail atomically" {
    const relative = [_][]const u8{"relative.txt"};
    try std.testing.expectError(error.InvalidPath, format(std.testing.allocator, &relative));

    const newline = [_][]const u8{"/tmp/a\nb"};
    try std.testing.expectError(error.InvalidPath, format(std.testing.allocator, &newline));

    const malformed_bytes = [_]u8{ '/', 0xff };
    const malformed = [_][]const u8{&malformed_bytes};
    try std.testing.expectError(error.InvalidPath, format(std.testing.allocator, &malformed));
}

test "dropped path payload is bounded" {
    const oversized = try std.testing.allocator.alloc(u8, max_payload_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'a');
    oversized[0] = '/';
    const paths = [_][]const u8{oversized};
    try std.testing.expectError(error.PayloadTooLarge, format(std.testing.allocator, &paths));
}
