//! Window-title presentation: middle ellipsis for long titles (RFC 0005),
//! the Finder/Cursor convention — keep head and tail, drop the middle.
//! Pure and UTF-8 safe so it lives in the headless test suite.

const std = @import("std");

/// Codepoint budget before ellipsizing. NSWindow additionally
/// middle-truncates to the actual title bar width; this cap only bounds
/// absurd titles with a stable, deliberate shape.
pub const default_max_codepoints: usize = 64;

/// Copies an untrusted terminal title as well-formed UTF-8. Invalid bytes are
/// replaced one-for-one with U+FFFD and a full codepoint is never split at the
/// output cap. Keeping this at the session boundary means every native string
/// consumer receives valid UTF-8, even when an OSC payload is hostile.
pub fn sanitizeUtf8Into(input: []const u8, out: []u8) []const u8 {
    var source: usize = 0;
    var dest: usize = 0;
    while (source < input.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(input[source]) catch {
            if (out.len - dest < 3) break;
            @memcpy(out[dest..][0..3], "�");
            dest += 3;
            source += 1;
            continue;
        };
        const valid = if (sequence_len <= input.len - source) valid: {
            _ = std.unicode.utf8Decode(input[source .. source + sequence_len]) catch break :valid false;
            break :valid true;
        } else false;
        if (!valid) {
            if (out.len - dest < 3) break;
            @memcpy(out[dest..][0..3], "�");
            dest += 3;
            source += 1;
            continue;
        }
        if (out.len - dest < sequence_len) break;
        const end = source + sequence_len;
        @memcpy(out[dest..][0..sequence_len], input[source..end]);
        dest += sequence_len;
        source = end;
    }
    return out[0..dest];
}

/// Returns `title` unchanged when it fits, else head + "…" + tail written
/// into `out`. `out` must hold at least `title.len + 3` bytes. Invalid
/// UTF-8 passes through untouched. Callers present session-owned titles,
/// which have already crossed `sanitizeUtf8Into`.
pub fn middleEllipsize(title: []const u8, out: []u8, max_codepoints: usize) []const u8 {
    std.debug.assert(max_codepoints >= 3);

    var offsets_buf: [1024]usize = undefined;
    var i: usize = 0;
    var n: usize = 0;
    while (i < title.len) {
        if (n >= offsets_buf.len) return title; // absurd; give up gracefully
        offsets_buf[n] = i;
        // Manual walk: Utf8Iterator asserts validity, but titles are
        // arbitrary OSC bytes — invalid UTF-8 passes through untouched.
        const len = std.unicode.utf8ByteSequenceLength(title[i]) catch return title;
        if (i + len > title.len) return title;
        i += len;
        n += 1;
    }
    if (n <= max_codepoints) return title;

    const head_cps = (max_codepoints - 1) / 2;
    const tail_cps = max_codepoints - 1 - head_cps;
    const head = title[0..offsets_buf[head_cps]];
    const tail = title[offsets_buf[n - tail_cps]..];

    @memcpy(out[0..head.len], head);
    @memcpy(out[head.len..][0..3], "…");
    @memcpy(out[head.len + 3 ..][0..tail.len], tail);
    return out[0 .. head.len + 3 + tail.len];
}

test "short titles pass through" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hi", middleEllipsize("hi", &buf, 8));
}

test "long titles keep head and tail" {
    var buf: [64]u8 = undefined;
    // 32 codepoints, cap 9 → 4 head + … + 4 tail.
    const got = middleEllipsize("/Users/x/Projects/boringterminal/src/vt", &buf, 9);
    try std.testing.expectEqualStrings("/Use…c/vt", got);
}

test "utf8 boundaries respected" {
    var buf: [64]u8 = undefined;
    // 10 two-byte codepoints; cap at 5 → 2 head + … + 2 tail codepoints.
    const got = middleEllipsize("éééééééééé", &buf, 5);
    try std.testing.expectEqualStrings("éé…éé", got);
}

test "invalid utf8 passes through" {
    var buf: [64]u8 = undefined;
    const junk = &[_]u8{ 'a', 0xFF, 'b' };
    try std.testing.expectEqualSlices(u8, junk, middleEllipsize(junk, &buf, 3));
}

test "title sanitizer preserves Unicode and replaces malformed bytes" {
    var buf: [64]u8 = undefined;
    const input = "😀" ++ [_]u8{0xFF} ++ "👨🏽‍💻";
    try std.testing.expectEqualStrings(
        "😀�👨🏽‍💻",
        sanitizeUtf8Into(input, &buf),
    );
}

test "title sanitizer never splits a codepoint at its cap" {
    var exact: [5]u8 = undefined;
    try std.testing.expectEqualStrings("a😀", sanitizeUtf8Into("a😀b", &exact));

    var short: [4]u8 = undefined;
    try std.testing.expectEqualStrings("a", sanitizeUtf8Into("a😀b", &short));
}
