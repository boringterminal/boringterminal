//! Pure boundary between AppKit event inspection and terminal key semantics.
//!
//! `window.zig` reads Objective-C objects exactly once and passes only stable
//! scalar/key/modifier values here. Keeping policy out of the ObjC callback
//! makes the complete native mapping available to hermetic conformance tests.

const keyboard = @import("../vt/keyboard.zig");
const input = @import("input.zig");

pub const NativeEvent = struct {
    key_code: u16,
    primary: ?u21 = null,
    shifted: ?u21 = null,
    modifiers: keyboard.Modifiers = .{},
    action: keyboard.Action = .press,
    committed_text: []const u8 = "",
};

pub fn normalize(native: NativeEvent) ?keyboard.Event {
    var modifiers = native.modifiers;
    // Option participates in macOS text composition. Once AppKit committed
    // text, it is no longer a terminal binding modifier for that transaction.
    if (native.committed_text.len != 0) modifiers.alt = false;

    if (input.keyFromKeyCode(native.key_code)) |code| return .{
        .code = code,
        .modifiers = modifiers,
        .action = native.action,
        .text = native.committed_text,
    };

    const code: keyboard.Code = switch (native.key_code) {
        36 => .enter,
        48 => .tab,
        51 => .backspace,
        53 => .escape,
        else => .codepoint,
    };
    if (code != .codepoint) return .{
        .code = code,
        .modifiers = modifiers,
        .action = native.action,
        .text = native.committed_text,
    };

    const primary = native.primary orelse
        input.baseCodepointFromKeyCode(native.key_code) orelse return null;
    const shifted = if (native.modifiers.shift and native.shifted != null and
        native.shifted.? != primary) native.shifted.? else 0;
    const base_raw = input.baseCodepointFromKeyCode(native.key_code) orelse 0;
    const base = if (base_raw != primary) base_raw else 0;
    return .{
        .code = .codepoint,
        .codepoint = primary,
        .shifted_codepoint = shifted,
        .base_layout_codepoint = base,
        .modifiers = modifiers,
        .action = native.action,
        .text = native.committed_text,
    };
}

pub fn normalizeModifier(
    key_code: u16,
    modifiers: keyboard.Modifiers,
    pressed: bool,
) ?keyboard.Event {
    return .{
        .code = input.modifierFromKeyCode(key_code) orelse return null,
        .modifiers = modifiers,
        .action = if (pressed) .press else .release,
    };
}

test "normalizer preserves physical and layout identities" {
    const testing = @import("std").testing;
    const event = normalize(.{
        .key_code = 8,
        .primary = 0x0441,
        .modifiers = .{ .control = true },
    }).?;
    try testing.expectEqual(keyboard.Code.codepoint, event.code);
    try testing.expectEqual(@as(u21, 0x0441), event.codepoint);
    try testing.expectEqual(@as(u21, 'c'), event.base_layout_codepoint);
}

test "normalizer treats Option-produced text as committed text" {
    const testing = @import("std").testing;
    const event = normalize(.{
        .key_code = 0,
        .primary = 'a',
        .modifiers = .{ .alt = true },
        .committed_text = "å",
    }).?;
    try testing.expect(!event.modifiers.alt);
    try testing.expectEqualStrings("å", event.text);
}

test "normalizer retains action and sided modifier identity" {
    const testing = @import("std").testing;
    const repeated = normalize(.{ .key_code = 126, .action = .repeat }).?;
    try testing.expectEqual(keyboard.Code.up, repeated.code);
    try testing.expectEqual(keyboard.Action.repeat, repeated.action);
    const released = normalizeModifier(61, .{ .alt = false }, false).?;
    try testing.expectEqual(keyboard.Code.right_alt, released.code);
    try testing.expectEqual(keyboard.Action.release, released.action);
}
