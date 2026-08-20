//! Terminal semantic tests. Every case goes through `expectBoth`, which
//! feeds the byte stream whole AND byte-at-a-time and asserts identical
//! snapshots — the chunk-split rule from RFC 0008, enforced suite-wide.

const std = @import("std");
const vt = @import("../vt.zig");
const terminal = @import("terminal.zig");
const parser = @import("parser.zig");

const t = std.testing;

const Feed = enum { whole, chunked };

fn snapshot(alloc: std.mem.Allocator, cols: u16, rows: u16, stream: []const u8, how: Feed) ![]u8 {
    var v = try vt.Vt.init(alloc, cols, rows);
    defer v.deinit();
    switch (how) {
        .whole => v.feed(stream),
        .chunked => for (stream) |b| v.feed(&[_]u8{b}),
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const dump = try v.term.dumpText(alloc);
    defer alloc.free(dump);
    try out.appendSlice(alloc, dump);
    var buf: [32]u8 = undefined;
    const cur = try std.fmt.bufPrint(&buf, "\n@{d},{d}", .{ v.term.row, v.term.col });
    try out.appendSlice(alloc, cur);
    return out.toOwnedSlice(alloc);
}

/// Assert the grid (rows joined by \n, right-trimmed) plus final cursor
/// "@row,col", for whole-stream and per-byte feeding.
fn expectBoth(cols: u16, rows: u16, stream: []const u8, expected: []const u8) !void {
    const whole = try snapshot(t.allocator, cols, rows, stream, .whole);
    defer t.allocator.free(whole);
    try t.expectEqualStrings(expected, whole);
    const chunked = try snapshot(t.allocator, cols, rows, stream, .chunked);
    defer t.allocator.free(chunked);
    try t.expectEqualStrings(expected, chunked);
}

test "plain text and newline" {
    try expectBoth(10, 3, "hi\r\nyo", "hi\nyo\n\n@1,2");
}

test "Codex empty SGR parameter resets dim border intensity" {
    const stream = "\x1b[2m│ dim │\x1b[0m\r\n" ++
        "\x1b[2m│ reset \x1b[;m│\x1b[0m";
    inline for (.{ Feed.whole, Feed.chunked }) |how| {
        var v = try vt.Vt.init(t.allocator, 12, 2);
        defer v.deinit();
        switch (how) {
            .whole => v.feed(stream),
            .chunked => for (stream) |b| v.feed(&[_]u8{b}),
        }
        try t.expect(v.term.cellAt(0, 0).flags.dim);
        try t.expect(v.term.cellAt(0, 6).flags.dim);
        try t.expect(v.term.cellAt(1, 0).flags.dim);
        try t.expect(!v.term.cellAt(1, 8).flags.dim);
    }
}

test "lf without cr keeps column" {
    try expectBoth(10, 3, "ab\ncd", "ab\n  cd\n\n@1,4");
}

test "autowrap with pending wrap semantics" {
    // 5 cols: "abcde" fills row 0, cursor pends at last col; "f" wraps.
    try expectBoth(5, 3, "abcde", "abcde\n\n\n@0,4");
    try expectBoth(5, 3, "abcdef", "abcde\nf\n\n@1,1");
}

test "search joins soft wraps but not hard line boundaries" {
    var v = try vt.Vt.init(t.allocator, 5, 3);
    defer v.deinit();
    v.feed("helloWORLD");

    var wrapped = try v.term.searchText(t.allocator, "OWOR");
    defer wrapped.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), wrapped.matches.len);
    try t.expectEqual(@as(u16, 4), wrapped.matches[0].start.col);
    try t.expectEqual(@as(u16, 2), wrapped.matches[0].end.col);
    try t.expect(wrapped.matches[0].start.row_id + 1 == wrapped.matches[0].end.row_id);

    v.feed("\r\nNEXT");
    var hard = try v.term.searchText(t.allocator, "LDNEXT");
    defer hard.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), hard.matches.len);
}

test "search is canonically equivalent and Unicode case folded" {
    var v = try vt.Vt.init(t.allocator, 24, 3);
    defer v.deinit();
    v.feed("Straße Cafe\u{301}");

    var folded = try v.term.searchText(t.allocator, "STRASSE");
    defer folded.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), folded.matches.len);
    try t.expectEqual(@as(u16, 0), folded.matches[0].start.col);
    try t.expectEqual(@as(u16, 5), folded.matches[0].end.col);

    var canonical = try v.term.searchText(t.allocator, "CAFÉ");
    defer canonical.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), canonical.matches.len);
    try t.expectEqual(@as(u16, 7), canonical.matches[0].start.col);
    try t.expectEqual(@as(u16, 10), canonical.matches[0].end.col);
}

test "search maps a wide grapheme to its content cell only" {
    var v = try vt.Vt.init(t.allocator, 8, 2);
    defer v.deinit();
    v.feed("A界B");

    var found = try v.term.searchText(t.allocator, "界");
    defer found.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), found.matches.len);
    try t.expectEqual(@as(u16, 1), found.matches[0].start.col);
    try t.expectEqual(@as(u16, 1), found.matches[0].end.col);
}

test "search ignores storage padding and does not bridge Kitty placeholders" {
    var v = try vt.Vt.init(t.allocator, 8, 2);
    defer v.deinit();
    v.feed("A B");

    var printed_space = try v.term.searchText(t.allocator, "A B");
    defer printed_space.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), printed_space.matches.len);

    var padding = try v.term.searchText(t.allocator, "B ");
    defer padding.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), padding.matches.len);

    const row = v.term.primary.screenRow(0);
    row.cells[1] = .{ .cp = vt.graphics.unicode_placeholder, .flags = .{ .content = true } };
    var image_bridge = try v.term.searchText(t.allocator, "AB");
    defer image_bridge.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), image_bridge.matches.len);
}

test "search is limited to the active alternate screen" {
    var v = try vt.Vt.init(t.allocator, 12, 2);
    defer v.deinit();
    v.feed("primary\x1b[?1049h\x1b[Halternate");

    var hidden = try v.term.searchText(t.allocator, "primary");
    defer hidden.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), hidden.matches.len);

    var visible = try v.term.searchText(t.allocator, "ALTERNATE");
    defer visible.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), visible.matches.len);
}

test "search reports overlapping matches" {
    var v = try vt.Vt.init(t.allocator, 8, 1);
    defer v.deinit();
    v.feed("aaa");
    var found = try v.term.searchText(t.allocator, "aa");
    defer found.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), found.matches.len);
    try t.expectEqual(@as(u16, 0), found.matches[0].start.col);
    try t.expectEqual(@as(u16, 1), found.matches[1].start.col);
}

test "search covers the complete retained history bound" {
    var v = try vt.Vt.init(t.allocator, 32, 8);
    defer v.deinit();
    for (0..10_006) |index| {
        var buf: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "history-{d:0>5}\r\n", .{index});
        v.feed(line);
    }
    v.feed("THE-ONLY-NEEDLE");

    var found = try v.term.searchText(t.allocator, "the-only-needle");
    defer found.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), found.matches.len);
    try t.expect(!found.truncated);
}

test "batched search corpus rejects mixed grid generations" {
    var v = try vt.Vt.init(t.allocator, 12, 3);
    defer v.deinit();
    v.feed("stable");
    const descriptor = v.term.searchCorpusDescriptor();
    var corpus = try vt.search.Corpus.init(t.allocator, descriptor);
    defer corpus.deinit(t.allocator);

    v.feed(" mutation");
    try t.expect(!v.term.copySearchCorpusGraphemes(descriptor, corpus.graphemes));
    try t.expect(!v.term.copySearchCorpusRows(descriptor, &corpus, 0, descriptor.row_count));
}

test "pending wrap cleared by cursor motion" {
    // CUP after filling the row: no spurious wrap on the next print.
    try expectBoth(5, 3, "abcde\x1b[2;1Hf", "abcde\nf\n\n@1,1");
    // CR clears pending wrap.
    try expectBoth(5, 3, "abcde\rX", "Xbcde\n\n\n@0,1");
}

test "autowrap off clips at last column" {
    try expectBoth(5, 3, "\x1b[?7labcdefgh", "abcdh\n\n\n@0,4");
}

test "scroll at bottom" {
    try expectBoth(5, 3, "a\r\nb\r\nc\r\nd", "b\nc\nd\n@2,1");
}

test "cursor movement and clamping" {
    // CUP 2;3 is 1-based: x at (1,2). CUU: y at (0,3). CUB 3: z at (0,1).
    try expectBoth(10, 4, "\x1b[2;3Hx\x1b[Ay\x1b[3Dz\x1b[99;99Hq", " z y\n  x\n\n         q\n@3,9");
}

test "ed and el with bce" {
    // Fill, then ED 0 from middle; erased cells keep current bg.
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 4, 2);
    defer v.deinit();
    v.feed("aaaa" ++ "bbbb" ++ "\x1b[41m\x1b[1;3H\x1b[0J");
    const dump = try v.term.dumpText(alloc);
    defer alloc.free(dump);
    try t.expectEqualStrings("aa\n", dump);
    // Erased cell carries red bg (BCE).
    try t.expectEqual(vt.Color{ .indexed = 1 }, v.term.cellAt(0, 3).bg);
    try t.expectEqual(vt.Color{ .indexed = 1 }, v.term.cellAt(1, 0).bg);
    // Untouched cell keeps default.
    try t.expectEqual(vt.Color.default, v.term.cellAt(0, 0).bg);
}

test "el variants" {
    try expectBoth(6, 2, "abcdef\x1b[1;3H\x1b[K", "ab\n\n@0,2");
    try expectBoth(6, 2, "abcdef\x1b[1;3H\x1b[1K", "   def\n\n@0,2");
    try expectBoth(6, 2, "abcdef\x1b[1;3H\x1b[2K", "\n\n@0,2");
}

