//! Pure legacy/Kitty keyboard protocol state and control-lane encoding.
//! The host supplies semantic events; terminal modes decide the bytes.

const std = @import("std");
const termcap = @import("termcap.zig");

pub const supported_flags: u8 = 0b11111;
pub const stack_capacity: usize = 8;
pub const max_text_bytes: usize = 4096;

pub const Flags = packed struct(u8) {
    disambiguate: bool = false,
    report_events: bool = false,
    report_alternates: bool = false,
    report_all: bool = false,
    report_associated: bool = false,
    _pad: u3 = 0,

    pub fn bits(self: Flags) u8 {
        return @bitCast(self);
    }

    pub fn supported(raw: u16) Flags {
        return @bitCast(@as(u8, @truncate(raw)) & supported_flags);
    }
};

pub const SetMode = enum { replace, union_set, subtract };

/// The current value is the top entry. Keeping an explicit base entry makes
/// underflow/reset behavior unambiguous and avoids allocation in the VT core.
pub const FlagStack = struct {
    entries: [stack_capacity]Flags = @splat(.{}),
    len: u8 = 1,

    pub fn current(self: *const FlagStack) Flags {
        return self.entries[self.len - 1];
    }

    pub fn set(self: *FlagStack, mode: SetMode, requested: u16) void {
        const value = Flags.supported(requested);
        const top = &self.entries[self.len - 1];
        top.* = switch (mode) {
            .replace => value,
            .union_set => @bitCast(top.bits() | value.bits()),
            .subtract => @bitCast(top.bits() & ~value.bits()),
        };
    }

    pub fn push(self: *FlagStack, requested: u16) void {
        const value = Flags.supported(requested);
        if (self.len < stack_capacity) {
            self.entries[self.len] = value;
            self.len += 1;
            return;
        }
        std.mem.copyForwards(Flags, self.entries[0 .. stack_capacity - 1], self.entries[1..]);
        self.entries[stack_capacity - 1] = value;
    }

    pub fn pop(self: *FlagStack, count: u16) void {
        if (count == 0) return;
        if (count >= self.len) return self.reset();
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) {
            self.len -= 1;
            self.entries[self.len] = .{};
        }
    }

    pub fn reset(self: *FlagStack) void {
        self.* = .{};
    }
};

pub const Code = enum(u8) {
    text,
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
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    kp_0,
    kp_1,
    kp_2,
    kp_3,
    kp_4,
    kp_5,
    kp_6,
    kp_7,
    kp_8,
    kp_9,
    kp_decimal,
    kp_divide,
    kp_multiply,
    kp_subtract,
    kp_add,
    kp_enter,
    kp_equal,
    caps_lock,
    num_lock,
    left_shift,
    left_control,
    left_alt,
    left_super,
    right_shift,
    right_control,
    right_alt,
    right_super,
};

pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    alt: bool = false,
    control: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _pad: u2 = 0,
};

pub const Action = enum(u8) { press, repeat, release };

pub const Event = struct {
    code: Code,
    codepoint: u21 = 0,
    shifted_codepoint: u21 = 0,
    base_layout_codepoint: u21 = 0,
    modifiers: Modifiers = .{},
    action: Action = .press,
    text: []const u8 = "",
};

fn modifierParameter(modifiers: Modifiers, include_locks: bool) u16 {
    var bits: u16 = 0;
    if (modifiers.shift) bits |= 1;
    if (modifiers.alt) bits |= 2;
    if (modifiers.control) bits |= 4;
    if (modifiers.super) bits |= 8;
    if (include_locks and modifiers.caps_lock) bits |= 64;
    if (include_locks and modifiers.num_lock) bits |= 128;
    return bits + 1;
}

fn hasBindingModifier(modifiers: Modifiers) bool {
    return modifiers.shift or modifiers.alt or modifiers.control or modifiers.super;
}

fn eventType(action: Action) u8 {
    return switch (action) {
        .press => 1,
        .repeat => 2,
        .release => 3,
    };
}

const Functional = struct { number: u16, final: u8 };

