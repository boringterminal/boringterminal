//! Historical keyboard regression oracle only. Never imported by viewer/daemon.
//! Kept so retiring production v13 support does not shrink the conformance ratchet.
const protocol = @import("../daemon/protocol.zig");
const vt = @import("../vt.zig");

pub const version: u16 = 13;

const WireCode = enum(u8) {
    codepoint,
    escape,
    enter,
    tab,
    backspace,
    insert,
    delete_forward,
    up,
    down,
    right,
    left,
    home,
    end,
    page_up,
    page_down,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

pub const KeyEncoding = union(enum) {
    /// The old daemon can reproduce the event through its semantic key path.
    semantic: WireCode,
    /// Committed text did not exist in v13's key schema. Send it through the
    /// already-bounded raw input command instead.
    raw: []const u8,
    /// Release-only/new physical keys cannot have been negotiated by v13.
    ignored,
};

pub fn classifyKey(event: vt.keyboard.Event) KeyEncoding {
    if (event.code == .text) {
        if (event.action == .release) return .ignored;
        return .{ .raw = event.text };
    }
    // v13 cannot carry AppKit's committed text alongside a physical key.
    // Preserve the text lane for ordinary/Option-composed input instead of
    // degrading it to a bare key identity. Control and Super remain semantic
    // because their committed bytes represent bindings, not inserted text.
    if (event.action != .release and event.text.len != 0 and
        !event.modifiers.control and !event.modifiers.super)
    {
        return .{ .raw = event.text };
    }
    if (wireCode(event.code)) |code| return .{ .semantic = code };
    if (event.action != .release and event.text.len != 0) return .{ .raw = event.text };
    return .ignored;
}

pub fn encodeSemanticKey(
    enc: *protocol.Encoder,
    code: WireCode,
    event: vt.keyboard.Event,
) !void {
    try enc.byte(@intFromEnum(code));
    try enc.byte(@intFromEnum(event.action));
    try enc.byte(@bitCast(event.modifiers));
    try enc.int(u32, event.codepoint);
}

fn wireCode(code: vt.keyboard.Code) ?WireCode {
    return switch (code) {
        .codepoint => .codepoint,
        .escape => .escape,
        .enter => .enter,
        .tab => .tab,
        .backspace => .backspace,
        .insert => .insert,
        .delete_forward => .delete_forward,
        .up => .up,
        .down => .down,
        .right => .right,
        .left => .left,
        .home => .home,
        .end => .end,
        .page_up => .page_up,
        .page_down => .page_down,
        .f1 => .f1,
        .f2 => .f2,
        .f3 => .f3,
        .f4 => .f4,
        .f5 => .f5,
        .f6 => .f6,
        .f7 => .f7,
        .f8 => .f8,
        .f9 => .f9,
        .f10 => .f10,
        .f11 => .f11,
        .f12 => .f12,
        else => null,
    };
}

test "v13 wire codes stay frozen" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(u8, 0), @intFromEnum(WireCode.codepoint));
    try testing.expectEqual(@as(u8, 26), @intFromEnum(WireCode.f12));
}

test "v13 committed text uses raw input" {
    const testing = @import("std").testing;
    const pure_text = classifyKey(.{ .code = .text, .text = "hello" });
    try testing.expectEqualStrings("hello", pure_text.raw);

    const keyed_text = classifyKey(.{
        .code = .codepoint,
        .codepoint = 'h',
        .text = "h",
    });
    try testing.expectEqualStrings("h", keyed_text.raw);

    const control_key = classifyKey(.{
        .code = .codepoint,
        .codepoint = 'c',
        .modifiers = .{ .control = true },
        .text = "\x03",
    });
    try testing.expect(control_key == .semantic);
}

pub fn encodeKeyEvent(enc: *protocol.Encoder, event: vt.keyboard.Event) !@import("../shell/daemon_protocol/selected.zig").KeyEncoding {
    return switch (classifyKey(event)) {
        .semantic => |code| blk: {
            try encodeSemanticKey(enc, code, event);
            break :blk .{ .semantic = {} };
        },
        .raw => |bytes| .{ .raw = bytes },
        .ignored => .ignored,
    };
}