test "scroll region with ind and ri" {
    // Margins rows 2-3 (1-based). IND at the bottom margin scrolls only
    // the region: B scrolls out, row 0 and row 3 untouched.
    try expectBoth(5, 4, "\x1b[2;3rA\r\nB\r\nC\x1bD\rD", "A\nC\nD\n\n@2,1");
    // RI at top margin scrolls region down.
    try expectBoth(5, 4, "top\x1b[2;3r\x1b[2;1HX\x1b[2;1H\x1bMY", "top\nY\nX\n\n@1,1");
}

test "il and dl" {
    try expectBoth(5, 4, "a\r\nb\r\nc\x1b[2;1H\x1b[L", "a\n\nb\nc\n@1,0");
    try expectBoth(5, 4, "a\r\nb\r\nc\x1b[1;1H\x1b[M", "b\nc\n\n\n@0,0");
}

test "ich dch ech" {
    try expectBoth(8, 1, "abcdef\x1b[1;3H\x1b[2@", "ab  cdef\n@0,2");
    try expectBoth(8, 1, "abcdef\x1b[1;3H\x1b[2P", "abef\n@0,2");
    try expectBoth(8, 1, "abcdef\x1b[1;3H\x1b[2X", "ab  ef\n@0,2");
}

test "tabs default and custom" {
    try expectBoth(20, 1, "\tx", "        x\n@0,9");
    // Clear all stops, set one at col 4 (0-based col 3 via CUF).
    try expectBoth(20, 1, "\x1b[3g\x1b[1;4H\x1bH\x1b[1;1H\ty", "   y\n@0,4");
    // CBT goes back two stops (col 8, then col 0); print overwrites 'a'
    // but leaves 'b'.
    try expectBoth(20, 1, "ab\th\x1b[2Zc", "cb      h\n@0,1");
}

test "alt screen 1049 round trip" {
    // Content on primary survives an alt-screen excursion; cursor restored.
    try expectBoth(10, 3, "hello\x1b[?1049halt!\x1b[?1049l", "hello\n\n\n@0,5");
    // While on alt, primary content is not visible.
    try expectBoth(10, 3, "hello\x1b[?1049h\x1b[Hworld", "world\n\n\n@0,5");
}

test "decsc decrc" {
    try expectBoth(10, 3, "ab\x1b7cd\x1b8X", "abXd\n\n\n@0,3");
}

test "sgr colors reach cells" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 8, 1);
    defer v.deinit();
    v.feed("\x1b[1;31ma\x1b[38;5;196mb\x1b[38;2;1;2;3mc\x1b[38:2:9:8:7md\x1b[me");
    try t.expect(v.term.cellAt(0, 0).flags.bold);
    try t.expectEqual(vt.Color{ .indexed = 1 }, v.term.cellAt(0, 0).fg);
    try t.expectEqual(vt.Color{ .indexed = 196 }, v.term.cellAt(0, 1).fg);
    try t.expectEqual(vt.Color{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, v.term.cellAt(0, 2).fg);
    try t.expectEqual(vt.Color{ .rgb = .{ .r = 9, .g = 8, .b = 7 } }, v.term.cellAt(0, 3).fg);
    try t.expectEqual(vt.Color.default, v.term.cellAt(0, 4).fg);
    try t.expect(!v.term.cellAt(0, 4).flags.bold);
}

test "sgr underline color is semantic cell state" {
    var v = try vt.Vt.init(t.allocator, 4, 1);
    defer v.deinit();
    v.feed("\x1b[4;58;5;77ma\x1b[58:2:1:2:3mb\x1b[59mc");
    try t.expectEqual(vt.Color{ .indexed = 77 }, v.term.cellAt(0, 0).underline_color);
    try t.expectEqual(
        vt.Color{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
        v.term.cellAt(0, 1).underline_color,
    );
    try t.expectEqual(vt.Color.default, v.term.cellAt(0, 2).underline_color);
}

test "sgr bright and reset pairs" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 8, 1);
    defer v.deinit();
    v.feed("\x1b[93;4ma\x1b[24;107mb");
    try t.expectEqual(vt.Color{ .indexed = 11 }, v.term.cellAt(0, 0).fg);
    try t.expect(v.term.cellAt(0, 0).flags.underline);
    try t.expect(!v.term.cellAt(0, 1).flags.underline);
    try t.expectEqual(vt.Color{ .indexed = 15 }, v.term.cellAt(0, 1).bg);
}

test "dec special graphics" {
    // Final q lands on the last column: pending wrap clamps the cursor.
    try expectBoth(6, 1, "\x1b(0qqlk\x1b(B q", "──┌┐ q\n@0,5");
}

test "wide char occupies two cells" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 6, 2);
    defer v.deinit();
    v.feed("汉x");
    try t.expectEqual(@as(u21, 0x6C49), v.term.cellAt(0, 0).cp);
    try t.expect(v.term.cellAt(0, 0).flags.wide);
    try t.expect(v.term.cellAt(0, 1).flags.wide_spacer);
    try t.expectEqual(@as(u21, 'x'), v.term.cellAt(0, 2).cp);
    const dump = try v.term.dumpText(alloc);
    defer alloc.free(dump);
    try t.expectEqualStrings("汉x\n", dump);
}

test "pinned Unicode widths keep the Codex sparkle row aligned" {
    try t.expectEqual(@as(u2, 1), terminal.charWidth('A'));
    try t.expectEqual(@as(u2, 0), terminal.charWidth(0x0301)); // combining acute
    try t.expectEqual(@as(u2, 2), terminal.charWidth(0x6c49)); // CJK
    try t.expectEqual(@as(u2, 2), terminal.charWidth(0x2728)); // ✨
    try t.expectEqual(@as(u2, 1), terminal.charWidth(0x2764)); // text-default heart

    try expectBoth(6, 1, "✨x", "✨x\n@0,3");
}

test "legacy mode retains combining suffix without changing cursor width" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 8, 2);
    defer v.deinit();
    v.feed("e\u{0301}x");
    try t.expectEqual(@as(u16, 2), v.term.col);
    const cell = v.term.cellAt(0, 0);
    try t.expect(cell.hasGrapheme());
    try t.expectEqualSlices(u21, &.{0x0301}, v.term.cellGrapheme(cell));
    const dump = try v.term.dumpText(alloc);
    defer alloc.free(dump);
    try t.expectEqualStrings("e\u{0301}x\n", dump);
}

test "mode 2027 clusters ZWJ emoji while legacy mode advances codepoints" {
    const alloc = t.allocator;
    const farmer = "🧑‍🌾";

    var legacy = try vt.Vt.init(alloc, 10, 2);
    defer legacy.deinit();
    legacy.feed(farmer);
    try t.expectEqual(@as(u16, 4), legacy.term.col);

    var full = try vt.Vt.init(alloc, 10, 2);
    defer full.deinit();
    full.feed("\x1b[?2027h" ++ farmer);
    try t.expectEqual(@as(u16, 2), full.term.col);
    const cell = full.term.cellAt(0, 0);
    try t.expect(cell.flags.wide);
    try t.expectEqualSlices(u21, &.{ 0x200d, 0x1f33e }, full.term.cellGrapheme(cell));
    const dump = try full.term.dumpText(alloc);
    defer alloc.free(dump);
    try t.expectEqualStrings(farmer ++ "\n", dump);
}

test "mode 2027 applies VS16 widening and VS15 narrowing" {
    const alloc = t.allocator;
    var wide = try vt.Vt.init(alloc, 8, 2);
    defer wide.deinit();
    wide.feed("\x1b[?2027h❤\u{fe0f}x");
    try t.expectEqual(@as(u16, 3), wide.term.col);
    try t.expect(wide.term.cellAt(0, 0).flags.wide);
    try t.expect(wide.term.cellAt(0, 1).flags.wide_spacer);
    try t.expectEqual(@as(u21, 'x'), wide.term.cellAt(0, 2).cp);

    var narrow = try vt.Vt.init(alloc, 8, 2);
    defer narrow.deinit();
    narrow.feed("\x1b[?2027h⚡\u{fe0e}x");
    try t.expectEqual(@as(u16, 2), narrow.term.col);
    try t.expect(!narrow.term.cellAt(0, 0).flags.wide);
    try t.expect(!narrow.term.cellAt(0, 1).flags.wide_spacer);
    try t.expectEqual(@as(u21, 'x'), narrow.term.cellAt(0, 1).cp);
}

test "mode 2027 widens a pending edge cluster by moving it whole" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 3, 2);
    defer v.deinit();
    v.feed("\x1b[?2027hab❤\u{fe0f}");
    try t.expect(v.term.primary.screenRow(0).wrapped);
    try t.expect(v.term.cellAt(0, 2).flags.wide_pad);
    try t.expectEqual(@as(u21, 0x2764), v.term.cellAt(1, 0).cp);
    try t.expect(v.term.cellAt(1, 0).flags.wide);
    try t.expect(v.term.cellAt(1, 1).flags.wide_spacer);
    try t.expectEqual(@as(u16, 1), v.term.row);
    try t.expectEqual(@as(u16, 2), v.term.col);
    const dump = try v.term.dumpText(alloc);
    defer alloc.free(dump);
    try t.expectEqualStrings("ab\n❤\u{fe0f}", dump);
}

test "mode 2027 pairs regional indicators and caps hostile suffixes" {
    const alloc = t.allocator;
    var flag = try vt.Vt.init(alloc, 10, 2);
    defer flag.deinit();
    flag.feed("\x1b[?2027h🇮🇳🇺");
    try t.expectEqual(@as(u16, 3), flag.term.col);
    try t.expectEqualSlices(u21, &.{0x1f1f3}, flag.term.cellGrapheme(flag.term.cellAt(0, 0)));

    var capped = try vt.Vt.init(alloc, 10, 2);
    defer capped.deinit();
    capped.feed("\x1b[?2027he");
    for (0..80) |_| capped.feed("\u{0301}");
    try t.expectEqual(@as(u8, vt.max_grapheme_codepoints - 1), capped.term.cellAt(0, 0).grapheme_len);
    try t.expectEqual(@as(u16, 1), capped.term.col);
}