fn functional(code: Code) ?Functional {
    return switch (code) {
        .up => .{ .number = 1, .final = 'A' },
        .down => .{ .number = 1, .final = 'B' },
        .right => .{ .number = 1, .final = 'C' },
        .left => .{ .number = 1, .final = 'D' },
        .home => .{ .number = 1, .final = 'H' },
        .end => .{ .number = 1, .final = 'F' },
        .f1 => .{ .number = 1, .final = 'P' },
        .f2 => .{ .number = 1, .final = 'Q' },
        // CSI R is the cursor-position report, so the published protocol
        // removed it as a Kitty F3 encoding. Legacy mode still uses SS3 R.
        .f3 => .{ .number = 13, .final = '~' },
        .f4 => .{ .number = 1, .final = 'S' },
        .insert => .{ .number = 2, .final = '~' },
        .delete_forward => .{ .number = 3, .final = '~' },
        .page_up => .{ .number = 5, .final = '~' },
        .page_down => .{ .number = 6, .final = '~' },
        .f5 => .{ .number = 15, .final = '~' },
        .f6 => .{ .number = 17, .final = '~' },
        .f7 => .{ .number = 18, .final = '~' },
        .f8 => .{ .number = 19, .final = '~' },
        .f9 => .{ .number = 20, .final = '~' },
        .f10 => .{ .number = 21, .final = '~' },
        .f11 => .{ .number = 23, .final = '~' },
        .f12 => .{ .number = 24, .final = '~' },
        else => null,
    };
}

/// Encode one semantic control-lane event. Null means the event belongs to
/// the text lane or is intentionally suppressed by the negotiated flags.
pub fn encode(
    buf: []u8,
    flags: Flags,
    cursor_keys_application: bool,
    event: Event,
) !?[]const u8 {
    if (flags.bits() == 0) return encodeLegacy(buf, cursor_keys_application, event);
    return encodeKitty(buf, flags, cursor_keys_application, event);
}

fn privateKeyNumber(code: Code) ?u21 {
    return switch (code) {
        .num_lock => 57360,
        .f13 => 57376,
        .f14 => 57377,
        .f15 => 57378,
        .f16 => 57379,
        .f17 => 57380,
        .f18 => 57381,
        .f19 => 57382,
        .f20 => 57383,
        .kp_0 => 57399,
        .kp_1 => 57400,
        .kp_2 => 57401,
        .kp_3 => 57402,
        .kp_4 => 57403,
        .kp_5 => 57404,
        .kp_6 => 57405,
        .kp_7 => 57406,
        .kp_8 => 57407,
        .kp_9 => 57408,
        .kp_decimal => 57409,
        .kp_divide => 57410,
        .kp_multiply => 57411,
        .kp_subtract => 57412,
        .kp_add => 57413,
        .kp_enter => 57414,
        .kp_equal => 57415,
        .caps_lock => 57358,
        .left_shift => 57441,
        .left_control => 57442,
        .left_alt => 57443,
        .left_super => 57444,
        .right_shift => 57447,
        .right_control => 57448,
        .right_alt => 57449,
        .right_super => 57450,
        else => null,
    };
}

fn isKeypad(code: Code) bool {
    return switch (code) {
        .kp_0,
        .kp_1,
        .kp_2,
        .kp_3,
        .kp_4,
        .kp_5,
        .kp_6,
        .kp_7,
        .kp_8,
        .kp_9,
        .kp_decimal,
        .kp_divide,
        .kp_multiply,
        .kp_subtract,
        .kp_add,
        .kp_enter,
        .kp_equal,
        => true,
        else => false,
    };
}

fn keypadEquivalent(event: Event) Event {
    var equivalent = event;
    equivalent.text = "";
    equivalent.codepoint = 0;
    equivalent.shifted_codepoint = 0;
    equivalent.base_layout_codepoint = 0;
    switch (event.code) {
        .kp_enter => equivalent.code = .enter,
        else => {
            equivalent.code = .codepoint;
            equivalent.codepoint = switch (event.code) {
                .kp_0 => '0',
                .kp_1 => '1',
                .kp_2 => '2',
                .kp_3 => '3',
                .kp_4 => '4',
                .kp_5 => '5',
                .kp_6 => '6',
                .kp_7 => '7',
                .kp_8 => '8',
                .kp_9 => '9',
                .kp_decimal => '.',
                .kp_divide => '/',
                .kp_multiply => '*',
                .kp_subtract => '-',
                .kp_add => '+',
                .kp_equal => '=',
                else => unreachable,
            };
        },
    }
    return equivalent;
}

