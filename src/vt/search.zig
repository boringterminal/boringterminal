//! Pure terminal-text search primitives (RFC 0016).
//!
//! The caller builds a logical line and supplies one source-cell pin for
//! every UTF-8 byte. zg performs canonical caseless matching and returns a
//! slice of the original haystack, which lets us map a transformed match
//! back to exact terminal cells without storing normalized shadow text.

const std = @import("std");
const CaselessMatch = @import("CaselessMatch");
const cell_mod = @import("cell.zig");
const graphics = @import("graphics.zig");

pub const max_query_bytes: usize = 1024;
pub const max_query_codepoints: usize = 256;
pub const max_matches: usize = 100_000;

pub const Point = struct {
    row_id: u64,
    col: u16,
};

pub const Match = struct {
    start: Point,
    end: Point,
};

pub const Results = struct {
    matches: []Match,
    truncated: bool,

    pub fn deinit(self: *Results, alloc: std.mem.Allocator) void {
        alloc.free(self.matches);
        self.* = undefined;
    }
};

pub const Row = struct {
    id: u64,
    wrapped: bool,
};

pub const CorpusDescriptor = struct {
    state_epoch: u64,
    on_alt: bool,
    cols: u16,
    screen_rows: u16,
    row_count: usize,
    base_id: u64,
    grapheme_len: usize,
};

/// Detached, immutable search input. The daemon can copy this while holding
/// the terminal mutex, release the PTY immediately, then do all Unicode work
/// on the requesting command thread.
pub const Corpus = struct {
    state_epoch: u64,
    on_alt: bool,
    cols: u16,
    screen_rows: u16,
    rows: []Row,
    cells: []cell_mod.Cell,
    graphemes: []u21,

    pub fn init(alloc: std.mem.Allocator, descriptor: CorpusDescriptor) !Corpus {
        const rows = try alloc.alloc(Row, descriptor.row_count);
        errdefer alloc.free(rows);
        const cells = try alloc.alloc(cell_mod.Cell, descriptor.row_count * descriptor.cols);
        errdefer alloc.free(cells);
        const graphemes = try alloc.alloc(u21, descriptor.grapheme_len);
        errdefer alloc.free(graphemes);
        return .{
            .state_epoch = descriptor.state_epoch,
            .on_alt = descriptor.on_alt,
            .cols = descriptor.cols,
            .screen_rows = descriptor.screen_rows,
            .rows = rows,
            .cells = cells,
            .graphemes = graphemes,
        };
    }

    pub fn deinit(self: *Corpus, alloc: std.mem.Allocator) void {
        alloc.free(self.rows);
        alloc.free(self.cells);
        alloc.free(self.graphemes);
        self.* = undefined;
    }

    pub fn find(
        self: *const Corpus,
        alloc: std.mem.Allocator,
        query: []const u8,
    ) !Results {
        try validateQuery(query);

        var matches: std.ArrayList(Match) = .empty;
        errdefer matches.deinit(alloc);
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(alloc);
        var byte_points: std.ArrayList(Point) = .empty;
        defer byte_points.deinit(alloc);
        var truncated = false;

        for (self.rows, 0..) |row, row_index| {
            const start = row_index * self.cols;
            try self.appendRow(
                alloc,
                &line,
                &byte_points,
                row,
                self.cells[start..][0..self.cols],
            );
            if (!row.wrapped) {
                truncated = try appendLineMatches(
                    line.items,
                    byte_points.items,
                    query,
                    &matches,
                    alloc,
                );
                line.clearRetainingCapacity();
                byte_points.clearRetainingCapacity();
                if (truncated) break;
            }
        }
        if (!truncated and line.items.len != 0) {
            truncated = try appendLineMatches(
                line.items,
                byte_points.items,
                query,
                &matches,
                alloc,
            );
        }

        return .{
            .matches = try matches.toOwnedSlice(alloc),
            .truncated = truncated,
        };
    }

    fn appendRow(
        self: *const Corpus,
        alloc: std.mem.Allocator,
        line: *std.ArrayList(u8),
        byte_points: *std.ArrayList(Point),
        row: Row,
        cells: []const cell_mod.Cell,
    ) !void {
        var cell_count: usize = cells.len;
        if (!row.wrapped) {
            cell_count = 0;
            for (cells, 0..) |cell, col| {
                if (cell.flags.content and !cell.flags.wide_spacer and !cell.flags.wide_pad)
                    cell_count = col + 1;
            }
        }

        for (cells[0..cell_count], 0..) |cell, col| {
            if (cell.flags.wide_spacer or cell.flags.wide_pad) continue;
            const point: Point = .{ .row_id = row.id, .col = @intCast(col) };
            if (cell.cp == graphics.unicode_placeholder) {
                try line.append(alloc, '\n');
                try byte_points.append(alloc, point);
                continue;
            }

            var utf8: [4]u8 = undefined;
            const cp_len = std.unicode.utf8Encode(cell.cp, &utf8) catch continue;
            try line.appendSlice(alloc, utf8[0..cp_len]);
            try byte_points.appendNTimes(alloc, point, cp_len);
            const suffix_end = @as(usize, cell.grapheme_offset) + cell.grapheme_len;
            const suffix: []const u21 = if (cell.grapheme_len == 0 or suffix_end > self.graphemes.len)
                &.{}
            else
                self.graphemes[@as(usize, cell.grapheme_offset)..][0..cell.grapheme_len];
            for (suffix) |suffix_cp| {
                const suffix_len = std.unicode.utf8Encode(suffix_cp, &utf8) catch continue;
                try line.appendSlice(alloc, utf8[0..suffix_len]);
                try byte_points.appendNTimes(alloc, point, suffix_len);
            }
        }
    }
};