test "mode 2027 handles skin tones Hangul and ZWJ versus zero width space" {
    const alloc = t.allocator;
    var emoji = try vt.Vt.init(alloc, 10, 2);
    defer emoji.deinit();
    emoji.feed("\x1b[?2027h👨🏽x");
    try t.expectEqual(@as(u16, 3), emoji.term.col);
    try t.expectEqualSlices(u21, &.{0x1f3fd}, emoji.term.cellGrapheme(emoji.term.cellAt(0, 0)));

    var hangul = try vt.Vt.init(alloc, 10, 2);
    defer hangul.deinit();
    hangul.feed("\x1b[?2027h가x");
    try t.expect(hangul.term.cellAt(0, 0).hasGrapheme());
    try t.expectEqualSlices(u21, &.{0x1161}, hangul.term.cellGrapheme(hangul.term.cellAt(0, 0)));

    var zero = try vt.Vt.init(alloc, 10, 2);
    defer zero.deinit();
    zero.feed("\x1b[?2027he\u{200b}x"); // ZWSP is a grapheme break: ignore it.
    try t.expect(!zero.term.cellAt(0, 0).hasGrapheme());
    zero.feed("\r\x1b[2Ke\u{200d}x"); // ZWJ is retained on the base.
    try t.expectEqualSlices(u21, &.{0x200d}, zero.term.cellGrapheme(zero.term.cellAt(0, 0)));
}

test "mode 2027 is set reset and queryable" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 8, 2);
    defer v.deinit();
    v.feed("\x1b[?2027h\x1b[?2027$p\x1b[?2027l\x1b[?2027$p");
    const actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 2), actions.len);
    try t.expectEqualStrings("\x1b[?2027;1$y", actions[0].pty_write);
    try t.expectEqualStrings("\x1b[?2027;2$y", actions[1].pty_write);
    v.term.clearActions();
}

test "grapheme suffixes survive arena compaction reflow and selection" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 8, 3);
    defer v.deinit();
    v.feed("\x1b[?2027he\u{0301} x\u{0308}");

    // Force the next append through the tracing compactor while both earlier
    // offsets are live, then exercise memcpy-based reflow on the new offsets.
    v.term.grapheme_gc_at = 1;
    v.feed(" y\u{0302}");
    try v.term.resize(4, 3);
    try v.term.resize(8, 3);

    const dump = try v.term.dumpText(alloc);
    defer alloc.free(dump);
    try t.expectEqualStrings("e\u{0301} x\u{0308} y\u{0302}\n\n", dump);

    v.term.selectionStart(0, 0, .char);
    v.term.selectionDrag(0, 5);
    const selected = (try v.term.selectionText(alloc)).?;
    defer alloc.free(selected);
    try t.expectEqualStrings("e\u{0301} x\u{0308} y\u{0302}", selected);
}

test "wide char at last column wraps whole" {
    // 5 cols: "abcd" then wide char cannot straddle; lands on next row.
    try expectBoth(5, 2, "abcd汉", "abcd\n汉\n@1,2");
}

test "rep repeats last printed" {
    try expectBoth(10, 1, "ab\x1b[3b", "abbbb\n@0,5");
}

test "decaln fills" {
    try expectBoth(3, 2, "\x1b#8", "EEE\nEEE\n@0,0");
}

test "origin mode confines and offsets" {
    // Margins 2-3; origin on; CUP 1;1 lands at absolute row 2.
    try expectBoth(5, 4, "\x1b[2;3r\x1b[?6hX", "\nX\n\n\n@1,1");
    // CUP beyond region clamps to bottom margin.
    try expectBoth(5, 4, "\x1b[2;3r\x1b[?6h\x1b[9;1HY", "\n\nY\n\n@2,1");
}

test "ris resets everything visible" {
    try expectBoth(5, 2, "ab\x1b[41m\x1b[?7l\x1bccd", "cd\n\n@0,2");
}

test "resize reflows, bottom-anchors, and feeds scrollback" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 6, 3);
    defer v.deinit();
    v.feed("abcdef\r\nghijkl\r\nmnop");
    try v.term.resize(4, 2);
    // Hard lines rewrap to 4 cols: abcd|ef ghij|kl mnop|␣ — screen shows
    // the bottom, the rest is scrollback (RFC 0003). The cursor sat at
    // offset 4 of "mnop", which is exactly the new width: it takes the
    // post-wrap position (next row, col 0) so shell repaint math holds.
    const dump = try v.term.dumpText(alloc);
    defer alloc.free(dump);
    try t.expectEqualStrings("mnop\n", dump);
    try t.expectEqual(@as(usize, 4), v.term.scrollbackLen());
    try t.expectEqual(@as(u16, 1), v.term.row);
    try t.expectEqual(@as(u16, 0), v.term.col);
    // Viewport reads history (clamped to scrollback).
    v.term.scrollViewport(99);
    try t.expectEqual(@as(u21, 'a'), v.term.viewCellAt(0, 0).cp);
    try t.expectEqual(@as(u21, 'e'), v.term.viewCellAt(1, 0).cp);
    v.term.viewportToBottom();
}

test "actions: bell title and replies" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 3);
    defer v.deinit();
    v.feed("\x07\x1b]0;my title\x07\x1b[6n\x1b[5n");
    const actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 4), actions.len);
    try t.expectEqual(terminal.Action.bell, actions[0]);
    try t.expectEqualStrings("my title", actions[1].set_title);
    try t.expectEqualStrings("\x1b[1;1R", actions[2].pty_write);
    try t.expectEqualStrings("\x1b[0n", actions[3].pty_write);
    v.term.clearActions();
    v.feed("\x1b[c");
    const more = v.term.drainActions();
    try t.expectEqual(@as(usize, 1), more.len);
    try t.expectEqualStrings("\x1b[?6c", more[0].pty_write);
    v.term.clearActions();
}

test "cpr respects origin mode" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 4);
    defer v.deinit();
    v.feed("\x1b[2;3r\x1b[?6h\x1b[6n");
    const actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 1), actions.len);
    try t.expectEqualStrings("\x1b[1;1R", actions[0].pty_write);
    v.term.clearActions();
}

test "modes surface to host" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 3);
    defer v.deinit();
    v.feed("\x1b[?1h\x1b[?2004h\x1b[?25l");
    try t.expect(v.term.modes.cursor_keys);
    try t.expect(v.term.modes.bracketed_paste);
    try t.expect(!v.term.modes.cursor_visible);
    v.feed("\x1b[?1l\x1b[?2004l\x1b[?25h");
    try t.expect(!v.term.modes.cursor_keys);
    try t.expect(!v.term.modes.bracketed_paste);
    try t.expect(v.term.modes.cursor_visible);
}

test "kitty keyboard negotiation is bounded per-screen and chunk-split safe" {
    inline for (.{ Feed.whole, Feed.chunked }) |how| {
        const alloc = t.allocator;
        var v = try vt.Vt.init(alloc, 10, 3);
        defer v.deinit();
        const stream = "\x1b[?u" ++ // primary starts reset
            "\x1b[>31u\x1b[?u" ++ // all five enhancements are supported
            "\x1b[=2;3u\x1b[?u" ++ // subtract report-events
            "\x1b[?1049h\x1b[?u" ++ // alternate has an independent stack
            "\x1b[>2u\x1b[?u" ++
            "\x1b[?1049l\x1b[?u" ++
            "\x1b[<u\x1b[?u" ++
            "\x1b[>1u\x1b[?1049h\x1b[>2u" ++
            "\x1bc\x1b[?u\x1b[?1049h\x1b[?u"; // RIS clears both stacks
        switch (how) {
            .whole => v.feed(stream),
            .chunked => for (stream) |byte| v.feed(&[_]u8{byte}),
        }
        const expected = [_][]const u8{
            "\x1b[?0u",
            "\x1b[?31u",
            "\x1b[?29u",
            "\x1b[?0u",
            "\x1b[?2u",
            "\x1b[?29u",
            "\x1b[?0u",
            "\x1b[?0u",
            "\x1b[?0u",
        };
        const actions = v.term.drainActions();
        try t.expectEqual(expected.len, actions.len);
        for (actions, expected) |action, reply| try t.expectEqualStrings(reply, action.pty_write);
        v.term.clearActions();
    }
}

test "kitty keyboard malformed controls are consumed without state changes" {
    var v = try vt.Vt.init(t.allocator, 10, 3);
    defer v.deinit();
    v.feed("\x1b[>1;2u\x1b[=3;9u\x1b[?1u\x1b[?u");
    try t.expectEqual(@as(u8, 0), v.term.keyboardFlags().bits());
    const actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 1), actions.len);
    try t.expectEqualStrings("\x1b[?0u", actions[0].pty_write);
    v.term.clearActions();
}