fn appendFmt(buf: []u8, len: *usize, comptime format: []const u8, args: anytype) !void {
    const written = try std.fmt.bufPrint(buf[len.*..], format, args);
    len.* += written.len;
}

fn associatedTextValid(text: []const u8) bool {
    if (text.len == 0 or text.len > max_text_bytes) return false;
    const view = std.unicode.Utf8View.init(text) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return false;
    }
    return true;
}

fn encodeCanonical(
    buf: []u8,
    flags: Flags,
    event: Event,
    number: u21,
) ![]const u8 {
    var len: usize = 0;
    try appendFmt(buf, &len, "\x1b[{d}", .{number});

    if (flags.report_alternates and event.code == .codepoint) {
        const shifted = if (event.modifiers.shift) event.shifted_codepoint else 0;
        const base = event.base_layout_codepoint;
        if (base != 0) {
            if (shifted != 0) try appendFmt(buf, &len, ":{d}:{d}", .{ shifted, base }) else try appendFmt(buf, &len, "::{d}", .{base});
        } else if (shifted != 0) {
            try appendFmt(buf, &len, ":{d}", .{shifted});
        }
    }

    const modifier = modifierParameter(event.modifiers, flags.report_all or event.code != .codepoint);
    const typed = flags.report_events and event.action != .press;
    const include_text = flags.report_all and flags.report_associated and
        event.action != .release and associatedTextValid(event.text);

    if (include_text) {
        try appendFmt(buf, &len, ";", .{});
        if (modifier != 1 or typed) {
            try appendFmt(buf, &len, "{d}", .{modifier});
            if (typed) try appendFmt(buf, &len, ":{d}", .{eventType(event.action)});
        }
        try appendFmt(buf, &len, ";", .{});
        const view = try std.unicode.Utf8View.init(event.text);
        var it = view.iterator();
        var first = true;
        while (it.nextCodepoint()) |cp| {
            if (!first) try appendFmt(buf, &len, ":", .{});
            try appendFmt(buf, &len, "{d}", .{cp});
            first = false;
        }
        try appendFmt(buf, &len, "u", .{});
        return buf[0..len];
    }

    if (modifier != 1 or typed) {
        try appendFmt(buf, &len, ";{d}", .{modifier});
        if (typed) try appendFmt(buf, &len, ":{d}", .{eventType(event.action)});
    }
    try appendFmt(buf, &len, "u", .{});
    return buf[0..len];
}

