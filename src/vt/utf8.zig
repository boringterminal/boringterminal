//! Streaming UTF-8 decoder that sits in front of the parser (RFC 0002).
//! Byte-at-a-time so PTY reads can split sequences anywhere. Invalid input
//! never stalls: it yields U+FFFD and, when the offending byte could open a
//! new sequence, asks the caller to re-feed it.
//!
//! Ranges follow Unicode 15 Table 3-7 (well-formed UTF-8 byte sequences),
//! which rejects overlongs, surrogates, and > U+10FFFF structurally.

const std = @import("std");

pub const replacement: u21 = 0xFFFD;

pub const Result = struct {
    /// Decoded codepoint, if this byte completed one.
    cp: ?u21 = null,
    /// The byte was rejected as a continuation; re-feed it after handling
    /// `cp` (always `replacement` when set together with `retry`).
    retry: bool = false,
};

pub const Decoder = struct {
    acc: u21 = 0,
    /// Continuation bytes still expected. 0 = ground.
    needed: u3 = 0,
    /// Valid range for the *next* continuation byte. Table 3-7 narrows the
    /// first continuation after E0/ED/F0/F4; later ones are 0x80..0xBF.
    next_min: u8 = 0x80,
    next_max: u8 = 0xBF,

    pub fn pending(self: *const Decoder) bool {
        return self.needed != 0;
    }

    pub fn reset(self: *Decoder) void {
        self.* = .{};
    }

    pub fn feed(self: *Decoder, byte: u8) Result {
        if (self.needed == 0) return self.start(byte);

        if (byte < self.next_min or byte > self.next_max) {
            // Truncated sequence. Emit one replacement for the whole mess
            // and let the caller reprocess this byte from ground.
            self.reset();
            return .{ .cp = replacement, .retry = true };
        }

        self.acc = (self.acc << 6) | (byte & 0x3F);
        self.next_min = 0x80;
        self.next_max = 0xBF;
        self.needed -= 1;
        if (self.needed == 0) {
            const cp = self.acc;
            self.acc = 0;
            return .{ .cp = cp };
        }
        return .{};
    }

    fn start(self: *Decoder, byte: u8) Result {
        switch (byte) {
            0x00...0x7F => return .{ .cp = byte },
            0xC2...0xDF => {
                self.begin(byte & 0x1F, 1, 0x80, 0xBF);
                return .{};
            },
            0xE0 => {
                self.begin(0, 2, 0xA0, 0xBF);
                return .{};
            },
            0xE1...0xEC, 0xEE...0xEF => {
                self.begin(byte & 0x0F, 2, 0x80, 0xBF);
                return .{};
            },
            0xED => {
                self.begin(0x0D, 2, 0x80, 0x9F);
                return .{};
            },
            0xF0 => {
                self.begin(0, 3, 0x90, 0xBF);
                return .{};
            },
            0xF1...0xF3 => {
                self.begin(byte & 0x07, 3, 0x80, 0xBF);
                return .{};
            },
            0xF4 => {
                self.begin(4, 3, 0x80, 0x8F);
                return .{};
            },
            // 0x80..0xC1 stray continuation / overlong lead, 0xF5..0xFF
            // out of range: one replacement each, no retry.
            else => return .{ .cp = replacement },
        }
    }

    fn begin(self: *Decoder, acc: u21, needed: u3, min: u8, max: u8) void {
        self.acc = acc;
        self.needed = needed;
        self.next_min = min;
        self.next_max = max;
    }
};

fn decodeAll(bytes: []const u8, out: []u21) usize {
    var d: Decoder = .{};
    var n: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const r = d.feed(bytes[i]);
        if (r.cp) |cp| {
            out[n] = cp;
            n += 1;
        }
        if (!r.retry) i += 1;
    }
    return n;
}

test "ascii and multibyte" {
    var out: [16]u21 = undefined;
    const n = decodeAll("aé€😀", &out);
    try std.testing.expectEqualSlices(u21, &[_]u21{ 'a', 0xE9, 0x20AC, 0x1F600 }, out[0..n]);
}

test "overlong rejected" {
    // 0xC0 0xAF is the classic overlong '/': two replacements, no '/'.
    var out: [16]u21 = undefined;
    const n = decodeAll(&[_]u8{ 0xC0, 0xAF }, &out);
    try std.testing.expectEqualSlices(u21, &[_]u21{ replacement, replacement }, out[0..n]);
}

test "surrogate rejected" {
    // ED A0 80 would be U+D800.
    var out: [16]u21 = undefined;
    const n = decodeAll(&[_]u8{ 0xED, 0xA0, 0x80 }, &out);
    try std.testing.expect(n >= 1);
    try std.testing.expectEqual(replacement, out[0]);
}

test "truncated sequence retries next byte" {
    // E2 (expects two continuations) followed by 'A': replacement then 'A'.
    var out: [16]u21 = undefined;
    const n = decodeAll(&[_]u8{ 0xE2, 'A' }, &out);
    try std.testing.expectEqualSlices(u21, &[_]u21{ replacement, 'A' }, out[0..n]);
}

test "stray continuation" {
    var out: [16]u21 = undefined;
    const n = decodeAll(&[_]u8{ 0x80, 'B' }, &out);
    try std.testing.expectEqualSlices(u21, &[_]u21{ replacement, 'B' }, out[0..n]);
}
