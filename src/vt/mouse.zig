//! Pure xterm mouse-event filtering and encoding (RFC 0002).

const std = @import("std");
const termcap = @import("termcap.zig");

pub const Tracking = enum(u2) {
    none,
    normal,
    button,
    any,
};

pub const Encoding = enum(u2) {
    legacy,
    sgr,
    sgr_pixels,
};

/// RFC 0002's first interoperable OSC 22 surface. The numeric order is the
/// attach-dialect-18 snapshot encoding; zero preserves the historical text
/// default of retained public dialects.
pub const PointerShape = enum(u2) {
    text,
    default,
    pointer,
    crosshair,

    pub fn parse(value: []const u8) PointerShape {
        if (std.mem.eql(u8, value, "default") or
            std.mem.eql(u8, value, "left_ptr")) return .default;
        if (std.mem.eql(u8, value, "pointer") or
            std.mem.eql(u8, value, "hand") or
            std.mem.eql(u8, value, "hand2")) return .pointer;
        if (std.mem.eql(u8, value, "crosshair") or
            std.mem.eql(u8, value, "cross")) return .crosshair;
        // xterm calls its text cursor "xterm". Empty and unknown values also
        // reset to that terminal default instead of retaining stale state.
        return .text;
    }
};

pub const Button = enum(u2) {
    left,
    middle,
    right,
    none,
};

pub const Modifiers = packed struct(u3) {
    shift: bool = false,
    alt: bool = false,
    control: bool = false,
};

pub const Kind = enum(u3) {
    press,
    release,
    motion,
    wheel_up,
    wheel_down,
    wheel_left,
    wheel_right,
};

pub const Event = struct {
    kind: Kind,
    button: Button = .none,
    modifiers: Modifiers = .{},
    /// Zero-based cell coordinates.
    col: u16,
    row: u16,
    /// Zero-based physical pixels relative to the terminal content origin.
    pixel_x: u32 = 0,
    pixel_y: u32 = 0,
};

/// Encode one event for the active tracking/format modes. `null` means the
/// tracking mode suppresses this event, or legacy coordinates cannot
/// represent it. The largest SGR response fits comfortably in 64 bytes.
pub fn encode(out: []u8, tracking: Tracking, encoding: Encoding, event: Event) !?[]const u8 {
    if (tracking == .none) return null;

    var code: u8 = switch (event.kind) {
        .press, .release => buttonCode(event.button) orelse return null,
        .motion => motion: {
            if (tracking == .normal) return null;
            if (tracking == .button and event.button == .none) return null;
            break :motion (buttonCode(event.button) orelse 3) + 32;
        },
        .wheel_up => 64,
        .wheel_down => 65,
        .wheel_left => 66,
        .wheel_right => 67,
    };
    code += modifierCode(event.modifiers);

    return switch (encoding) {
        .sgr => try std.fmt.bufPrint(
            out,
            "\x1b[<{d};{d};{d}{c}",
            .{ code, @as(u32, event.col) + 1, @as(u32, event.row) + 1, if (event.kind == .release) @as(u8, 'm') else 'M' },
        ),
        .sgr_pixels => try std.fmt.bufPrint(
            out,
            "\x1b[<{d};{d};{d}{c}",
            .{ code, @as(u64, event.pixel_x) + 1, @as(u64, event.pixel_y) + 1, if (event.kind == .release) @as(u8, 'm') else 'M' },
        ),
        .legacy => legacy: {
            // X10's one-byte position is value+32 after converting to the
            // protocol's one-based coordinate, so zero-based 223 is the
            // first unrepresentable cell.
            if (event.col >= 223 or event.row >= 223) return null;
            if (out.len < 6) return error.NoSpaceLeft;
            const legacy_code: u8 = if (event.kind == .release)
                3 + modifierCode(event.modifiers)
            else
                code;
            @memcpy(out[0..termcap.mouse.len], termcap.mouse);
            out[3] = legacy_code + 32;
            out[4] = @intCast(event.col + 33);
            out[5] = @intCast(event.row + 33);
            break :legacy out[0..6];
        },
    };
}

fn buttonCode(button: Button) ?u8 {
    return switch (button) {
        .left => 0,
        .middle => 1,
        .right => 2,
        .none => null,
    };
}

