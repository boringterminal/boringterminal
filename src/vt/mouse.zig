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

/// RFC 0024's complete OSC 22 pointer vocabulary. Values 0...3 preserve the
/// released attach-dialect-18 encoding; dialect 19 carries the validated enum
/// in its own byte.
pub const PointerShape = enum(u8) {
    text = 0,
    default = 1,
    pointer = 2,
    crosshair = 3,
    context_menu = 4,
    help = 5,
    progress = 6,
    wait = 7,
    cell = 8,
    vertical_text = 9,
    alias = 10,
    copy = 11,
    move = 12,
    no_drop = 13,
    not_allowed = 14,
    grab = 15,
    grabbing = 16,
    all_scroll = 17,
    col_resize = 18,
    row_resize = 19,
    n_resize = 20,
    e_resize = 21,
    s_resize = 22,
    w_resize = 23,
    ne_resize = 24,
    nw_resize = 25,
    se_resize = 26,
    sw_resize = 27,
    ew_resize = 28,
    ns_resize = 29,
    nesw_resize = 30,
    nwse_resize = 31,
    zoom_in = 32,
    zoom_out = 33,

    pub fn parse(value: []const u8) PointerShape {
        // Empty and unknown values reset to xterm's text default instead of
        // retaining stale application state.
        return pointer_shape_names.get(value) orelse .text;
    }
};

// CSS names and the interoperable xterm/Xcursor aliases catalogued by Ghostty
// (MIT), src/terminal/mouse.zig. Boring Terminal retains its shipped `cross`
// alias as crosshair rather than Ghostty's cell mapping.
const pointer_shape_names = std.StaticStringMap(PointerShape).initComptime(.{
    .{ "text", .text },
    .{ "xterm", .text },
    .{ "default", .default },
    .{ "left_ptr", .default },
    .{ "pointer", .pointer },
    .{ "hand", .pointer },
    .{ "hand2", .pointer },
    .{ "crosshair", .crosshair },
    .{ "cross", .crosshair },
    .{ "context-menu", .context_menu },
    .{ "help", .help },
    .{ "question_arrow", .help },
    .{ "progress", .progress },
    .{ "left_ptr_watch", .progress },
    .{ "wait", .wait },
    .{ "watch", .wait },
    .{ "cell", .cell },
    .{ "vertical-text", .vertical_text },
    .{ "alias", .alias },
    .{ "dnd-link", .alias },
    .{ "copy", .copy },
    .{ "dnd-copy", .copy },
    .{ "move", .move },
    .{ "dnd-move", .move },
    .{ "no-drop", .no_drop },
    .{ "dnd-no-drop", .no_drop },
    .{ "not-allowed", .not_allowed },
    .{ "crossed_circle", .not_allowed },
    .{ "grab", .grab },
    .{ "hand1", .grab },
    .{ "grabbing", .grabbing },
    .{ "all-scroll", .all_scroll },
    .{ "fleur", .all_scroll },
    .{ "col-resize", .col_resize },
    .{ "row-resize", .row_resize },
    .{ "n-resize", .n_resize },
    .{ "top_side", .n_resize },
    .{ "e-resize", .e_resize },
    .{ "right_side", .e_resize },
    .{ "s-resize", .s_resize },
    .{ "bottom_side", .s_resize },
    .{ "w-resize", .w_resize },
    .{ "left_side", .w_resize },
    .{ "ne-resize", .ne_resize },
    .{ "top_right_corner", .ne_resize },
    .{ "nw-resize", .nw_resize },
    .{ "top_left_corner", .nw_resize },
    .{ "se-resize", .se_resize },
    .{ "bottom_right_corner", .se_resize },
    .{ "sw-resize", .sw_resize },
    .{ "bottom_left_corner", .sw_resize },
    .{ "ew-resize", .ew_resize },
    .{ "ns-resize", .ns_resize },
    .{ "nesw-resize", .nesw_resize },
    .{ "nwse-resize", .nwse_resize },
    .{ "zoom-in", .zoom_in },
    .{ "zoom-out", .zoom_out },
});

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

test "OSC 22 accepts every canonical pointer name" {
    const testing = std.testing;
    const cases = [_]struct { []const u8, PointerShape }{
        .{ "text", .text },
        .{ "default", .default },
        .{ "pointer", .pointer },
        .{ "crosshair", .crosshair },
        .{ "context-menu", .context_menu },
        .{ "help", .help },
        .{ "progress", .progress },
        .{ "wait", .wait },
        .{ "cell", .cell },
        .{ "vertical-text", .vertical_text },
        .{ "alias", .alias },
        .{ "copy", .copy },
        .{ "move", .move },
        .{ "no-drop", .no_drop },
        .{ "not-allowed", .not_allowed },
        .{ "grab", .grab },
        .{ "grabbing", .grabbing },
        .{ "all-scroll", .all_scroll },
        .{ "col-resize", .col_resize },
        .{ "row-resize", .row_resize },
        .{ "n-resize", .n_resize },
        .{ "e-resize", .e_resize },
        .{ "s-resize", .s_resize },
        .{ "w-resize", .w_resize },
        .{ "ne-resize", .ne_resize },
        .{ "nw-resize", .nw_resize },
        .{ "se-resize", .se_resize },
        .{ "sw-resize", .sw_resize },
        .{ "ew-resize", .ew_resize },
        .{ "ns-resize", .ns_resize },
        .{ "nesw-resize", .nesw_resize },
        .{ "nwse-resize", .nwse_resize },
        .{ "zoom-in", .zoom_in },
        .{ "zoom-out", .zoom_out },
    };
    for (cases) |case| try testing.expectEqual(case[1], PointerShape.parse(case[0]));
}

test "OSC 22 accepts interoperable aliases and resets unknown names" {
    const testing = std.testing;
    try testing.expectEqual(PointerShape.text, PointerShape.parse("xterm"));
    try testing.expectEqual(PointerShape.text, PointerShape.parse(""));
    try testing.expectEqual(PointerShape.text, PointerShape.parse("bogus"));
    try testing.expectEqual(PointerShape.default, PointerShape.parse("default"));
    try testing.expectEqual(PointerShape.default, PointerShape.parse("left_ptr"));
    try testing.expectEqual(PointerShape.pointer, PointerShape.parse("hand2"));
    try testing.expectEqual(PointerShape.crosshair, PointerShape.parse("cross"));
    try testing.expectEqual(PointerShape.help, PointerShape.parse("question_arrow"));
    try testing.expectEqual(PointerShape.alias, PointerShape.parse("dnd-link"));
    try testing.expectEqual(PointerShape.not_allowed, PointerShape.parse("crossed_circle"));
    try testing.expectEqual(PointerShape.grab, PointerShape.parse("hand1"));
    try testing.expectEqual(PointerShape.all_scroll, PointerShape.parse("fleur"));
    try testing.expectEqual(PointerShape.ne_resize, PointerShape.parse("top_right_corner"));
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
