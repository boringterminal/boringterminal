//! Truthful XTGETTCAP values shared with the legacy input encoder.

const std = @import("std");

pub const terminfo_name = "xterm-256color";

pub const up_normal = "\x1b[A";
pub const down_normal = "\x1b[B";
pub const right_normal = "\x1b[C";
pub const left_normal = "\x1b[D";
pub const home_normal = "\x1b[H";
pub const end_normal = "\x1b[F";

pub const up_application = "\x1bOA";
pub const down_application = "\x1bOB";
pub const right_application = "\x1bOC";
pub const left_application = "\x1bOD";
pub const home_application = "\x1bOH";
pub const end_application = "\x1bOF";

pub const page_up = "\x1b[5~";
pub const page_down = "\x1b[6~";
pub const delete_forward = "\x1b[3~";
pub const backspace = "\x7f";
pub const mouse = "\x1b[M";

const Entry = struct {
    name: []const u8,
    value: []const u8,
};

/// XTGETTCAP is not a general terminfo dump. This table contains xterm's
/// dynamic extras and only input strings the native event path emits.
const entries = [_]Entry{
    .{ .name = "TN", .value = terminfo_name },
    .{ .name = "Co", .value = "256" },
    .{ .name = "colors", .value = "256" },
    .{ .name = "RGB", .value = "8" },
    .{ .name = "kcuu1", .value = up_application },
    .{ .name = "ku", .value = up_application },
    .{ .name = "kcud1", .value = down_application },
    .{ .name = "kd", .value = down_application },
    .{ .name = "kcuf1", .value = right_application },
    .{ .name = "kr", .value = right_application },
    .{ .name = "kcub1", .value = left_application },
    .{ .name = "kl", .value = left_application },
    .{ .name = "khome", .value = home_application },
    .{ .name = "kh", .value = home_application },
    .{ .name = "kend", .value = end_application },
    .{ .name = "@7", .value = end_application },
    .{ .name = "kpp", .value = page_up },
    .{ .name = "kP", .value = page_up },
    .{ .name = "knp", .value = page_down },
    .{ .name = "kN", .value = page_down },
    .{ .name = "kdch1", .value = delete_forward },
    .{ .name = "kD", .value = delete_forward },
    .{ .name = "kbs", .value = backspace },
    .{ .name = "kb", .value = backspace },
    .{ .name = "kmous", .value = mouse },
    .{ .name = "Km", .value = mouse },
};

pub fn lookup(name: []const u8) ?[]const u8 {
    for (entries) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.value;
    }
    return null;
}

test "XTGETTCAP table advertises only concrete values" {
    try std.testing.expectEqualStrings("xterm-256color", lookup("TN").?);
    try std.testing.expectEqualStrings("\x1bOA", lookup("kcuu1").?);
    try std.testing.expectEqualStrings("\x7f", lookup("kb").?);
    try std.testing.expect(lookup("kf1") == null);
    try std.testing.expect(lookup("clear") == null);
}
