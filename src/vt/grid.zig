//! RFC 0003 v1 storage: the primary screen is a ring of uniform-width
//! rows with absolute ids — scrollback, wrap flags, viewport, and reflow
//! live here. The alt screen stays a flat clip/pad grid (no scrollback,
//! no reflow — TUIs repaint on SIGWINCH).
//!
//! Invariants (fuzzed via the vt test suite):
//!   - len >= screen_rows at all times
//!   - every stored row's cells.len == cols
//!   - viewport_offset <= scrollbackLen()

const std = @import("std");
const cell_mod = @import("cell.zig");

pub const Cell = cell_mod.Cell;

/// Rows kept above the screen. Compile-time until the config file exists
/// (RFC 0003); revisit only on real memory profiles.
pub const scrollback_cap: usize = 10_000;

/// Physical ring capacity headroom for the tallest sane screen.
const max_screen_rows: usize = 1024;

pub const Row = struct {
    cells: []Cell,
    /// This row soft-wraps onto the next one (same logical line).
    wrapped: bool = false,
};

pub const Cursor = struct {
    row: u16,
    col: u16,
};

/// Prompt-aware reflow input (RFC 0006): the marked region is shell
/// paint the shell will redraw; reflow drops it and preserves the
/// cursor's row offset from the mark so zle's stale-offset repaint
/// lands exactly on the fresh mark row.
pub const PromptRegion = struct {
    /// Logical index of the prompt's first row.
    start: usize,
    /// Cursor rows below the mark at the old width.
    cursor_rel: u16,
};

