//! Pure paste encoding policy. The host supplies authoritative mode state and
//! owns allocation/I/O; this module only transforms a complete byte stream.
//!
//! Control filtering and unbracketed newline handling independently follow
//! xterm's documented defaults and Ghostty's compatible behavior (RFC 0005).

const std = @import("std");

pub const begin = "\x1b[200~";
pub const end = "\x1b[201~";

pub fn encodedLen(input_len: usize, bracketed: bool) !usize {
    if (!bracketed) return input_len;
    return std.math.add(usize, input_len, begin.len + end.len);
}

/// Encode `input` into an exactly-sized or larger caller-owned buffer.
/// Unicode bytes and tabs pass through unchanged. Unsafe controls become
/// spaces; bare LF becomes Return only outside bracketed-paste mode.
pub fn encode(out: []u8, input: []const u8, bracketed: bool) ![]const u8 {
    const needed = try encodedLen(input.len, bracketed);
    if (out.len < needed) return error.OutputTooSmall;

    var cursor: usize = 0;
    if (bracketed) {
        @memcpy(out[cursor..][0..begin.len], begin);
        cursor += begin.len;
    }

    for (input) |byte| {
        out[cursor] = if (unsafeControl(byte))
            ' '
        else if (!bracketed and byte == '\n')
            '\r'
        else
            byte;
        cursor += 1;
    }

    if (bracketed) {
        @memcpy(out[cursor..][0..end.len], end);
        cursor += end.len;
    }
    return out[0..cursor];
}

fn unsafeControl(byte: u8) bool {
    return switch (byte) {
        // xterm's default disallowedPasteControls plus the default tty
        // signal/editing characters it names.
        0x00, // NUL
        0x03, // VINTR
        0x04, // EOT
        0x05, // ENQ
        0x08, // BS
        0x0f, // VDISCARD
        0x11, // VSTART
        0x12, // VREPRINT
        0x13, // VSTOP
        0x15, // VKILL
        0x16, // VLNEXT
        0x17, // VWERASE
        0x1a, // VSUSP
        0x1b, // ESC
        0x1c, // VQUIT
        0x7f, // DEL
        => true,
        else => false,
    };
}

test "bracketed paste filters controls and preserves UTF-8 and newlines" {
    const input = "hello\n\t😀\x1b[201~\x03";
    var out: [64]u8 = undefined;
    const encoded = try encode(&out, input, true);
    try std.testing.expectEqualStrings(
        "\x1b[200~hello\n\t😀 [201~ \x1b[201~",
        encoded,
    );
}

test "unbracketed paste maps LF to Return without collapsing CRLF" {
    var out: [32]u8 = undefined;
    const encoded = try encode(&out, "one\ntwo\r\nthree", false);
    try std.testing.expectEqualStrings("one\rtwo\r\rthree", encoded);
}

test "paste filters the xterm default unsafe control set" {
    const input = [_]u8{
        0x00, 0x03, 0x04, 0x05, 0x08, 0x0f, 0x11, 0x12,
        0x13, 0x15, 0x16, 0x17, 0x1a, 0x1b, 0x1c, 0x7f,
    };
    var out: [input.len]u8 = undefined;
    const encoded = try encode(&out, &input, false);
    try std.testing.expectEqualSlices(u8, " " ** input.len, encoded);
}

test "paste output is bounded and sized before mutation" {
    try std.testing.expectError(error.Overflow, encodedLen(std.math.maxInt(usize), true));
    var out: [2]u8 = .{ 0xaa, 0xbb };
    try std.testing.expectError(error.OutputTooSmall, encode(&out, "abc", false));
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, &out);
}