fn encodeKitty(
    buf: []u8,
    flags: Flags,
    cursor_keys_application: bool,
    event: Event,
) !?[]const u8 {
    if (event.action == .release and !flags.report_events) return null;

    // Flags are independently negotiable. Event types or alternate-key
    // reporting alone do not opt text keys into CSI-u identity, and ordinary
    // functional presses still honor legacy cursor-key application mode.
    if (!flags.disambiguate and !flags.report_all) switch (event.code) {
        .text, .codepoint => return encodeLegacy(buf, cursor_keys_application, event),
        .escape => if (event.action == .press or !flags.report_events)
            return encodeLegacy(buf, cursor_keys_application, event),
        else => {},
    };

    if (privateKeyNumber(event.code)) |number| {
        const is_modifier = switch (event.code) {
            .caps_lock,
            .num_lock,
            .left_shift,
            .left_control,
            .left_alt,
            .left_super,
            .right_shift,
            .right_control,
            .right_alt,
            .right_super,
            => true,
            else => false,
        };
        if (is_modifier and !flags.report_all) return null;
        // Without disambiguation the published legacy contract aliases every
        // keypad key to its non-keypad equivalent. Event types alone do not
        // make a text-producing keypad key distinct.
        if (isKeypad(event.code) and !flags.disambiguate and !flags.report_all)
            return encodeLegacy(buf, cursor_keys_application, keypadEquivalent(event));
        return try encodeCanonical(buf, flags, event, number);
    }

    if (functional(event.code)) |key| {
        if (!flags.disambiguate and !flags.report_all and
            (event.action == .press or !flags.report_events))
            return encodeLegacy(buf, cursor_keys_application, event);
        const modifier = modifierParameter(event.modifiers, true);
        const typed = flags.report_events and event.action != .press;
        if (modifier == 1 and !typed) {
            if (key.final == '~') return try std.fmt.bufPrint(buf, "\x1b[{d}~", .{key.number});
            return try std.fmt.bufPrint(buf, "\x1b[{c}", .{key.final});
        }
        if (typed) return try std.fmt.bufPrint(
            buf,
            "\x1b[{d};{d}:{d}{c}",
            .{ key.number, modifier, eventType(event.action), key.final },
        );
        return try std.fmt.bufPrint(buf, "\x1b[{d};{d}{c}", .{ key.number, modifier, key.final });
    }

    const number: u21 = switch (event.code) {
        .text => 0,
        .codepoint => event.codepoint,
        .escape => 27,
        .enter => 13,
        .tab => 9,
        .backspace => 127,
        else => unreachable,
    };

    // Without report-all, committed AppKit text remains ordinary UTF-8. Enter,
    // Tab, and Backspace also retain their recovery bytes when unmodified.
    if (!flags.report_all and event.text.len > 0 and
        !event.modifiers.control and !event.modifiers.super and event.action != .release)
    {
        return event.text;
    }
    if (!flags.report_all and
        (event.code == .enter or event.code == .tab or event.code == .backspace) and
        !hasBindingModifier(event.modifiers))
    {
        if (event.action == .release) return null;
        return switch (event.code) {
            .enter => "\r",
            .tab => "\t",
            .backspace => termcap.backspace,
            else => unreachable,
        };
    }

    if (event.code == .text and
        (!flags.report_all or !flags.report_associated or !associatedTextValid(event.text)))
    {
        // AppKit can commit text without a physical key (IME, dictation,
        // character palette). Never discard user input merely because the
        // foreground program omitted the associated-text enhancement.
        return if (event.action == .release) null else event.text;
    }
    return try encodeCanonical(buf, flags, event, number);
}

fn encodeLegacy(buf: []u8, cursor_keys_application: bool, event: Event) !?[]const u8 {
    if (event.action == .release) return null;
    // Command is AppKit-owned unless the foreground program explicitly asks
    // report-all to represent it. Never leak an unclaimed macOS shortcut as
    // ordinary legacy text.
    if (event.modifiers.super) return null;
    if (event.text.len > 0 and !event.modifiers.control)
        return event.text;
    if (isKeypad(event.code)) return encodeLegacy(buf, cursor_keys_application, keypadEquivalent(event));
    if (privateKeyNumber(event.code) != null) return null;
    const modifier = modifierParameter(event.modifiers, false);

    if (functional(event.code)) |key| {
        if (hasBindingModifier(event.modifiers)) {
            return try std.fmt.bufPrint(buf, "\x1b[{d};{d}{c}", .{ key.number, modifier, key.final });
        }
        return switch (event.code) {
            .up => if (cursor_keys_application) termcap.up_application else termcap.up_normal,
            .down => if (cursor_keys_application) termcap.down_application else termcap.down_normal,
            .right => if (cursor_keys_application) termcap.right_application else termcap.right_normal,
            .left => if (cursor_keys_application) termcap.left_application else termcap.left_normal,
            .home => if (cursor_keys_application) termcap.home_application else termcap.home_normal,
            .end => if (cursor_keys_application) termcap.end_application else termcap.end_normal,
            .page_up => termcap.page_up,
            .page_down => termcap.page_down,
            .delete_forward => termcap.delete_forward,
            .insert => "\x1b[2~",
            .f1 => "\x1bOP",
            .f2 => "\x1bOQ",
            .f3 => "\x1bOR",
            .f4 => "\x1bOS",
            .f5 => "\x1b[15~",
            .f6 => "\x1b[17~",
            .f7 => "\x1b[18~",
            .f8 => "\x1b[19~",
            .f9 => "\x1b[20~",
            .f10 => "\x1b[21~",
            .f11 => "\x1b[23~",
            .f12 => "\x1b[24~",
            else => unreachable,
        };
    }

    return switch (event.code) {
        .text => event.text,
        .escape => if (event.modifiers.alt) "\x1b\x1b" else "\x1b",
        .enter => if (event.modifiers.alt) "\x1b\r" else "\r",
        .backspace => blk: {
            const byte: u8 = if (event.modifiers.control) 0x08 else 0x7f;
            if (event.modifiers.alt) break :blk try std.fmt.bufPrint(buf, "\x1b{c}", .{byte});
            buf[0] = byte;
            break :blk buf[0..1];
        },
        .tab => blk: {
            if (event.modifiers.shift) {
                if (event.modifiers.alt) break :blk "\x1b\x1b[Z";
                break :blk "\x1b[Z";
            }
            if (event.modifiers.alt) break :blk "\x1b\t";
            break :blk "\t";
        },
        .codepoint => blk: {
            if (event.codepoint > 0x7f) break :blk null;
            const cp: u8 = @intCast(event.codepoint);
            const byte = if (event.modifiers.control) controlByte(cp) orelse cp else cp;
            if (event.modifiers.alt) break :blk try std.fmt.bufPrint(buf, "\x1b{c}", .{byte});
            buf[0] = byte;
            break :blk buf[0..1];
        },
        else => unreachable,
    };
}