pub const PrimaryGrid = struct {
    alloc: std.mem.Allocator,
    slots: []Row,
    start: usize = 0,
    len: usize = 0,
    base_id: u64 = 0,
    cols: u16,
    screen_rows: u16,
    /// Rows scrolled above the live bottom; 0 = live.
    viewport_offset: usize = 0,

    pub fn init(alloc: std.mem.Allocator, cols: u16, rows: u16) !PrimaryGrid {
        var self: PrimaryGrid = .{
            .alloc = alloc,
            .slots = try alloc.alloc(Row, scrollback_cap + max_screen_rows),
            .cols = cols,
            .screen_rows = rows,
        };
        errdefer alloc.free(self.slots);
        var r: u16 = 0;
        while (r < rows) : (r += 1) try self.pushBottom(.{});
        return self;
    }

    pub fn deinit(self: *PrimaryGrid) void {
        var i: usize = 0;
        while (i < self.len) : (i += 1) self.alloc.free(self.rowAt(i).cells);
        self.alloc.free(self.slots);
    }

    fn physIndex(self: *const PrimaryGrid, i: usize) usize {
        return (self.start + i) % self.slots.len;
    }

    pub fn rowAt(self: *const PrimaryGrid, i: usize) *Row {
        std.debug.assert(i < self.len);
        return &self.slots[self.physIndex(i)];
    }

    pub fn screenRow(self: *const PrimaryGrid, r: u16) *Row {
        return self.rowAt(self.len - self.screen_rows + r);
    }

    pub fn scrollbackLen(self: *const PrimaryGrid) usize {
        return self.len - self.screen_rows;
    }

    /// Screen row as seen through the viewport (offset rows up).
    pub fn viewRow(self: *const PrimaryGrid, r: u16) *Row {
        return self.rowAt(self.len - self.screen_rows - self.viewport_offset + r);
    }

    pub fn scrollViewport(self: *PrimaryGrid, delta: i64) void {
        const cur: i64 = @intCast(self.viewport_offset);
        const max: i64 = @intCast(self.scrollbackLen());
        self.viewport_offset = @intCast(std.math.clamp(cur + delta, 0, max));
    }

    pub fn viewportToBottom(self: *PrimaryGrid) void {
        self.viewport_offset = 0;
    }

    fn newCells(self: *PrimaryGrid, fill: Cell) ![]Cell {
        const cells = try self.alloc.alloc(Cell, self.cols);
        @memset(cells, fill);
        return cells;
    }

    fn pushBottom(self: *PrimaryGrid, fill: Cell) !void {
        if (self.len == self.slots.len) self.evictOldest();
        self.slots[self.physIndex(self.len)] = .{ .cells = try self.newCells(fill) };
        self.len += 1;
    }

    fn evictOldest(self: *PrimaryGrid) void {
        self.alloc.free(self.slots[self.start].cells);
        self.start = (self.start + 1) % self.slots.len;
        self.len -= 1;
        self.base_id += 1;
        // The viewport follows content; eviction can shrink what's above.
        self.viewport_offset = @min(self.viewport_offset, self.scrollbackLen());
    }

    fn popBottom(self: *PrimaryGrid) void {
        std.debug.assert(self.len > 0);
        self.len -= 1;
        self.alloc.free(self.slots[self.physIndex(self.len)].cells);
    }

    /// Scroll a full-width, top-anchored region up by one row. The row at
    /// screen row zero enters history while rows below `bottom` remain
    /// visually fixed (RFC 0003 amendment, 2026-08-16).
    /// Returns false when the blank row cannot be allocated.
    pub fn scrollTopRegionUpOne(self: *PrimaryGrid, bottom: u16, fill: Cell) bool {
        std.debug.assert(bottom < self.screen_rows);
        self.pushBottom(fill) catch return false;

        // pushBottom shifts the live-screen window up by one. Restore the
        // rows below the scrolling region to their old screen positions.
        var dst = self.screen_rows - 1;
        while (dst > bottom) : (dst -= 1) {
            const src = dst - 1;
            @memcpy(self.screenRow(dst).cells, self.screenRow(src).cells);
            self.screenRow(dst).wrapped = self.screenRow(src).wrapped;
        }

        @memset(self.screenRow(bottom).cells, fill);
        self.screenRow(bottom).wrapped = false;
        return true;
    }

    pub fn clearScrollback(self: *PrimaryGrid) void {
        while (self.scrollbackLen() > 0) self.evictOldest();
        self.viewport_offset = 0;
    }

    /// Returns the prompt mark's new absolute id when a PromptRegion was
    /// honored (width changes only; height changes keep ids stable).
    pub fn resize(
        self: *PrimaryGrid,
        new_cols: u16,
        new_rows_in: u16,
        cursor: *Cursor,
        prompt: ?PromptRegion,
    ) !?u64 {
        const new_rows: u16 = @min(new_rows_in, max_screen_rows);
        var new_mark: ?u64 = null;
        if (new_cols != self.cols) {
            new_mark = try self.rewrap(new_cols, new_rows, cursor, prompt);
        } else if (new_rows != self.screen_rows) {
            try self.resizeHeight(new_rows, cursor);
        }
        self.viewport_offset = 0;
        return new_mark;
    }

    /// Height-only change, bottom-anchored: shrinking drops blank rows
    /// below the cursor first, then pushes top rows into scrollback;
    /// growing pulls scrollback rows back into view (RFC 0003).
    fn resizeHeight(self: *PrimaryGrid, new_rows: u16, cursor: *Cursor) !void {
        if (new_rows > self.screen_rows) {
            var d = new_rows - self.screen_rows;
            const revealed: u16 = @intCast(@min(d, self.scrollbackLen()));
            self.screen_rows += d;
            cursor.row += revealed;
            d -= revealed;
            while (self.len < self.screen_rows) try self.pushBottom(.{});
        } else {
            var d = self.screen_rows - new_rows;
            while (d > 0) : (d -= 1) {
                const last = self.screenRow(self.screen_rows - 1);
                if (cursor.row + 1 < self.screen_rows and rowIsBlank(last)) {
                    self.popBottom();
                    self.screen_rows -= 1;
                } else {
                    self.screen_rows -= 1;
                    cursor.row -|= 1;
                }
            }
        }
        cursor.row = @min(cursor.row, self.screen_rows - 1);
    }

    /// Width change: rebuild every logical line at the new width. The
    /// shrink-then-grow round trip must be exact (RFC 0003 acceptance).
    fn rewrap(
        self: *PrimaryGrid,
        new_cols: u16,
        new_rows: u16,
        cursor: *Cursor,
        prompt: ?PromptRegion,
    ) !?u64 {
        const alloc = self.alloc;
        var out: PrimaryGrid = .{
            .alloc = alloc,
            .slots = try alloc.alloc(Row, scrollback_cap + max_screen_rows),
            .cols = new_cols,
            .screen_rows = 0, // filled below; emit uses pushBottom
        };
        errdefer {
            var i: usize = 0;
            while (i < out.len) : (i += 1) alloc.free(out.rowAt(i).cells);
            alloc.free(out.slots);
        }

        const cursor_logical = self.len - self.screen_rows + cursor.row;
        var new_cursor_abs: ?usize = null;
        var new_cursor_col: u16 = 0;

        // Prompt-aware path (RFC 0006): content ends where the prompt
        // begins; the marked region is dropped, not rewrapped.
        const content_end: usize = if (prompt) |pr| @min(pr.start, self.len) else self.len;

        // Trailing blank screen rows below the cursor are padding, not
        // content — as lines they would shove real content into
        // scrollback on every rewrap. Drop them (freeing their cells);
        // rows that belong to a wrapped logical line stay.
        var eff = content_end;
        while (prompt == null and eff > 0) {
            const j = eff - 1;
            if (j <= cursor_logical) break;
            const row = self.rowAt(j);
            if (!rowIsBlank(row)) break;
            if (j > 0 and self.rowAt(j - 1).wrapped) break;
            alloc.free(row.cells);
            row.cells = &.{};
            eff -= 1;
        }

        var line: std.ArrayList(Cell) = .empty;
        defer line.deinit(alloc);
        var cursor_char: ?usize = null;

        var i: usize = 0;
        while (i < eff) : (i += 1) {
            const row = self.rowAt(i);
            if (i == cursor_logical) {
                cursor_char = line.items.len + @min(cursor.col, self.cols - 1);
            }
            // Wide-split padding at a wrapped row's tail is filler, not
            // content: strip it so lines rejoin exactly.
            var cells: []const Cell = row.cells;
            if (row.wrapped) {
                while (cells.len > 0 and cells[cells.len - 1].flags.wide_pad) {
                    cells = cells[0 .. cells.len - 1];
                }
            }
            try line.appendSlice(alloc, cells);
            const line_ends = !row.wrapped or i == eff - 1;
            alloc.free(row.cells);
            row.cells = &.{};
            if (line_ends) {
                try emitLine(&out, line.items, cursor_char, &new_cursor_abs, &new_cursor_col);
                line.clearRetainingCapacity();
                cursor_char = null;
            }
        }

        // Prompt region: free the dropped rows, append fresh blank rows
        // for the shell's repaint, pin the new mark, place the cursor at
        // its preserved offset below it.
        var prompt_mark_out: ?u64 = null;
        if (prompt) |pr| {
            var j = content_end;
            while (j < self.len) : (j += 1) {
                const row = self.rowAt(j);
                if (row.cells.len > 0) alloc.free(row.cells);
                row.cells = &.{};
            }
            var k: usize = 0;
            while (k <= pr.cursor_rel) : (k += 1) try out.pushBottom(.{});
            prompt_mark_out = out.base_id + out.len - 1 - pr.cursor_rel;
            new_cursor_abs = @intCast(out.base_id + out.len - 1);
            new_cursor_col = @min(cursor.col, new_cols - 1);
        }

        // Old storage is fully consumed; adopt the new ring.
        alloc.free(self.slots);
        self.slots = out.slots;
        self.start = out.start;
        self.len = out.len;
        self.base_id = out.base_id;
        self.cols = new_cols;
        self.screen_rows = new_rows;
        while (self.len < self.screen_rows) try self.pushBottom(.{});

        if (new_cursor_abs) |abs| {
            // Eviction during emit may have consumed the cursor's line.
            const evicted = out.base_id;
            if (abs >= evicted) {
                const logical = abs - @as(usize, @intCast(evicted));
                const top = self.len - self.screen_rows;
                cursor.row = if (logical >= top) @intCast(@min(logical - top, self.screen_rows - 1)) else 0;
                cursor.col = @min(new_cursor_col, new_cols - 1);
                return prompt_mark_out;
            }
        }
        cursor.row = 0;
        cursor.col = @min(cursor.col, new_cols - 1);
        return prompt_mark_out;
    }

    /// Wrap one logical line into `out` rows, tracking where the cursor's
    /// character lands. `abs` is recorded as base_id + index-at-emit so
    /// eviction during later emits stays accountable.
    fn emitLine(
        out: *PrimaryGrid,
        cells_in: []const Cell,
        cursor_char: ?usize,
        new_cursor_abs: *?usize,
        new_cursor_col: *u16,
    ) !void {
        // Trim the trailable tail — padding, not content. Lines rejoin
        // exactly because only attribute-free default blanks trim. Never
        // trim at or before the cursor's offset: shells track the cursor
        // against their own prompt geometry (trailing spaces included),
        // and shifting it breaks every relative repaint (RFC 0003).
        const floor: usize = if (cursor_char) |cc| @min(cc + 1, cells_in.len) else 0;
        var n = cells_in.len;
        while (n > floor and cells_in[n - 1].isTrimmable()) n -= 1;

        const cols = out.cols;
        var idx: usize = 0;
        while (true) {
            var take = @min(cols, n - idx);
            // Never split a wide pair across the wrap boundary.
            if (take > 0 and take < n - idx and cells_in[idx + take - 1].flags.wide) {
                take -= 1;
            }
            try out.pushBottom(.{});
            const row = out.rowAt(out.len - 1);
            @memcpy(row.cells[0..take], cells_in[idx .. idx + take]);
            const end = idx + take;
            row.wrapped = end < n;
            if (row.wrapped and take < cols) {
                // Re-created wide-split padding: keep it marked so the
                // next rewrap strips it again.
                for (row.cells[take..]) |*c| c.flags.wide_pad = true;
            }

            if (cursor_char) |cc| {
                const here = out.base_id + out.len - 1;
                if (cc >= idx and (cc < end or end >= n)) {
                    new_cursor_abs.* = @intCast(here);
                    new_cursor_col.* = @intCast(@min(cc - idx, cols - 1));
                }
            }

            idx = end;
            if (idx >= n) break;
        }
    }
};