test "kitty graphics probe and chunked terminal-browser frame leave pure actions" {
    const alloc = std.testing.allocator;
    var v = try vt.Vt.init(alloc, 20, 5);
    defer v.deinit();

    v.feed("\x1b_Gi=4207,a=q,t=d,f=24,s=1,v=1;AAAA\x1b\\");
    var actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 1), actions.len);
    const query = actions[0].graphics.load;
    try t.expect(query.query);
    try t.expectEqual(@as(u32, 4207), query.image_id);
    try t.expectEqualStrings("AAAA", query.encoded);
    v.term.clearActions();

    v.feed("\x1b[?1049h\x1b[H");
    const first = "\x1b_Ga=T,f=32,o=z,s=1,v=1,t=d,i=7,p=1,C=1,q=2,m=1;eJ\x1b\\";
    const last = "\x1b_Gm=0;xjYGBgAAAABAAB\x1b\\";
    for (first) |byte| v.feed(&.{byte});
    try t.expectEqual(@as(usize, 0), v.term.drainActions().len);
    for (last) |byte| v.feed(&.{byte});
    actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 1), actions.len);
    const load = &actions[0].graphics.load;
    try t.expect(load.display);
    try t.expect(load.on_alt);
    try t.expect(load.cursor_no_move);
    try t.expectEqualStrings("eJxjYGBgAAAABAAB", load.encoded);
    v.term.setPixelSize(160, 80);
    try v.term.graphicsCommitLoad(load, .{
        .image_id = 7,
        .image_number = 0,
        .generation = 11,
        .width = 1,
        .height = 1,
    });
    try t.expectEqual(@as(usize, 1), v.term.graphicsPlacements().len);
    try t.expectEqual(@as(u64, 11), v.term.graphicsPlacements()[0].generation);
    v.term.clearActions();

    v.feed("\x1b[2J");
    try t.expectEqual(@as(usize, 0), v.term.graphicsPlacements().len);
}

test "Kitty put cursor movement precedes following text" {
    var v = try vt.Vt.init(t.allocator, 10, 5);
    defer v.deinit();
    v.term.setPixelSize(100, 100);
    for ("\x1b_Ga=p,i=7,p=4,c=2,r=2\x1b\\") |byte| v.feed(&.{byte});
    const actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 1), actions.len);
    const put = &actions[0].graphics.put;
    try v.term.graphicsCommitPut(put, .{
        .image_id = 7,
        .image_number = 0,
        .generation = 3,
        .width = 1,
        .height = 1,
    });
    v.term.clearActions();
    v.feed("X");
    try t.expectEqual(@as(u16, 2), v.term.row);
    try t.expectEqual(@as(u16, 3), v.term.col);
    try t.expectEqual(@as(u21, 'X'), v.term.viewCellAt(2, 2).cp);
    try t.expectEqual(@as(usize, 1), v.term.graphicsPlacements().len);
    try t.expectEqual(@as(u64, 0), v.term.graphicsPlacements()[0].row_id);
    try t.expectEqual(@as(u16, 0), v.term.graphicsPlacements()[0].col);
}

test "Kitty virtual placement is chunk-safe cursor-neutral and grid-owned" {
    var v = try vt.Vt.init(t.allocator, 10, 5);
    defer v.deinit();
    v.term.setPixelSize(100, 100);
    for ("\x1b_Ga=T,U=1,f=32,s=1,v=1,t=d,i=42,p=7,c=2,r=2;AAAA\x1b\\") |byte|
        v.feed(&.{byte});
    const actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 1), actions.len);
    const load = &actions[0].graphics.load;
    try t.expect(load.virtual);
    try v.term.graphicsCommitLoad(load, .{
        .image_id = 42,
        .image_number = 0,
        .generation = 3,
        .width = 100,
        .height = 50,
    });
    v.term.clearActions();
    try t.expectEqual(@as(u16, 0), v.term.row);
    try t.expectEqual(@as(u16, 0), v.term.col);
    try t.expect(v.term.graphicsPlacements()[0].virtual);

    for ("\x1b[38;5;42;58;5;7m\u{10EEEE}\u{0305}\u{0305}\u{10EEEE}\u{0305}\u{030D}") |byte|
        v.feed(&.{byte});
    const first = v.term.viewCellAt(0, 0);
    try t.expectEqual(vt.graphics.unicode_placeholder, first.cp);
    try t.expectEqual(@as(u8, 2), first.grapheme_len);
    try t.expectEqual(vt.Color{ .indexed = 7 }, first.underline_color);
    try t.expectEqual(@as(u16, 2), v.term.col);

    v.feed("\x1b[2J");
    try t.expectEqual(@as(usize, 1), v.term.graphicsPlacements().len);
    v.feed("\x1b_Ga=d,d=a\x1b\\");
    const spatial_delete = v.term.drainActions()[0].graphics.delete;
    _ = v.term.graphicsDelete(spatial_delete, null);
    v.term.clearActions();
    try t.expectEqual(@as(usize, 1), v.term.graphicsPlacements().len);
    v.feed("\x1b_Ga=d,d=i,i=42,p=7\x1b\\");
    const id_delete = v.term.drainActions()[0].graphics.delete;
    _ = v.term.graphicsDelete(id_delete, 42);
    try t.expectEqual(@as(usize, 0), v.term.graphicsPlacements().len);
}

test "XTWINOPS pixel reports use host geometry and never synthesize it" {
    var v = try vt.Vt.init(t.allocator, 10, 3);
    defer v.deinit();

    v.feed("\x1b[14t\x1b[16t");
    try t.expectEqual(@as(usize, 0), v.term.drainActions().len);

    v.term.setPixelSize(100, 60);
    v.feed("\x1b[14t\x1b[16t");
    const actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 2), actions.len);
    try t.expectEqualStrings("\x1b[4;60;100t", actions[0].pty_write);
    try t.expectEqualStrings("\x1b[6;20;10t", actions[1].pty_write);
}

test "focus reporting mode is set reset queryable and chunk-split safe" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 3);
    defer v.deinit();

    for ("\x1b[?1004h\x1b[?1004$p") |byte| v.feed(&[_]u8{byte});
    try t.expect(v.term.modes.focus_reporting);
    var actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 1), actions.len);
    try t.expectEqualStrings("\x1b[?1004;1$y", actions[0].pty_write);
    v.term.clearActions();

    v.feed("\x1b[?1004l\x1b[?1004$p");
    try t.expect(!v.term.modes.focus_reporting);
    actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 1), actions.len);
    try t.expectEqualStrings("\x1b[?1004;2$y", actions[0].pty_write);
    v.term.clearActions();
}

test "mouse tracking and mutually exclusive SGR formats are queryable" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 3);
    defer v.deinit();

    // Enabling a new tracking selector replaces the old one; SGR encoding
    // remains independently active. Feed byte-at-a-time for the parser rule.
    for ("\x1b[?1000h\x1b[?1006h\x1b[?1002h") |byte| v.feed(&[_]u8{byte});
    try t.expectEqual(vt.mouse.Tracking.button, v.term.modes.mouse_tracking);
    try t.expectEqual(vt.mouse.Encoding.sgr, v.term.modes.mouse_encoding);

    // Resetting an inactive selector must not disable the active one.
    v.feed("\x1b[?1000l\x1b[?1000$p\x1b[?1002$p\x1b[?1006$p\x1b[?1016$p");
    try t.expectEqual(vt.mouse.Tracking.button, v.term.modes.mouse_tracking);
    const actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 4), actions.len);
    try t.expectEqualStrings("\x1b[?1000;2$y", actions[0].pty_write);
    try t.expectEqualStrings("\x1b[?1002;1$y", actions[1].pty_write);
    try t.expectEqualStrings("\x1b[?1006;1$y", actions[2].pty_write);
    try t.expectEqualStrings("\x1b[?1016;2$y", actions[3].pty_write);
    v.term.clearActions();

    // Selecting pixels resets the cell-format report. Resetting the inactive
    // 1006 selector must leave pixels active.
    v.feed("\x1b[?1016h\x1b[?1006l\x1b[?1006$p\x1b[?1016$p");
    try t.expectEqual(vt.mouse.Encoding.sgr_pixels, v.term.modes.mouse_encoding);
    const pixel_actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 2), pixel_actions.len);
    try t.expectEqualStrings("\x1b[?1006;2$y", pixel_actions[0].pty_write);
    try t.expectEqualStrings("\x1b[?1016;1$y", pixel_actions[1].pty_write);
    v.term.clearActions();

    v.feed("\x1b[?1002l\x1b[?1016l");
    try t.expectEqual(vt.mouse.Tracking.none, v.term.modes.mouse_tracking);
    try t.expectEqual(vt.mouse.Encoding.legacy, v.term.modes.mouse_encoding);
}

test "DECRQM reports stored modes and rejects unsupported inventory honestly" {
    var v = try vt.Vt.init(t.allocator, 10, 3);
    defer v.deinit();

    v.feed("\x1b[?7$p\x1b[?25l\x1b[?25$p\x1b[4$p\x1b[?3$p\x1b[?1005$p\x1b[?1015$p\x1b[?1048$p\x1b[?9999$p");
    const actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 8), actions.len);
    try t.expectEqualStrings("\x1b[?7;1$y", actions[0].pty_write);
    try t.expectEqualStrings("\x1b[?25;2$y", actions[1].pty_write);
    try t.expectEqualStrings("\x1b[4;0$y", actions[2].pty_write);
    try t.expectEqualStrings("\x1b[?3;4$y", actions[3].pty_write);
    try t.expectEqualStrings("\x1b[?1005;4$y", actions[4].pty_write);
    try t.expectEqualStrings("\x1b[?1015;4$y", actions[5].pty_write);
    try t.expectEqualStrings("\x1b[?1048;0$y", actions[6].pty_write);
    try t.expectEqualStrings("\x1b[?9999;0$y", actions[7].pty_write);
}

test "XTGETTCAP replies with truthful ordered capabilities" {
    const alloc = t.allocator;
    const request = "\x1bP+q544E;436F;524742;6B63757531\x1b\\";
    const expected = "\x1bP1+r" ++
        "544E=787465726D2D323536636F6C6F72;" ++
        "436F=323536;" ++
        "524742=38;" ++
        "6B63757531=1B4F41\x1b\\";

    inline for (.{ Feed.whole, Feed.chunked }) |how| {
        var v = try vt.Vt.init(alloc, 10, 3);
        defer v.deinit();
        switch (how) {
            .whole => v.feed(request),
            .chunked => for (request) |byte| v.feed(&[_]u8{byte}),
        }
        const actions = v.term.drainActions();
        try t.expectEqual(@as(usize, 1), actions.len);
        try t.expectEqualStrings(expected, actions[0].pty_write);
    }
}