test "OSC 22 pointer names use the bounded interoperable set" {
    const testing = std.testing;
    try testing.expectEqual(PointerShape.text, PointerShape.parse("text"));
    try testing.expectEqual(PointerShape.text, PointerShape.parse("xterm"));
    try testing.expectEqual(PointerShape.text, PointerShape.parse(""));
    try testing.expectEqual(PointerShape.text, PointerShape.parse("row-resize"));
    try testing.expectEqual(PointerShape.default, PointerShape.parse("default"));
    try testing.expectEqual(PointerShape.default, PointerShape.parse("left_ptr"));
    try testing.expectEqual(PointerShape.pointer, PointerShape.parse("pointer"));
    try testing.expectEqual(PointerShape.pointer, PointerShape.parse("hand2"));
    try testing.expectEqual(PointerShape.crosshair, PointerShape.parse("crosshair"));
    try testing.expectEqual(PointerShape.crosshair, PointerShape.parse("cross"));
}

fn modifierCode(modifiers: Modifiers) u8 {
    return @as(u8, @intFromBool(modifiers.shift)) * 4 +
        @as(u8, @intFromBool(modifiers.alt)) * 8 +
        @as(u8, @intFromBool(modifiers.control)) * 16;
}

test "SGR mouse encodes buttons modifiers motion release and wheels" {
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "\x1b[<28;5;3M",
        (try encode(&out, .normal, .sgr, .{
            .kind = .press,
            .button = .left,
            .modifiers = .{ .shift = true, .alt = true, .control = true },
            .col = 4,
            .row = 2,
        })).?,
    );
    try std.testing.expectEqualStrings(
        "\x1b[<10;5;3m",
        (try encode(&out, .normal, .sgr, .{
            .kind = .release,
            .button = .right,
            .modifiers = .{ .alt = true },
            .col = 4,
            .row = 2,
        })).?,
    );
    try std.testing.expectEqualStrings(
        "\x1b[<35;1;1M",
        (try encode(&out, .any, .sgr, .{ .kind = .motion, .col = 0, .row = 0 })).?,
    );
    try std.testing.expectEqualStrings(
        "\x1b[<65;2;4M",
        (try encode(&out, .normal, .sgr, .{ .kind = .wheel_down, .col = 1, .row = 3 })).?,
    );
}

test "legacy mouse uses X10 release and coordinate encoding" {
    var out: [64]u8 = undefined;
    try std.testing.expectEqualSlices(
        u8,
        "\x1b[M !!",
        (try encode(&out, .normal, .legacy, .{
            .kind = .press,
            .button = .left,
            .col = 0,
            .row = 0,
        })).?,
    );
    try std.testing.expectEqualSlices(
        u8,
        "\x1b[M'!!",
        (try encode(&out, .normal, .legacy, .{
            .kind = .release,
            .button = .right,
            .modifiers = .{ .shift = true },
            .col = 0,
            .row = 0,
        })).?,
    );
    try std.testing.expect((try encode(&out, .normal, .legacy, .{
        .kind = .press,
        .button = .left,
        .col = 223,
        .row = 0,
    })) == null);
}

test "tracking modes filter motion independently of encoding" {
    var out: [64]u8 = undefined;
    const no_button: Event = .{ .kind = .motion, .col = 1, .row = 1 };
    try std.testing.expect((try encode(&out, .normal, .sgr, no_button)) == null);
    try std.testing.expect((try encode(&out, .button, .sgr, no_button)) == null);
    try std.testing.expect((try encode(&out, .any, .sgr, no_button)) != null);
    try std.testing.expect((try encode(&out, .button, .sgr, .{
        .kind = .motion,
        .button = .left,
        .col = 1,
        .row = 1,
    })) != null);
}

test "SGR pixel mouse uses one-based physical pixels" {
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "\x1b[<0;1;1M",
        (try encode(&out, .normal, .sgr_pixels, .{
            .kind = .press,
            .button = .left,
            .col = 9,
            .row = 4,
            .pixel_x = 0,
            .pixel_y = 0,
        })).?,
    );
    try std.testing.expectEqualStrings(
        "\x1b[<2;641;359m",
        (try encode(&out, .normal, .sgr_pixels, .{
            .kind = .release,
            .button = .right,
            .col = 0,
            .row = 0,
            .pixel_x = 640,
            .pixel_y = 358,
        })).?,
    );
}
