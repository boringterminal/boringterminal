//! Cell color model and the xterm 256-color palette. Cells store the
//! *semantic* color (default / indexed / rgb); the renderer resolves it
//! against the theme at draw time so SGR state never bakes in theme RGB.

const std = @import("std");

pub const RGB = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn eql(a: RGB, b_: RGB) bool {
        return a.r == b_.r and a.g == b_.g and a.b == b_.b;
    }
};

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: RGB,
};

/// One source of truth for the effective terminal colors. The renderer uses
/// these values for pixels and OSC 10/11/12 reports them to applications.
pub const Scheme = struct {
    bg: RGB,
    fg: RGB,
    cursor: RGB,
    selection: RGB,
    search_match: RGB,
    search_selected: RGB,
    ansi: [16]RGB,
};

pub const default_scheme: Scheme = .{
    .bg = .{ .r = 0x10, .g = 0x14, .b = 0x18 },
    .fg = .{ .r = 0xd4, .g = 0xd8, .b = 0xde },
    .cursor = .{ .r = 0xd4, .g = 0xd8, .b = 0xde },
    .selection = .{ .r = 0x2c, .g = 0x3d, .b = 0x54 },
    .search_match = .{ .r = 0x45, .g = 0x3d, .b = 0x2b },
    .search_selected = .{ .r = 0x78, .g = 0x5d, .b = 0x29 },
    .ansi = .{
        .{ .r = 0x15, .g = 0x19, .b = 0x1e },
        .{ .r = 0xe0, .g = 0x55, .b = 0x61 },
        .{ .r = 0x8c, .g = 0xc2, .b = 0x65 },
        .{ .r = 0xd1, .g = 0x8f, .b = 0x52 },
        .{ .r = 0x4a, .g = 0xa5, .b = 0xf0 },
        .{ .r = 0xc1, .g = 0x62, .b = 0xde },
        .{ .r = 0x42, .g = 0xb3, .b = 0xc2 },
        .{ .r = 0xd7, .g = 0xda, .b = 0xe0 },
        .{ .r = 0x4f, .g = 0x56, .b = 0x66 },
        .{ .r = 0xff, .g = 0x61, .b = 0x6e },
        .{ .r = 0xa5, .g = 0xe0, .b = 0x75 },
        .{ .r = 0xf0, .g = 0xa4, .b = 0x5d },
        .{ .r = 0x4d, .g = 0xc4, .b = 0xff },
        .{ .r = 0xde, .g = 0x73, .b = 0xff },
        .{ .r = 0x4c, .g = 0xd1, .b = 0xe0 },
        .{ .r = 0xe6, .g = 0xe6, .b = 0xe6 },
    },
};

/// Standard xterm 256-color table for indexes 16..255: 6x6x6 cube then a
/// 24-step grayscale ramp. 0..15 are theme-owned; callers resolve those
/// through the theme's ANSI table, not here.
pub fn cube256(idx: u8) RGB {
    std.debug.assert(idx >= 16);
    if (idx < 232) {
        const i = idx - 16;
        const steps = [_]u8{ 0, 95, 135, 175, 215, 255 };
        return .{
            .r = steps[i / 36],
            .g = steps[(i / 6) % 6],
            .b = steps[i % 6],
        };
    }
    const level: u8 = 8 + @as(u8, idx - 232) * 10;
    return .{ .r = level, .g = level, .b = level };
}

test "cube corners and grayscale" {
    try std.testing.expectEqual(RGB{ .r = 0, .g = 0, .b = 0 }, cube256(16));
    try std.testing.expectEqual(RGB{ .r = 255, .g = 255, .b = 255 }, cube256(231));
    try std.testing.expectEqual(RGB{ .r = 0, .g = 0, .b = 95 }, cube256(17));
    try std.testing.expectEqual(RGB{ .r = 8, .g = 8, .b = 8 }, cube256(232));
    try std.testing.expectEqual(RGB{ .r = 238, .g = 238, .b = 238 }, cube256(255));
}