test "XTGETTCAP rejects malformed requests and stops at unsupported names" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 3);
    defer v.deinit();

    v.feed("\x1bP+q5A5A\x1b\\"); // unknown first
    var actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 1), actions.len);
    try t.expectEqualStrings("\x1bP0+r\x1b\\", actions[0].pty_write);
    v.term.clearActions();

    v.feed("\x1bP+q544e;5A5A;436F\x1b\\"); // valid, unknown, never reaches Co
    actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 1), actions.len);
    try t.expectEqualStrings(
        "\x1bP1+r544E=787465726D2D323536636F6C6F72\x1b\\",
        actions[0].pty_write,
    );
    v.term.clearActions();

    v.feed("\x1bP+q5\x1b\\\x1bP1+q544E\x1b\\\x1bP+p544E\x1b\\");
    actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 1), actions.len);
    try t.expectEqualStrings("\x1bP0+r\x1b\\", actions[0].pty_write);
}

test "DECRQSS reports SGR and vertical margins whole and byte split" {
    const alloc = t.allocator;
    const request =
        "\x1bP$qm\x1b\\" ++
        "\x1b[1;2;3;4;7;8;9;38:5:42;48:2::1:2:3;58:5:7m" ++
        "\x1bP$qm\x1b\\" ++
        "\x1b[5;6r\x1bP$qr\x1b\\";
    const expected = [_][]const u8{
        "\x1bP1$r0m\x1b\\",
        "\x1bP1$r0;1;2;3;4;7;8;9;38:5:42;48:2::1:2:3;58:5:7m\x1b\\",
        "\x1bP1$r5;6r\x1b\\",
    };

    inline for (.{ Feed.whole, Feed.chunked }) |how| {
        var v = try vt.Vt.init(alloc, 20, 10);
        defer v.deinit();
        switch (how) {
            .whole => v.feed(request),
            .chunked => for (request) |byte| v.feed(&[_]u8{byte}),
        }
        const actions = v.term.drainActions();
        try t.expectEqual(expected.len, actions.len);
        for (actions, expected) |action, reply| try t.expectEqualStrings(reply, action.pty_write);
    }
}

test "DECRQSS rejects unsupported settings and recovers after overflow" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 3);
    defer v.deinit();

    // A well-formed request for state we do not own receives DECRPSS invalid.
    // Parameters before $q form a different, unrecognized DCS and get no reply.
    v.feed("\x1bP$q q\x1b\\\x1bP1$qm\x1b\\\x1bP$qbogus\x1b\\");
    var actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 2), actions.len);
    for (actions) |action| try t.expectEqualStrings("\x1bP0$r\x1b\\", action.pty_write);
    v.term.clearActions();

    var oversized: std.ArrayList(u8) = .empty;
    defer oversized.deinit(alloc);
    try oversized.appendSlice(alloc, "\x1bP$q");
    try oversized.appendNTimes(alloc, 'x', parser.max_dcs_bytes + 1);
    try oversized.appendSlice(alloc, "\x1b\\\x1bP$qm\x1b\\");
    v.feed(oversized.items);
    actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 1), actions.len);
    try t.expectEqualStrings("\x1bP1$r0m\x1b\\", actions[0].pty_write);
}

test "DECRQSS SGR maximum stored rendition fits the fixed reply" {
    var v = try vt.Vt.init(t.allocator, 10, 3);
    defer v.deinit();
    v.feed("\x1b[1;2;3;4;7;8;9;38:2::255:254:253;48:2::252:251:250;58:2::249:248:247m" ++
        "\x1bP$qm\x1b\\");
    const actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 1), actions.len);
    try t.expectEqualStrings(
        "\x1bP1$r0;1;2;3;4;7;8;9;38:2::255:254:253;48:2::252:251:250;58:2::249:248:247m\x1b\\",
        actions[0].pty_write,
    );
}

test "synchronized output mode, epoch, query, timeout, and resize reset" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 3);
    defer v.deinit();

    // Codex-shaped frame: the cursor visits an intermediate status position
    // while BSU is active, then ends at the composer before ESU.
    v.feed("\x1b[?2026h\x1b[2;5Hwork");
    try t.expect(v.term.modes.synchronized_output);
    try t.expectEqual(@as(u64, 1), v.term.sync_output_epoch);
    try t.expectEqual(@as(u16, 1), v.term.row);

    v.feed("\x1b[?2026$p");
    const active_report = v.term.drainActions();
    try t.expectEqual(@as(usize, 1), active_report.len);
    try t.expectEqualStrings("\x1b[?2026;1$y", active_report[0].pty_write);
    v.term.clearActions();

    v.feed("\x1b[?2026h"); // repeated BSU re-arms the host watchdog
    try t.expectEqual(@as(u64, 2), v.term.sync_output_epoch);
    v.feed("\x1b[3;2H\x1b[?2026l");
    try t.expect(!v.term.modes.synchronized_output);
    try t.expectEqual(@as(u16, 2), v.term.row);
    try t.expectEqual(@as(u16, 1), v.term.col);

    v.feed("\x1b[?2026$p");
    const inactive_report = v.term.drainActions();
    try t.expectEqualStrings("\x1b[?2026;2$y", inactive_report[0].pty_write);
    v.term.clearActions();

    v.feed("\x1b[?2026h");
    v.term.forceEndSynchronizedOutput();
    try t.expect(!v.term.modes.synchronized_output);
    v.feed("\x1b[?2026h");
    try v.term.resize(11, 3);
    try t.expect(!v.term.modes.synchronized_output);
    v.feed("\x1b[?2026h");
    v.term.forceEndSynchronizedOutput(); // pixel-only resize host path
    try t.expect(!v.term.modes.synchronized_output);
}

test "synchronized output sequences are chunk-split safe" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 3);
    defer v.deinit();
    for ("\x1b[?2026h\x1b[2;5Hwork\x1b[3;2H\x1b[?2026l") |byte| {
        v.feed(&[_]u8{byte});
    }
    try t.expect(!v.term.modes.synchronized_output);
    try t.expectEqual(@as(u64, 1), v.term.sync_output_epoch);
    try t.expectEqual(@as(u16, 2), v.term.row);
    try t.expectEqual(@as(u16, 1), v.term.col);
}

test "unknown sequences are consumed silently" {
    // Unknown CSI, OSC, DCS: nothing printed, nothing crashes.
    try expectBoth(10, 2, "a\x1b[999zb\x1b]777;x;y\x07c\x1bP1;2|junk\x1b\\d", "abcd\n\n@0,4");
}

test "vim-like smoke stream" {
    const stream = "\x1b[?1049h\x1b[H\x1b[2J\x1b[1;1H~ line1\x1b[2;1H~\x1b[3;1H~\x1b[1;3Hhello\x1b[?1049l";
    try expectBoth(12, 3, stream, "\n\n\n@0,0");
}

test "decrqcra checksums rectangles" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 4, 2);
    defer v.deinit();
    // "AB" on row 1; rest blank. Checksum of full screen vs 1x1 rect.
    v.feed("AB\x1b[1;1;1;1;1;2*y\x1b[5;1;1;1;1;1*y");
    const actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 2), actions.len);
    // 'A'+'B' = 0x0083 (modern xterm positive sums).
    try t.expectEqualStrings("\x1bP1!~0083\x1b\\", actions[0].pty_write);
    // 'A' = 0x0041.
    try t.expectEqualStrings("\x1bP5!~0041\x1b\\", actions[1].pty_write);
    v.term.clearActions();
    // Attributes weigh in: bold 'A' adds 0x80.
    v.feed("\x1b[2;1H\x1b[1mA\x1b[m\x1b[9;1;2;1;2;1*y");
    const more = v.term.drainActions();
    // bold 'A' = 0x41 + 0x80 = 0x00C1.
    try t.expectEqualStrings("\x1bP9!~00C1\x1b\\", more[0].pty_write);
    v.term.clearActions();
}

test "xtwinops reports and resize action" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 4, 2);
    defer v.deinit();
    v.feed("\x1b[18t\x1b[8;10;20t\x1b[11t");
    const actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 3), actions.len);
    try t.expectEqualStrings("\x1b[8;2;4t", actions[0].pty_write);
    try t.expectEqual(@as(u16, 20), actions[1].resize_request.cols);
    try t.expectEqual(@as(u16, 10), actions[1].resize_request.rows);
    try t.expectEqualStrings("\x1b[1t", actions[2].pty_write);
    v.term.clearActions();
}

test "xtversion reports product identity for omitted and zero requests" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 4, 2);
    defer v.deinit();

    v.feed("\x1b[>q\x1b[>0q\x1b[>1q\x1b[>0;1q\x1b[0q");
    const actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 2), actions.len);
    try t.expectEqualStrings("\x1bP>|boringterminal 0.4.0\x1b\\", actions[0].pty_write);
    try t.expectEqualStrings("\x1bP>|boringterminal 0.4.0\x1b\\", actions[1].pty_write);
    v.term.clearActions();
}

test "xtversion query is chunk-split safe" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 4, 2);
    defer v.deinit();

    for ("\x1b[>0q") |byte| v.feed(&[_]u8{byte});
    const actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 1), actions.len);
    try t.expectEqualStrings("\x1bP>|boringterminal 0.4.0\x1b\\", actions[0].pty_write);
    v.term.clearActions();
}

// -- milestone 3: storage, reflow, viewport ---------------------------------

fn dumpOf(v: *vt.Vt, alloc: std.mem.Allocator) ![]u8 {
    return v.term.dumpText(alloc);
}

test "soft wrap sets wrap flag, hard newline does not" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 5, 4);
    defer v.deinit();
    v.feed("abcdefg\r\nhi");
    // Row 0 soft-wrapped ("abcde" + "fg"), row 1 hard-ended.
    try t.expect(v.term.primary.screenRow(0).wrapped);
    try t.expect(!v.term.primary.screenRow(1).wrapped);
}