pub const AltGrid = struct {
    alloc: std.mem.Allocator,
    cells: []Cell,
    cols: u16,
    rows: u16,

    pub fn init(alloc: std.mem.Allocator, cols: u16, rows: u16) !AltGrid {
        const cells = try alloc.alloc(Cell, @as(usize, cols) * rows);
        @memset(cells, .{});
        return .{ .alloc = alloc, .cells = cells, .cols = cols, .rows = rows };
    }

    pub fn deinit(self: *AltGrid) void {
        self.alloc.free(self.cells);
    }

    pub fn rowSlice(self: *const AltGrid, r: u16) []Cell {
        return self.cells[@as(usize, r) * self.cols ..][0..self.cols];
    }

    pub fn clearAll(self: *AltGrid, fill: Cell) void {
        @memset(self.cells, fill);
    }

    /// Clip/pad, top-left anchored — alt-screen apps repaint on SIGWINCH.
    pub fn resize(self: *AltGrid, new_cols: u16, new_rows: u16) !void {
        if (new_cols == self.cols and new_rows == self.rows) return;
        const fresh = try self.alloc.alloc(Cell, @as(usize, new_cols) * new_rows);
        @memset(fresh, .{});
        const copy_rows = @min(self.rows, new_rows);
        const copy_cols = @min(self.cols, new_cols);
        var r: u16 = 0;
        while (r < copy_rows) : (r += 1) {
            @memcpy(
                fresh[@as(usize, r) * new_cols ..][0..copy_cols],
                self.cells[@as(usize, r) * self.cols ..][0..copy_cols],
            );
        }
        self.alloc.free(self.cells);
        self.cells = fresh;
        self.cols = new_cols;
        self.rows = new_rows;
    }
};

pub fn rowIsBlank(row: *const Row) bool {
    for (row.cells) |c| {
        if (!c.isTrimmable()) return false;
    }
    return true;
}
