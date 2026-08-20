//! macOS virtual-key translation. Protocol encoding lives in the pure VT
//! module so the daemon can consult authoritative negotiated state.

const std = @import("std");
const keyboard = @import("../vt/keyboard.zig");

pub const Key = keyboard.Code;

/// macOS virtual key codes for the keys the control lane handles.
pub fn keyFromKeyCode(code: u16) ?Key {
    return switch (code) {
        126 => .up,
        125 => .down,
        124 => .right,
        123 => .left,
        115 => .home,
        119 => .end,
        116 => .page_up,
        121 => .page_down,
        117 => .delete_forward,
        114 => .insert,
        122 => .f1,
        120 => .f2,
        99 => .f3,
        118 => .f4,
        96 => .f5,
        97 => .f6,
        98 => .f7,
        100 => .f8,
        101 => .f9,
        109 => .f10,
        103 => .f11,
        111 => .f12,
        105 => .f13,
        107 => .f14,
        113 => .f15,
        106 => .f16,
        64 => .f17,
        79 => .f18,
        80 => .f19,
        90 => .f20,
        82 => .kp_0,
        83 => .kp_1,
        84 => .kp_2,
        85 => .kp_3,
        86 => .kp_4,
        87 => .kp_5,
        88 => .kp_6,
        89 => .kp_7,
        91 => .kp_8,
        92 => .kp_9,
        65 => .kp_decimal,
        75 => .kp_divide,
        67 => .kp_multiply,
        78 => .kp_subtract,
        69 => .kp_add,
        76 => .kp_enter,
        81 => .kp_equal,
        71 => .num_lock, // Clear/Num Lock on Apple extended keyboards.
        else => null,
    };
}

/// Physical ANSI key → unshifted US/PC-101 scalar for Kitty's base-layout
/// alternate. macOS virtual key codes are positional, so this remains stable
/// while the active input source changes.
pub fn baseCodepointFromKeyCode(code: u16) ?u21 {
    return switch (code) {
        0 => 'a',
        1 => 's',
        2 => 'd',
        3 => 'f',
        4 => 'h',
        5 => 'g',
        6 => 'z',
        7 => 'x',
        8 => 'c',
        9 => 'v',
        11 => 'b',
        12 => 'q',
        13 => 'w',
        14 => 'e',
        15 => 'r',
        16 => 'y',
        17 => 't',
        18 => '1',
        19 => '2',
        20 => '3',
        21 => '4',
        22 => '6',
        23 => '5',
        24 => '=',
        25 => '9',
        26 => '7',
        27 => '-',
        28 => '8',
        29 => '0',
        30 => ']',
        31 => 'o',
        32 => 'u',
        33 => '[',
        34 => 'i',
        35 => 'p',
        37 => 'l',
        38 => 'j',
        39 => '\'',
        40 => 'k',
        41 => ';',
        42 => '\\',
        43 => ',',
        44 => '/',
        45 => 'n',
        46 => 'm',
        47 => '.',
        49 => ' ',
        50 => '`',
        else => null,
    };
}

pub fn modifierFromKeyCode(code: u16) ?Key {
    return switch (code) {
        57 => .caps_lock,
        56 => .left_shift,
        59 => .left_control,
        58 => .left_alt,
        55 => .left_super,
        60 => .right_shift,
        62 => .right_control,
        61 => .right_alt,
        54 => .right_super,
        else => null,
    };
}

test "macOS key codes map to protocol keys" {
    try std.testing.expectEqual(Key.up, keyFromKeyCode(126).?);
    try std.testing.expectEqual(Key.delete_forward, keyFromKeyCode(117).?);
    try std.testing.expectEqual(Key.f12, keyFromKeyCode(111).?);
    try std.testing.expectEqual(Key.f20, keyFromKeyCode(90).?);
    try std.testing.expectEqual(Key.kp_enter, keyFromKeyCode(76).?);
    try std.testing.expectEqual(Key.kp_7, keyFromKeyCode(89).?);
    try std.testing.expectEqual(@as(?Key, null), keyFromKeyCode(0));
    try std.testing.expectEqual(@as(u21, 'c'), baseCodepointFromKeyCode(8).?);
    try std.testing.expectEqual(Key.right_alt, modifierFromKeyCode(61).?);
}