test "reflow round trip: shrink then grow restores exactly" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 12, 4);
    defer v.deinit();
    v.feed("short\r\nthis-is-long-content\r\nx yz");
    const before = try dumpOf(&v, alloc);
    defer alloc.free(before);
    const row_before = v.term.row;
    const col_before = v.term.col;

    try v.term.resize(5, 4);
    try v.term.resize(7, 4);
    try v.term.resize(12, 4);

    // Content that has scrolled into history comes back when the screen
    // can show it again; the visible dump must round-trip exactly.
    const after = try dumpOf(&v, alloc);
    defer alloc.free(after);
    try t.expectEqualStrings(before, after);
    try t.expectEqual(row_before, v.term.row);
    try t.expectEqual(col_before, v.term.col);
}

test "reflow property: random width walk ends where it started" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 20, 6);
    defer v.deinit();
    v.feed("alpha beta gamma delta epsilon\r\nzeta\r\n\r\ntail-line q");
    const before = try dumpOf(&v, alloc);
    defer alloc.free(before);

    var prng = std.Random.DefaultPrng.init(0x6772696421);
    const random = prng.random();
    var i: usize = 0;
    while (i < 25) : (i += 1) {
        const w = 3 + random.uintLessThan(u16, 30);
        try v.term.resize(w, 6);
    }
    try v.term.resize(20, 6);

    const after = try dumpOf(&v, alloc);
    defer alloc.free(after);
    try t.expectEqualStrings(before, after);
}

test "scrollback accumulates and ED 3 clears only it" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 3);
    defer v.deinit();
    var i: usize = 0;
    var buf: [16]u8 = undefined;
    while (i < 10) : (i += 1) {
        const line = try std.fmt.bufPrint(&buf, "line{d}\r\n", .{i});
        v.feed(line);
    }
    // 10 lines + prompt row through a 3-row screen: 8 rows scrolled off.
    try t.expectEqual(@as(usize, 8), v.term.scrollbackLen());
    const before = try dumpOf(&v, alloc);
    defer alloc.free(before);

    v.feed("\x1b[3J");
    try t.expectEqual(@as(usize, 0), v.term.scrollbackLen());
    const after = try dumpOf(&v, alloc);
    defer alloc.free(after);
    // Screen untouched (xterm ED 3 semantics; esctest test_ED_3).
    try t.expectEqualStrings(before, after);
}

test "host clear scrollback leaves the screen and alternate history intact" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 3);
    defer v.deinit();
    v.feed("one\r\ntwo\r\nthree\r\nfour\r\nfive");
    try t.expectEqual(@as(usize, 2), v.term.scrollbackLen());
    const before = try dumpOf(&v, alloc);
    defer alloc.free(before);

    v.feed("\x1b[?1049h");
    v.term.clearScrollback();
    v.feed("\x1b[?1049l");
    try t.expectEqual(@as(usize, 2), v.term.scrollbackLen());

    v.term.clearScrollback();
    try t.expectEqual(@as(usize, 0), v.term.scrollbackLen());
    const after = try dumpOf(&v, alloc);
    defer alloc.free(after);
    try t.expectEqualStrings(before, after);
}

test "viewport scrolls, clamps, and ignores alt screen" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 3);
    defer v.deinit();
    v.feed("one\r\ntwo\r\nthree\r\nfour\r\nfive");
    try t.expectEqual(@as(usize, 2), v.term.scrollbackLen());
    v.term.scrollViewport(99); // clamps to scrollback
    try t.expectEqual(@as(usize, 2), v.term.viewportOffset());
    try t.expectEqual(@as(u21, 'o'), v.term.viewCellAt(0, 0).cp);
    v.term.scrollViewport(-1);
    try t.expectEqual(@as(usize, 1), v.term.viewportOffset());
    // Entering the alt screen snaps to bottom and reports offset 0.
    v.feed("\x1b[?1049h");
    try t.expectEqual(@as(usize, 0), v.term.viewportOffset());
    v.feed("\x1b[?1049l");
}

test "top-anchored upward scrolls feed scrollback" {
    const alloc = t.allocator;
    {
        var v = try vt.Vt.init(alloc, 10, 3);
        defer v.deinit();
        v.feed("a\r\nb\r\nc\x1b[S");
        try t.expectEqual(@as(usize, 1), v.term.scrollbackLen());
        v.term.scrollViewport(1);
        try t.expectEqual(@as(u21, 'a'), v.term.viewCellAt(0, 0).cp);
    }
    {
        var v = try vt.Vt.init(alloc, 10, 3);
        defer v.deinit();
        v.feed("a\r\nb\r\nc\x1b[1;1H\x1b[M");
        try t.expectEqual(@as(usize, 1), v.term.scrollbackLen());
    }
    {
        var v = try vt.Vt.init(alloc, 10, 4);
        defer v.deinit();
        v.feed("a\r\nb\r\nc\r\nd\x1b[2;3r\x1b[S");
        // A region with a nonzero top margin still recycles in place.
        try t.expectEqual(@as(usize, 0), v.term.scrollbackLen());
    }
}

test "top-anchored partial scroll region preserves fixed rows and pins" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 4, 5);
    defer v.deinit();
    v.feed("A\r\nB\r\nC\r\nD\r\nE");

    // Codex's inline renderer reserves rows below its output region for
    // the composer, then emits CRLF while the cursor is at that region's
    // bottom. Selection and prompt pins in the fixed rows must follow the
    // copied content to its new absolute row id.
    v.term.selectionStart(3, 0, .word);
    v.feed("\x1b[4;1H\x1b]133;A\x07\x1b[1;3r\x1b[3;1H\r\nX");

    const dump = try v.term.dumpText(alloc);
    defer alloc.free(dump);
    try t.expectEqualStrings("B\nC\nX\nD\nE", dump);
    try t.expectEqual(@as(usize, 1), v.term.scrollbackLen());

    const selected = (try v.term.selectionText(alloc)).?;
    defer alloc.free(selected);
    try t.expectEqualStrings("D", selected);

    const live_top_id = v.term.primary.base_id + v.term.primary.len - v.term.primary.screen_rows;
    try t.expectEqual(live_top_id + 3, v.term.prompt_mark.?);

    v.term.scrollViewport(1);
    try t.expectEqual(@as(u21, 'A'), v.term.viewCellAt(0, 0).cp);
}

test "top-anchored partial scroll preserves autowrap continuation" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 4, 4);
    defer v.deinit();
    v.feed("\x1b[4;1HZ\x1b[1;3r\x1b[3;1HabcdX");

    try t.expect(v.term.primary.screenRow(1).wrapped);
    const dump = try v.term.dumpText(alloc);
    defer alloc.free(dump);
    try t.expectEqualStrings("\nabcd\nX\nZ", dump);
}

test "height shrink drops blank rows below cursor first" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 5);
    defer v.deinit();
    v.feed("top\r\nmid");
    try v.term.resize(10, 3);
    // Blank bottom rows went away; content and cursor intact, nothing in
    // scrollback.
    const dump = try dumpOf(&v, alloc);
    defer alloc.free(dump);
    try t.expectEqualStrings("top\nmid\n", dump);
    try t.expectEqual(@as(usize, 0), v.term.scrollbackLen());
    try t.expectEqual(@as(u16, 1), v.term.row);
}

test "height grow pulls scrollback back into view" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 2);
    defer v.deinit();
    v.feed("one\r\ntwo\r\nthree");
    try t.expectEqual(@as(usize, 1), v.term.scrollbackLen());
    try v.term.resize(10, 4);
    const dump = try dumpOf(&v, alloc);
    defer alloc.free(dump);
    try t.expectEqualStrings("one\ntwo\nthree\n", dump);
    try t.expectEqual(@as(usize, 0), v.term.scrollbackLen());
    try t.expectEqual(@as(u16, 2), v.term.row);
}

test "wide chars never split across reflow" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 8, 3);
    defer v.deinit();
    v.feed("ab汉cd");
    try v.term.resize(3, 3);
    // "ab" then 汉 must move whole to the next row (can't straddle col 3).
    const d = try dumpOf(&v, alloc);
    defer alloc.free(d);
    try t.expectEqualStrings("ab\n汉c\nd", d);
    try v.term.resize(8, 3);
    const d2 = try dumpOf(&v, alloc);
    defer alloc.free(d2);
    try t.expectEqualStrings("ab汉cd\n\n", d2);
}

test "zsh-style repaint breaks stale wrap joins" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 4);
    defer v.deinit();
    // Long line wraps rows 0-1; a shell then repaints row 1 in place:
    // CR + ED 0 + fresh prompt (the SIGWINCH redraw shape).
    v.feed("0123456789ABCDE");
    try t.expect(v.term.primary.screenRow(0).wrapped);
    v.feed("\r\x1b[J> cmd");
    try t.expect(!v.term.primary.screenRow(0).wrapped);
    // Reflow must NOT weld the old first row onto the new prompt.
    try v.term.resize(20, 4);
    const d = try v.term.dumpText(alloc);
    defer alloc.free(d);
    try t.expectEqualStrings("0123456789\n> cmd\n\n", d);
}

test "overwriting the last column clears a stale wrap claim" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 3);
    defer v.deinit();
    v.feed("0123456789ABCDE"); // row 0 wrapped -> row 1
    v.feed("\x1b[1;10HZ"); // rewrite row 0's last cell, no wrap follows
    v.feed("\x1b[3;1H");
    try t.expect(!v.term.primary.screenRow(0).wrapped);
    try v.term.resize(20, 3);
    const d = try v.term.dumpText(alloc);
    defer alloc.free(d);
    // Two separate lines now; nothing rejoined.
    try t.expectEqualStrings("012345678Z\nABCDE\n", d);
}

