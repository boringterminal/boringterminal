//! Pure geometry for RFC 0006's native vertical session rail.

const std = @import("std");

pub const default_width: f32 = 160;
pub const min_width: f32 = 140;
pub const max_width: f32 = 280;
pub const divider_hit_width: f32 = 9;
pub const row_height: f32 = 28;
pub const row_pitch: f32 = 30;
pub const top_padding: f32 = 4;
pub const bottom_padding: f32 = 4;
pub const horizontal_padding: f32 = 6;

pub fn preferredWidth(value: f32) f32 {
    if (!std.math.isFinite(value)) return default_width;
    return std.math.clamp(value, min_width, max_width);
}

/// Preserve the user's bounded preference while temporarily yielding enough
/// room for the terminal's minimum grid in a narrow window.
pub fn effectiveWidth(preferred: f32, content_width: f32, terminal_min_width: f32) f32 {
    const available = @max(0, content_width - terminal_min_width);
    return @min(preferredWidth(preferred), available);
}

pub fn contentHeight(viewport_height: f32, session_count: usize) f32 {
    if (session_count == 0) return viewport_height;
    const final_row: f32 = @floatFromInt(session_count - 1);
    const rows_height = top_padding + row_height + row_pitch * final_row + bottom_padding;
    return @max(viewport_height, rows_height);
}

/// The document view is flipped, so positive Y proceeds down from the top.
pub fn rowY(index: usize) f32 {
    return top_padding + row_pitch * @as(f32, @floatFromInt(index));
}

/// Only the first nine positions have real macOS command-key accelerators.
/// Derive this from the current position because closing a preceding session
/// reindexes every surviving row.
pub fn shortcutLabel(index: usize, out: []u8) []const u8 {
    if (index >= 9) return "";
    return std.fmt.bufPrint(out, "⌘{d}", .{index + 1}) catch "";
}

test "overflow rows retain pitch inside a taller scroll document" {
    const viewport: f32 = 360;
    const count: usize = 15;
    const height = contentHeight(viewport, count);
    try std.testing.expect(height > viewport);
    try std.testing.expectEqual(row_pitch, rowY(14) - rowY(13));
    try std.testing.expect(rowY(count - 1) + row_height + bottom_padding <= height);
}

test "short session lists do not create needless scroll range" {
    try std.testing.expectEqual(@as(f32, 360), contentHeight(360, 3));
    try std.testing.expectEqual(top_padding, rowY(0));
}

test "shortcut labels stop at command nine and follow current position" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("⌘1", shortcutLabel(0, &buf));
    try std.testing.expectEqualStrings("⌘9", shortcutLabel(8, &buf));
    try std.testing.expectEqualStrings("", shortcutLabel(9, &buf));
    try std.testing.expectEqualStrings("", shortcutLabel(10, &buf));
}

test "sidebar width is bounded and yields to the terminal minimum" {
    try std.testing.expectEqual(default_width, preferredWidth(std.math.nan(f32)));
    try std.testing.expectEqual(min_width, preferredWidth(20));
    try std.testing.expectEqual(max_width, preferredWidth(900));
    try std.testing.expectEqual(@as(f32, 220), preferredWidth(220));

    try std.testing.expectEqual(@as(f32, 220), effectiveWidth(220, 800, 400));
    try std.testing.expectEqual(@as(f32, 150), effectiveWidth(220, 550, 400));
    try std.testing.expectEqual(@as(f32, 0), effectiveWidth(220, 300, 400));
}