pub fn controlByte(char: u8) ?u8 {
    return switch (char) {
        'a'...'z' => char - 'a' + 1,
        'A'...'Z' => char - 'A' + 1,
        '@', ' ' => 0,
        '2' => 0,
        '3' => 0x1b,
        '4' => 0x1c,
        '5' => 0x1d,
        '6', '~' => 0x1e,
        '7', '/', '_' => 0x1f,
        '8', '?' => 0x7f,
        '[' => 0x1b,
        '\\' => 0x1c,
        ']' => 0x1d,
        '^' => 0x1e,
        else => null,
    };
}

test "flag stacks mask unsupported bits and keep screens independent" {
    var primary: FlagStack = .{};
    var alternate: FlagStack = .{};
    primary.push(31);
    try std.testing.expectEqual(@as(u8, 31), primary.current().bits());
    try std.testing.expectEqual(@as(u8, 0), alternate.current().bits());
    primary.set(.subtract, 2);
    try std.testing.expectEqual(@as(u8, 29), primary.current().bits());
    primary.pop(1);
    try std.testing.expectEqual(@as(u8, 0), primary.current().bits());
}

test "kitty phase two reports alternates all keys and associated text" {
    var buf: [256]u8 = undefined;
    const flags: Flags = .{
        .disambiguate = true,
        .report_events = true,
        .report_alternates = true,
        .report_all = true,
        .report_associated = true,
    };
    try std.testing.expectEqualStrings("\x1b[61:43;2;43u", (try encode(&buf, flags, false, .{
        .code = .codepoint,
        .codepoint = '=',
        .shifted_codepoint = '+',
        .modifiers = .{ .shift = true },
        .text = "+",
    })).?);
    try std.testing.expectEqualStrings("\x1b[1092::99;5u", (try encode(&buf, flags, false, .{
        .code = .codepoint,
        .codepoint = 1092,
        .base_layout_codepoint = 'c',
        .modifiers = .{ .control = true },
    })).?);
    try std.testing.expectEqualStrings("\x1b[57441;2u", (try encode(&buf, flags, false, .{
        .code = .left_shift,
        .modifiers = .{ .shift = true },
    })).?);
    try std.testing.expectEqualStrings("\x1b[0;;229u", (try encode(&buf, flags, false, .{
        .code = .text,
        .text = "å",
    })).?);
    try std.testing.expectEqualStrings("\x1b[13u", (try encode(&buf, flags, false, .{
        .code = .enter,
    })).?);
    try std.testing.expectEqualStrings("\x1b[13;1:3u", (try encode(&buf, flags, false, .{
        .code = .enter,
        .action = .release,
    })).?);
    try std.testing.expectEqualStrings("\x1b[57414u", (try encode(&buf, flags, false, .{
        .code = .kp_enter,
    })).?);
    try std.testing.expectEqualStrings("\x1b[57383u", (try encode(&buf, flags, false, .{
        .code = .f20,
    })).?);
    try std.testing.expectEqualStrings("7", (try encode(&buf, .{
        .report_events = true,
    }, false, .{ .code = .kp_7 })).?);
}