test "el0 mid-row breaks own continuation only" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 4);
    defer v.deinit();
    v.feed("0123456789ABCDEFGHIJxyz"); // rows 0,1 wrapped; row 2 = xyz
    v.feed("\x1b[2;5H\x1b[K"); // EL0 mid row 1: row 1's claim dies
    try t.expect(v.term.primary.screenRow(0).wrapped);
    try t.expect(!v.term.primary.screenRow(1).wrapped);
}

test "reflow never trims blanks under the cursor" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 4);
    defer v.deinit();
    // Prompt-like content with a printed trailing space, cursor after it.
    v.feed("prompt) ");
    try t.expectEqual(@as(u16, 8), v.term.col);
    try v.term.resize(4, 4);
    // "prompt) " is 8 cells; at width 4 the cursor's space survives the
    // trim, so the cursor sits at row 2 col 0 — exactly where the shell's
    // relative repaint math expects it.
    try t.expectEqual(@as(u16, 2), v.term.row);
    try t.expectEqual(@as(u16, 0), v.term.col);
    // And the round trip still restores the visible text.
    try v.term.resize(10, 4);
    const d = try v.term.dumpText(alloc);
    defer alloc.free(d);
    try t.expectEqualStrings("prompt)\n\n\n", d);
    try t.expectEqual(@as(u16, 8), v.term.col);
}

// -- OSC 133 semantic prompts (RFC 0006) ------------------------------------

test "osc 133 tracks shell status, exit codes, and the mark" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 20, 4);
    defer v.deinit();
    try t.expectEqual(terminal.ShellStatus.unknown, v.term.shell_status);
    v.feed("\x1b]133;A\x07> ");
    try t.expectEqual(terminal.ShellStatus.prompt, v.term.shell_status);
    try t.expect(v.term.prompt_mark != null);
    v.feed("\x1b]133;C\x07building...\r\n");
    try t.expectEqual(terminal.ShellStatus.executing, v.term.shell_status);
    try t.expectEqual(@as(?u64, null), v.term.prompt_mark);
    v.feed("\x1b]133;D;2\x07\x1b]133;A\x07");
    try t.expectEqual(@as(?u16, 2), v.term.last_exit);
    try t.expectEqual(terminal.ShellStatus.prompt, v.term.shell_status);

    const actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 4), actions.len);
    try t.expectEqual(terminal.PromptMark.prompt_start, actions[0].prompt_mark);
    try t.expectEqual(terminal.PromptMark.command_executed, actions[1].prompt_mark);
    try t.expectEqual(@as(?u16, 2), actions[2].prompt_mark.command_finished);
    try t.expectEqual(terminal.PromptMark.prompt_start, actions[3].prompt_mark);
    v.term.clearActions();
}

test "osc 7 emits bounded cwd reports with ST BEL and empty reset" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 20, 4);
    defer v.deinit();
    v.feed("\x1b]7;file:///tmp/one\x1b\\\x1b]7;file://localhost/two\x07\x1b]7;\x1b\\");
    const actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 3), actions.len);
    try t.expectEqualStrings("file:///tmp/one", actions[0].cwd_report);
    try t.expectEqualStrings("file://localhost/two", actions[1].cwd_report);
    try t.expectEqualStrings("", actions[2].cwd_report);
    v.term.clearActions();

    const oversized = try alloc.alloc(u8, terminal.max_cwd_uri_bytes + 1);
    defer alloc.free(oversized);
    @memset(oversized, 'x');
    v.feed("\x1b]7;");
    v.feed(oversized);
    v.feed("\x07");
    try t.expectEqual(@as(usize, 0), v.term.drainActions().len);
}

test "osc 7 cwd reports are chunk split safe" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 20, 4);
    defer v.deinit();
    for ("\x1b]7;file:///tmp/split\x1b\\") |byte| v.feed(&[_]u8{byte});
    const actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 1), actions.len);
    try t.expectEqualStrings("file:///tmp/split", actions[0].cwd_report);
    v.term.clearActions();
}

test "osc 133 prompt actions are chunk-split safe" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 20, 4);
    defer v.deinit();
    for ("\x1b]133;A\x1b\\\x1b]133;B\x07\x1b]133;C\x07\x1b]133;D;7\x1b\\") |byte| {
        v.feed(&[_]u8{byte});
    }
    const actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 4), actions.len);
    try t.expectEqual(terminal.PromptMark.prompt_start, actions[0].prompt_mark);
    try t.expectEqual(terminal.PromptMark.command_start, actions[1].prompt_mark);
    try t.expectEqual(terminal.PromptMark.command_executed, actions[2].prompt_mark);
    try t.expectEqual(@as(?u16, 7), actions[3].prompt_mark.command_finished);
    v.term.clearActions();
}

test "osc 9 and 777 emit notifications but progress and unknown forms do not" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 20, 4);
    defer v.deinit();
    v.feed("\x1b]9;build finished\x07\x1b]9;4;1;50\x07" ++
        "\x1b]777;notify;Agent;Needs input\x1b\\\x1b]777;other;x;y\x07");
    const actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 2), actions.len);
    try t.expectEqualStrings("", actions[0].notify.title);
    try t.expectEqualStrings("build finished", actions[0].notify.body);
    try t.expectEqualStrings("Agent", actions[1].notify.title);
    try t.expectEqualStrings("Needs input", actions[1].notify.body);
    v.term.clearActions();
}

test "osc notifications are chunk-split safe" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 20, 4);
    defer v.deinit();
    for ("\x1b]9;hello\x1b\\\x1b]777;notify;title;body;with;semicolons\x07") |byte| {
        v.feed(&[_]u8{byte});
    }
    const actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 2), actions.len);
    try t.expectEqualStrings("hello", actions[0].notify.body);
    try t.expectEqualStrings("title", actions[1].notify.title);
    try t.expectEqualStrings("body;with;semicolons", actions[1].notify.body);
    v.term.clearActions();
}

test "osc 10 11 12 report effective colors with matching terminators" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 20, 4);
    defer v.deinit();

    v.feed("\x1b]10;?\x07\x1b]11;?\x1b\\\x1b]12;?\x07");
    const actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 3), actions.len);
    try t.expectEqualStrings("\x1b]10;rgb:d4d4/d8d8/dede\x07", actions[0].pty_write);
    try t.expectEqualStrings("\x1b]11;rgb:1010/1414/1818\x1b\\", actions[1].pty_write);
    try t.expectEqualStrings("\x1b]12;rgb:d4d4/d8d8/dede\x07", actions[2].pty_write);
    v.term.clearActions();
}

test "osc dynamic color queries are chunk-split safe and sets are ignored" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 20, 4);
    defer v.deinit();

    for ("\x1b]11;?\x1b\\\x1b]11;rgb:ffff/ffff/ffff\x1b\\") |byte| {
        v.feed(&[_]u8{byte});
    }
    const actions = v.term.drainActions();
    try t.expectEqual(@as(usize, 1), actions.len);
    try t.expectEqualStrings("\x1b]11;rgb:1010/1414/1818\x1b\\", actions[0].pty_write);
    v.term.clearActions();
}

test "osc 22 stores bounded pointer shapes and resets unknown names" {
    var v = try vt.Vt.init(t.allocator, 20, 4);
    defer v.deinit();

    const initial_epoch = v.term.state_epoch;
    v.feed("\x1b]22;pointer\x1b\\");
    try t.expectEqual(vt.mouse.PointerShape.pointer, v.term.pointer_shape);
    try t.expect(v.term.state_epoch != initial_epoch);

    v.feed("\x1b]22;hand2\x07");
    try t.expectEqual(vt.mouse.PointerShape.pointer, v.term.pointer_shape);

    v.feed("\x1b]22;cross\x1b\\");
    try t.expectEqual(vt.mouse.PointerShape.crosshair, v.term.pointer_shape);
    v.feed("\x1b]22;row-resize\x1b\\");
    try t.expectEqual(vt.mouse.PointerShape.text, v.term.pointer_shape);
    v.feed("\x1b]22;default\x1b\\");
    try t.expectEqual(vt.mouse.PointerShape.default, v.term.pointer_shape);
    v.feed("\x1bc");
    try t.expectEqual(vt.mouse.PointerShape.text, v.term.pointer_shape);
}

test "osc 22 pointer shape is chunk-split safe" {
    var v = try vt.Vt.init(t.allocator, 20, 4);
    defer v.deinit();
    for ("\x1b]22;pointer\x1b\\") |byte| v.feed(&.{byte});
    try t.expectEqual(vt.mouse.PointerShape.pointer, v.term.pointer_shape);
}

test "osc 8 attaches semantic hyperlinks and closes with ST or BEL" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 20, 3);
    defer v.deinit();

    v.feed("\x1b]8;id=docs;https://example.com/docs\x1b\\Docs" ++
        "\x1b]8;;\x07 plain");
    const linked = v.term.cellAt(0, 0);
    try t.expect(linked.hyperlink_id != 0);
    try t.expectEqual(linked.hyperlink_id, v.term.cellAt(0, 3).hyperlink_id);
    try t.expectEqual(@as(u32, 0), v.term.cellAt(0, 4).hyperlink_id);
    const link = v.term.hyperlink(linked.hyperlink_id).?;
    try t.expectEqualStrings("docs", link.explicit_id);
    try t.expectEqualStrings("https://example.com/docs", link.uri);
}

test "osc 8 is chunk-split safe and implicit openings remain distinct" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 20, 3);
    defer v.deinit();

    for ("\x1b]8;;https://example.com\x1b\\a\x1b]8;;\x1b\\" ++
        "\x1b]8;id=;https://example.com\x07b\x1b]8;;\x07") |byte|
    {
        v.feed(&[_]u8{byte});
    }
    const first = v.term.cellAt(0, 0).hyperlink_id;
    const second = v.term.cellAt(0, 1).hyperlink_id;
    try t.expect(first != 0 and second != 0 and first != second);
    try t.expectEqualStrings("", v.term.hyperlink(first).?.explicit_id);
    try t.expectEqualStrings("", v.term.hyperlink(second).?.explicit_id);
}