pub fn validateQuery(query: []const u8) !void {
    if (query.len == 0) return error.EmptyQuery;
    if (query.len > max_query_bytes) return error.QueryTooLong;
    if (!std.unicode.utf8ValidateSlice(query)) return error.InvalidUtf8;
    if (std.mem.indexOfAny(u8, query, "\x00\r\n") != null)
        return error.MultilineQuery;

    var count: usize = 0;
    for (query) |byte| {
        if (byte & 0xc0 != 0x80) count += 1;
    }
    if (count > max_query_codepoints) return error.QueryTooLong;
}

/// Append every (overlapping) canonical-caseless match in one logical line.
/// `byte_points[i]` identifies the terminal cell that contributed byte `i`.
pub fn appendLineMatches(
    haystack: []const u8,
    byte_points: []const Point,
    query: []const u8,
    matches: *std.ArrayList(Match),
    alloc: std.mem.Allocator,
) !bool {
    std.debug.assert(haystack.len == byte_points.len);
    if (haystack.len == 0) return false;

    var searcher = CaselessMatch.CaselessSearcher(max_query_codepoints, .canon).default;
    var from: usize = 0;
    while (from < haystack.len) {
        const found = try searcher.matchPos(haystack, query, from) orelse break;
        if (found.len == 0) break;
        const start = @intFromPtr(found.ptr) - @intFromPtr(haystack.ptr);
        const end = start + found.len - 1;
        if (matches.items.len == max_matches) return true;
        try matches.append(alloc, .{
            .start = byte_points[start],
            .end = byte_points[end],
        });

        // Advance one original scalar from the match start so overlapping
        // results remain discoverable without starting inside UTF-8.
        const scalar_len = std.unicode.utf8ByteSequenceLength(haystack[start]) catch 1;
        from = start + scalar_len;
    }
    return false;
}

test "canonical caseless matches retain original byte ranges" {
    const alloc = std.testing.allocator;
    const haystack = "Straße Cafe\u{301}";
    var points: [haystack.len]Point = undefined;
    for (&points, 0..) |*point, i| point.* = .{ .row_id = 7, .col = @intCast(i) };

    var found: std.ArrayList(Match) = .empty;
    defer found.deinit(alloc);
    try std.testing.expect(!try appendLineMatches(haystack, &points, "STRASSE", &found, alloc));
    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expectEqual(@as(u16, 0), found.items[0].start.col);
    try std.testing.expectEqual(@as(u16, 6), found.items[0].end.col);

    found.clearRetainingCapacity();
    try std.testing.expect(!try appendLineMatches(haystack, &points, "CAFÉ", &found, alloc));
    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expectEqual(@as(u16, 8), found.items[0].start.col);
    try std.testing.expectEqual(@as(u16, 13), found.items[0].end.col);
}

test "query bounds reject control-separated and oversized searches" {
    try std.testing.expectError(error.EmptyQuery, validateQuery(""));
    try std.testing.expectError(error.MultilineQuery, validateQuery("a\nb"));
    try std.testing.expectError(error.InvalidUtf8, validateQuery("\xff"));
}