test "pure AppKit text survives report-all without associated text" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("你好", (try encode(&buf, .{
        .report_all = true,
    }, false, .{ .code = .text, .text = "你好" })).?);
    try std.testing.expectEqualStrings("\t", (try encode(&buf, .{
        .report_all = true,
        .report_associated = true,
    }, false, .{ .code = .text, .text = "\t" })).?);
}

test "full flag stack evicts oldest and underflow resets" {
    var stack: FlagStack = .{};
    var i: usize = 0;
    while (i < stack_capacity + 2) : (i += 1) stack.push(@intCast(i & 3));
    try std.testing.expectEqual(@as(u8, 1), stack.current().bits());
    stack.pop(999);
    try std.testing.expectEqual(@as(u8, 0), stack.current().bits());
}

test "kitty phase one disambiguates and reports event types" {
    var buf: [64]u8 = undefined;
    const flags: Flags = .{ .disambiguate = true, .report_events = true };
    try std.testing.expectEqualStrings("\x1b[13;2u", (try encode(&buf, flags, false, .{
        .code = .enter,
        .modifiers = .{ .shift = true },
    })).?);
    try std.testing.expectEqualStrings("\x1b[99;5u", (try encode(&buf, flags, false, .{
        .code = .codepoint,
        .codepoint = 'c',
        .modifiers = .{ .control = true },
    })).?);
    try std.testing.expectEqualStrings("\x1b[1;1:2A", (try encode(&buf, flags, false, .{
        .code = .up,
        .action = .repeat,
    })).?);
    try std.testing.expectEqualStrings("\x1b[1;1:3A", (try encode(&buf, flags, false, .{
        .code = .up,
        .action = .release,
    })).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try encode(&buf, flags, false, .{
        .code = .enter,
        .action = .release,
    }));
    try std.testing.expectEqualStrings("\x1b[13~", (try encode(&buf, flags, false, .{
        .code = .f3,
    })).?);
    try std.testing.expectEqualStrings("\x1bOA", (try encode(&buf, .{
        .report_events = true,
    }, true, .{ .code = .up })).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try encode(&buf, .{
        .report_events = true,
    }, false, .{
        .code = .codepoint,
        .codepoint = 'a',
        .action = .release,
    }));
}

test "legacy encoding retains DECCKM and adds standard modifiers" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1bOA", (try encode(&buf, .{}, true, .{ .code = .up })).?);
    try std.testing.expectEqualStrings("\x1b[1;2A", (try encode(&buf, .{}, true, .{
        .code = .up,
        .modifiers = .{ .shift = true },
    })).?);
    try std.testing.expectEqualStrings("\x1b[Z", (try encode(&buf, .{}, false, .{
        .code = .tab,
        .modifiers = .{ .shift = true },
    })).?);
}

test "legacy control bytes" {
    try std.testing.expectEqual(@as(?u8, 3), controlByte('c'));
    try std.testing.expectEqual(@as(?u8, 0x1b), controlByte('['));
    try std.testing.expectEqual(@as(?u8, 0), controlByte(' '));
    try std.testing.expectEqual(@as(?u8, 0), controlByte('2'));
    try std.testing.expectEqual(@as(?u8, 0x1b), controlByte('3'));
    try std.testing.expectEqual(@as(?u8, 0x1f), controlByte('/'));
    try std.testing.expectEqual(@as(?u8, 0x7f), controlByte('8'));
    try std.testing.expectEqual(@as(?u8, null), controlByte('1'));
}