test "osc 8 explicit identity reconnects repainted cells" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 20, 3);
    defer v.deinit();

    v.feed("\x1b]8;future=x:id=shared;https://example.com/a\x1b\\a" ++
        "\x1b]8;;\x1b\\ \x1b]8;id=shared;https://example.com/a\x1b\\b");
    try t.expectEqual(v.term.cellAt(0, 0).hyperlink_id, v.term.cellAt(0, 2).hyperlink_id);
}

test "osc 8 malformed updates do not leak or replace active state" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 20, 3);
    defer v.deinit();

    v.feed("\x1b]8;id=good;https://example.com\x1b\\a" ++
        "\x1b]8;id=bad;\x1b\\b"); // empty URI with parameters
    const expected = v.term.cellAt(0, 0).hyperlink_id;
    try t.expectEqual(expected, v.term.cellAt(0, 1).hyperlink_id);

    var oversized: std.ArrayList(u8) = .empty;
    defer oversized.deinit(alloc);
    try oversized.appendSlice(alloc, "\x1b]8;;");
    try oversized.appendNTimes(alloc, 'x', vt.hyperlink.max_uri_bytes + 1);
    try oversized.appendSlice(alloc, "\x1b\\c");
    v.feed(oversized.items);
    try t.expectEqual(expected, v.term.cellAt(0, 2).hyperlink_id);
}

test "osc 8 is independent from SGR and follows cursor save restore" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 20, 3);
    defer v.deinit();

    v.feed("\x1b]8;id=a;https://a.example\x1b\\\x1b7" ++
        "\x1b]8;id=b;https://b.example\x1b\\\x1b[0mB\x1b8\x1b[CA");
    const b = v.term.cellAt(0, 0).hyperlink_id;
    const a = v.term.cellAt(0, 1).hyperlink_id;
    try t.expect(b != 0 and a != 0 and b != a);
    try t.expectEqualStrings("https://b.example", v.term.hyperlink(b).?.uri);
    try t.expectEqualStrings("https://a.example", v.term.hyperlink(a).?.uri);

    v.feed("\x1b[!pC"); // DECSTR closes the active hyperlink.
    try t.expectEqual(@as(u32, 0), v.term.cellAt(0, 2).hyperlink_id);
}

test "osc 8 moves through wide cells scrollback and resize reflow" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 6, 2);
    defer v.deinit();

    v.feed("\x1b]8;id=wide;https://example.com/wide\x1b\\a汉bcdef" ++
        "\x1b]8;;\x1b\\\r\nnext\r\nlast");
    try t.expect(v.term.scrollbackLen() > 0);
    v.term.scrollViewport(99);
    const id = v.term.viewCellAt(0, 0).hyperlink_id;
    try t.expect(id != 0);
    try t.expectEqual(id, v.term.viewCellAt(0, 1).hyperlink_id);
    try t.expectEqual(id, v.term.viewCellAt(0, 2).hyperlink_id); // wide spacer

    v.term.viewportToBottom();
    try v.term.resize(4, 2);
    v.term.scrollViewport(99);
    var linked_cells: usize = 0;
    var row: u16 = 0;
    while (row < v.term.rows) : (row += 1) {
        var col: u16 = 0;
        while (col < v.term.cols) : (col += 1) {
            if (v.term.viewCellAt(row, col).hyperlink_id == id) linked_cells += 1;
        }
    }
    try t.expect(linked_cells >= 3);
}

test "osc 8 erasure removes hyperlink metadata from blank cells" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 2);
    defer v.deinit();
    v.feed("\x1b]8;;https://example.com\x1b\\linked\r\x1b[2K");
    var col: u16 = 0;
    while (col < v.term.cols) : (col += 1)
        try t.expectEqual(@as(u32, 0), v.term.cellAt(0, col).hyperlink_id);
}

test "osc 8 metadata compaction traces retained cells before admitting more" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 2, 1);
    defer v.deinit();

    var sequence_buf: [128]u8 = undefined;
    var index: usize = 0;
    while (index <= vt.hyperlink.max_entries) : (index += 1) {
        const sequence = try std.fmt.bufPrint(
            &sequence_buf,
            "\x1b]8;;https://example.com/{d}\x1b\\x\r",
            .{index},
        );
        v.feed(sequence);
    }

    const retained_id = v.term.cellAt(0, 0).hyperlink_id;
    try t.expect(retained_id != 0);
    try t.expect(v.term.hyperlinks.items.len < vt.hyperlink.max_entries);
    try t.expectEqualStrings("https://example.com/16384", v.term.hyperlink(retained_id).?.uri);
}

test "prompt-aware reflow drops prompt paint and preserves cursor offset" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 12, 4);
    defer v.deinit();
    // Output, then a marked prompt that wraps to 2 rows at width 12
    // (prompt text is 14 cells), cursor on the second prompt row.
    v.feed("out-line\r\n\x1b]133;A\x07PROMPT-12345> ");
    try t.expectEqual(@as(u16, 2), v.term.row); // prompt rows 1-2
    try v.term.resize(8, 4);
    // Content kept; prompt region dropped to blanks for the shell's
    // repaint; cursor kept its 1-row offset below the (new) mark.
    const d = try v.term.dumpText(alloc);
    defer alloc.free(d);
    try t.expectEqualStrings("out-line\n\n\n", d);
    try t.expectEqual(terminal.ShellStatus.prompt, v.term.shell_status);
    const mark = v.term.prompt_mark.?;
    const top = v.term.primary.len - v.term.primary.screen_rows;
    const mark_row = @as(usize, @intCast(mark - v.term.primary.base_id)) - top;
    try t.expectEqual(@as(usize, 1), mark_row);
    try t.expectEqual(@as(u16, 2), v.term.row); // mark_row + rel(1)
}

test "unmarked reflow unchanged by 133 executing state" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 3);
    defer v.deinit();
    v.feed("\x1b]133;A\x07> make\x1b]133;C\x07\r\nlong-output-line");
    try v.term.resize(8, 3);
    // Executing: everything is content; normal reflow applies. The
    // 16-char line fills two 8-col rows exactly, the cursor takes the
    // post-wrap row, and "> make" scrolls into history.
    const d = try v.term.dumpText(alloc);
    defer alloc.free(d);
    try t.expectEqualStrings("long-out\nput-line\n", d);
    try t.expectEqual(@as(usize, 1), v.term.scrollbackLen());
    v.term.scrollViewport(1);
    try t.expectEqual(@as(u21, '>'), v.term.viewCellAt(0, 0).cp);
}

// -- selection (RFC 0010) ----------------------------------------------------

test "char selection and extraction across hard lines" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 3);
    defer v.deinit();
    v.feed("hello it\r\nworld");
    v.term.selectionStart(0, 6, .char);
    v.term.selectionDrag(
        1,
        2,
    );
    const text = (try v.term.selectionText(alloc)).?;
    defer alloc.free(text);
    try t.expectEqualStrings("it\nwor", text);
}

test "selection normalizes backwards drags" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 2);
    defer v.deinit();
    v.feed("abcdef");
    v.term.selectionStart(0, 4, .char);
    v.term.selectionDrag(0, 1);
    const text = (try v.term.selectionText(alloc)).?;
    defer alloc.free(text);
    try t.expectEqualStrings("bcde", text);
}

test "word selection snaps to non-space runs" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 20, 2);
    defer v.deinit();
    v.feed("foo bar-baz qux");
    v.term.selectionStart(0, 6, .word); // inside "bar-baz"
    const text = (try v.term.selectionText(alloc)).?;
    defer alloc.free(text);
    try t.expectEqualStrings("bar-baz", text);
}

test "line selection follows logical lines and joins soft wraps" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 6, 4);
    defer v.deinit();
    v.feed("abcdefgh\r\nnext");
    // Triple-click on the wrapped continuation row selects the whole
    // logical line, extracted without a newline at the soft wrap.
    v.term.selectionStart(1, 0, .line);
    const text = (try v.term.selectionText(alloc)).?;
    defer alloc.free(text);
    try t.expectEqualStrings("abcdefgh", text);
}

test "selection includes whole wide pairs" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 2);
    defer v.deinit();
    v.feed("a汉b");
    // Anchor on the spacer, head on the wide head: both snap outward.
    v.term.selectionStart(0, 2, .char);
    v.term.selectionDrag(0, 1);
    const text = (try v.term.selectionText(alloc)).?;
    defer alloc.free(text);
    try t.expectEqualStrings("汉", text);
}

test "selection survives scrolling, clears on reflow" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 3);
    defer v.deinit();
    v.feed("target");
    v.term.selectionStart(0, 0, .word);
    // New output scrolls the selected row into scrollback; ids keep it.
    v.feed("\r\na\r\nb\r\nc\r\nd");
    const text = (try v.term.selectionText(alloc)).?;
    defer alloc.free(text);
    try t.expectEqualStrings("target", text);
    // Width change clears (RFC 0010).
    try v.term.resize(8, 3);
    try t.expect(!v.term.hasSelection());
}

test "viewCellSelected respects viewport" {
    const alloc = t.allocator;
    var v = try vt.Vt.init(alloc, 10, 2);
    defer v.deinit();
    v.feed("sel\r\n1\r\n2\r\n3");
    // "sel" is 2 rows into scrollback now; select it via the viewport.
    v.term.scrollViewport(99);
    v.term.selectionStart(0, 0, .word);
    try t.expect(v.term.viewCellSelected(0, 0));
    try t.expect(!v.term.viewCellSelected(1, 0));
    v.term.viewportToBottom();
    // Same cells, now out of view: nothing on-screen is selected.
    try t.expect(!v.term.viewCellSelected(0, 0));
    const text = (try v.term.selectionText(alloc)).?;
    defer alloc.free(text);
    try t.expectEqualStrings("sel", text);
}
