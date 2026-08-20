//! Terminal semantics: cursor discipline, modes, SGR state, and the
//! dispatch surface — operating on RFC 0003 storage (grid.zig): a
//! scrollback ring with wrap flags and reflow for the primary screen, a
//! flat clip/pad grid for the alt screen. Pure per RFC 0001 — no I/O;
//! effects leave through the action list.
//!
//! Codepoint widths and UAX #29 grapheme clusters follow the pinned
//! zg/Unicode data and mode-2027 policy in unicode-width.md.

const std = @import("std");
const DisplayWidth = @import("DisplayWidth");
const Graphemes = @import("Graphemes");
const colors = @import("color.zig");
const parser_mod = @import("parser.zig");
const mouse_mod = @import("mouse.zig");
const keyboard_mod = @import("keyboard.zig");
const graphics_mod = @import("graphics.zig");
const hyperlink_mod = @import("hyperlink.zig");
const search_mod = @import("search.zig");
const termcap = @import("termcap.zig");
const cell_mod = @import("cell.zig");
const grid = @import("grid.zig");
const version = @import("../version.zig");

pub const Color = colors.Color;
pub const Params = parser_mod.Params;
pub const Flags = cell_mod.Flags;
pub const Cell = cell_mod.Cell;
pub const Attrs = cell_mod.Attrs;
pub const max_grapheme_codepoints: usize = 64;
const max_decrqss_reply_bytes: usize = 160;
pub const max_cwd_uri_bytes: usize = 4096;
pub const Hyperlink = hyperlink_mod.Link;

pub const Notification = struct {
    title: []u8,
    body: []u8,
};

pub const PromptMark = union(enum) {
    prompt_start,
    command_start,
    command_executed,
    command_finished: ?u16,
};

pub const Action = union(enum) {
    bell,
    set_title: []u8,
    cwd_report: []u8,
    notify: Notification,
    prompt_mark: PromptMark,
    pty_write: []u8,
    graphics: graphics_mod.Command,
    /// XTWINOPS 8: the app asked to resize the grid. Policy belongs to the
    /// host: the GUI ignores it (RFC 0002 — the PTY never resizes the
    /// window); the headless esctest harness honors it.
    resize_request: struct { cols: u16, rows: u16 },
};

pub const Modes = struct {
    cursor_keys: bool = false, // DECCKM
    origin: bool = false, // DECOM
    autowrap: bool = true, // DECAWM
    cursor_visible: bool = true, // DECTCEM
    bracketed_paste: bool = false, // 2004
    focus_reporting: bool = false, // 1004: xterm focus in/out events
    synchronized_output: bool = false, // 2026: shell holds presentation
    grapheme_cluster: bool = false, // 2027: UAX #29 display units
    keypad_application: bool = false,
    mouse_tracking: mouse_mod.Tracking = .none,
    mouse_encoding: mouse_mod.Encoding = .legacy,
};

pub const ShellStatus = enum { unknown, prompt, executing };

pub const SelectionMode = enum { char, word, line };

const SelPoint = struct { id: u64, col: u16 };

/// RFC 0010: endpoints are pin-like (absolute row ids on the primary
/// screen, plain row indexes on the alt screen). View-state only — the
/// child app never observes it and no actions are emitted.
pub const Selection = struct {
    on_alt: bool,
    mode: SelectionMode,
    anchor: SelPoint,
    head: SelPoint,
};

const Charset = enum { ascii, dec_special };

const SavedCursor = struct {
    col: u16,
    row: u16,
    attrs: Attrs,
    origin: bool,
    pending_wrap: bool,
    charsets: [2]Charset,
    active_charset: u1,
    hyperlink_id: u32,
};

pub const Terminal = struct {
    alloc: std.mem.Allocator,
    cols: u16,
    rows: u16,
    pixel_width: u32 = 0,
    pixel_height: u32 = 0,

    primary: grid.PrimaryGrid,
    alt: grid.AltGrid,
    on_alt: bool = false,

    col: u16 = 0,
    row: u16 = 0,
    pending_wrap: bool = false,
    attrs: Attrs = .{},

    /// Scroll margins, inclusive rows.
    top: u16 = 0,
    bot: u16,

    modes: Modes = .{},
    pointer_shape: mouse_mod.PointerShape = .text,
    keyboard_primary: keyboard_mod.FlagStack = .{},
    keyboard_alt: keyboard_mod.FlagStack = .{},
    graphics: graphics_mod.State = .{},
    tabs: []bool,
    charsets: [2]Charset = .{ .ascii, .ascii },
    active_charset: u1 = 0,
    saved_primary: ?SavedCursor = null,
    saved_alt: ?SavedCursor = null,
    last_printed: ?u21 = null,

    /// OSC 133 semantic state (RFC 0006): milestone-4 attention feeds on
    /// this; reflow uses the mark to drop stale prompt paint.
    shell_status: ShellStatus = .unknown,
    last_exit: ?u16 = null,
    /// Absolute row id (primary grid) of the current prompt's first row.
    prompt_mark: ?u64 = null,

    selection: ?Selection = null,

    /// Changes on every BSU, including repeated sets while already active.
    /// The shell uses this to re-arm its fail-safe timer without putting
    /// time or I/O into the pure VT core (RFC 0004).
    sync_output_epoch: u64 = 0,
    /// Host-visible semantic/presentation generation. Search uses it only to
    /// reject a mask captured across output, reflow, or viewport movement.
    state_epoch: u64 = 1,

    actions: std.ArrayList(Action) = .empty,

    /// Suffix codepoints for multi-codepoint cells. Cells contain offsets
    /// into this arena and remain plain memcpy-safe values (RFC 0003).
    graphemes: std.ArrayList(u21) = .empty,
    grapheme_gc_at: usize = 4096,

    /// OSC 8 metadata is process-local and compacted by tracing cell ids.
    hyperlinks: std.ArrayList(Hyperlink) = .empty,
    hyperlink_bytes: usize = 0,
    active_hyperlink_id: u32 = 0,

    pub fn init(alloc: std.mem.Allocator, cols: u16, rows: u16) !Terminal {
        std.debug.assert(cols >= 2 and rows >= 1);
        var primary = try grid.PrimaryGrid.init(alloc, cols, rows);
        errdefer primary.deinit();
        var alt = try grid.AltGrid.init(alloc, cols, rows);
        errdefer alt.deinit();
        const tabs = try alloc.alloc(bool, cols);
        defaultTabs(tabs);
        return .{
            .alloc = alloc,
            .cols = cols,
            .rows = rows,
            .primary = primary,
            .alt = alt,
            .bot = rows - 1,
            .tabs = tabs,
        };
    }

    pub fn deinit(self: *Terminal) void {
        self.clearActions();
        self.actions.deinit(self.alloc);
        self.graphics.deinit(self.alloc);
        self.clearHyperlinks();
        self.hyperlinks.deinit(self.alloc);
        self.graphemes.deinit(self.alloc);
        self.primary.deinit();
        self.alt.deinit();
        self.alloc.free(self.tabs);
    }

    // -- host interface ----------------------------------------------------

    pub fn drainActions(self: *Terminal) []Action {
        return self.actions.items;
    }

    pub fn clearActions(self: *Terminal) void {
        for (self.actions.items) |a| switch (a) {
            .set_title => |t| self.alloc.free(t),
            .cwd_report => |uri| self.alloc.free(uri),
            .notify => |notification| {
                self.alloc.free(notification.title);
                self.alloc.free(notification.body);
            },
            .pty_write => |w| self.alloc.free(w),
            .graphics => |command| command.deinit(self.alloc),
            .bell, .prompt_mark, .resize_request => {},
        };
        self.actions.clearRetainingCapacity();
    }

    /// Screen-relative cell (viewport-independent): tests, checksum, dumps.
    pub fn cellAt(self: *const Terminal, r: u16, c: u16) Cell {
        return self.rowCells(r)[c];
    }

    /// Viewport-relative cell: what the renderer draws.
    pub fn viewCellAt(self: *const Terminal, r: u16, c: u16) Cell {
        if (self.on_alt) return self.alt.rowSlice(r)[c];
        return self.primary.viewRow(r).cells[c];
    }

    pub fn cellGrapheme(self: *const Terminal, cell: Cell) []const u21 {
        if (cell.grapheme_len == 0) return &.{};
        const offset: usize = cell.grapheme_offset;
        return self.graphemes.items[offset..][0..cell.grapheme_len];
    }

    pub fn viewCellGrapheme(self: *const Terminal, cell: Cell) []const u21 {
        return self.cellGrapheme(cell);
    }

    pub fn hyperlink(self: *const Terminal, id: u32) ?*const Hyperlink {
        if (id == 0 or id > self.hyperlinks.items.len) return null;
        return &self.hyperlinks.items[id - 1];
    }

    pub fn scrollbackLen(self: *const Terminal) usize {
        return if (self.on_alt) 0 else self.primary.scrollbackLen();
    }

    pub fn viewportOffset(self: *const Terminal) usize {
        return if (self.on_alt) 0 else self.primary.viewport_offset;
    }

    pub fn graphicsPlacements(self: *const Terminal) []const graphics_mod.Placement {
        return self.graphics.placements.items;
    }

    pub fn graphicsDrainPendingOrphans(self: *Terminal) graphics_mod.DeleteResult {
        return self.graphics.drainPendingOrphans();
    }

    pub fn graphicsPlacementViewRow(self: *const Terminal, placement: graphics_mod.Placement) ?i32 {
        if (placement.on_alt != self.on_alt) return null;
        if (placement.on_alt) {
            return std.math.cast(i32, placement.row_id);
        }
        const top_id = self.viewRowId(0);
        if (placement.row_id >= top_id)
            return std.math.cast(i32, placement.row_id - top_id);
        const distance = top_id - placement.row_id;
        const signed = std.math.cast(i32, distance) orelse return null;
        return -signed;
    }

    /// Complete host-owned resource work synchronously at the APC boundary.
    /// Cursor movement must happen before the parser sees later PTY bytes.
    pub fn graphicsCommitLoad(
        self: *Terminal,
        load: *const graphics_mod.Load,
        resource: graphics_mod.Resource,
    ) graphics_mod.CommitError!void {
        const geometry = try self.graphics.commitLoad(
            self.alloc,
            load,
            resource,
            self.pixel_width,
            self.pixel_height,
            self.cols,
            self.rows,
        );
        if (geometry) |value| if (!load.virtual and load.parent_image_id == 0 and !load.cursor_no_move)
            self.moveAfterGraphics(load.col, value);
    }

    pub fn graphicsCommitPut(
        self: *Terminal,
        put: *const graphics_mod.Put,
        resource: graphics_mod.Resource,
    ) graphics_mod.CommitError!void {
        const geometry = try self.graphics.commitPut(
            self.alloc,
            put,
            resource,
            self.pixel_width,
            self.pixel_height,
            self.cols,
            self.rows,
        );
        if (!put.virtual and put.parent_image_id == 0 and !put.cursor_no_move)
            self.moveAfterGraphics(put.col, geometry);
    }

    pub fn graphicsDelete(
        self: *Terminal,
        delete: graphics_mod.Delete,
        resolved_image_id: ?u32,
    ) graphics_mod.DeleteResult {
        return self.graphics.applyDelete(
            delete,
            resolved_image_id,
            self.pixel_width,
            self.pixel_height,
            self.cols,
            self.rows,
        );
    }

    pub fn graphicsRemoveImagePlacements(self: *Terminal, image_id: u32) graphics_mod.DeleteResult {
        return self.graphics.removeImagePlacements(image_id);
    }

    pub fn graphicsPlacementGeometry(
        self: *const Terminal,
        placement: graphics_mod.Placement,
    ) graphics_mod.CommitError!graphics_mod.Geometry {
        return graphics_mod.placementGeometry(
            placement,
            self.pixel_width,
            self.pixel_height,
            self.cols,
            self.rows,
        );
    }

    pub fn graphicsVirtualPlacement(
        self: *const Terminal,
        image_id: u32,
        placement_id: u32,
    ) ?graphics_mod.Placement {
        return self.graphics.virtualPlacement(image_id, placement_id, self.on_alt);
    }

    fn moveAfterGraphics(self: *Terminal, anchor_col: u16, geometry: graphics_mod.Geometry) void {
        const rows_to_move: u32 = @min(geometry.grid_rows, self.rows);
        var moved: u32 = 0;
        while (moved < rows_to_move) : (moved += 1) self.index();
        const requested_col = @as(u64, anchor_col) + geometry.grid_cols;
        self.col = @intCast(@min(requested_col, self.cols - 1));
        self.pending_wrap = false;
    }

    /// Positive delta scrolls up (into history). No-op on the alt screen —
    /// the host translates wheel events to arrows there (RFC 0003).
    pub fn scrollViewport(self: *Terminal, delta: i64) void {
        if (!self.on_alt) {
            const before = self.primary.viewport_offset;
            self.primary.scrollViewport(delta);
            if (before != self.primary.viewport_offset) self.bumpStateEpoch();
        }
    }

    pub fn viewportToBottom(self: *Terminal) void {
        const before = self.primary.viewport_offset;
        self.primary.viewportToBottom();
        if (before != 0) self.bumpStateEpoch();
    }

    pub fn keyboardFlags(self: *const Terminal) keyboard_mod.Flags {
        return if (self.on_alt) self.keyboard_alt.current() else self.keyboard_primary.current();
    }

    /// Native host action used by ⌘K. Unlike ED 3 received from the PTY,
    /// this is invoked by UI chrome; it has the same primary-screen storage
    /// semantics and deliberately leaves the alternate screen alone.
    pub fn clearScrollback(self: *Terminal) void {
        if (self.on_alt) return;
        self.primary.clearScrollback();
        self.selection = null;
        self.bumpStateEpoch();
    }

    /// Host watchdog escape hatch for an application that never emits ESU.
    pub fn forceEndSynchronizedOutput(self: *Terminal) void {
        self.modes.synchronized_output = false;
    }

    /// Grid as text, rows trimmed right — the snapshot format for tests
    /// and vtdiff. Wide spacers are skipped (the wide cp covers them).
    pub fn dumpText(self: *const Terminal, alloc: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        var r: u16 = 0;
        while (r < self.rows) : (r += 1) {
            if (r > 0) try out.append(alloc, '\n');
            const line_start = out.items.len;
            var last_ink = line_start;
            var c: u16 = 0;
            while (c < self.cols) : (c += 1) {
                const cell = self.cellAt(r, c);
                if (cell.flags.wide_spacer) continue;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cell.cp, &buf) catch blk: {
                    buf[0] = '?';
                    break :blk 1;
                };
                try out.appendSlice(alloc, buf[0..n]);
                for (self.cellGrapheme(cell)) |suffix| {
                    const suffix_n = std.unicode.utf8Encode(suffix, &buf) catch continue;
                    try out.appendSlice(alloc, buf[0..suffix_n]);
                }
                if (cell.cp != ' ' or cell.hasGrapheme()) last_ink = out.items.len;
            }
            out.shrinkRetainingCapacity(last_ink);
        }
        return out.toOwnedSlice(alloc);
    }

    pub fn resize(self: *Terminal, new_cols: u16, new_rows: u16) !void {
        if (new_cols == self.cols and new_rows == self.rows) return;
        std.debug.assert(new_cols >= 2 and new_rows >= 1);

        try self.alt.resize(new_cols, new_rows);

        // The primary screen reflows with cursor tracking; while on the
        // alt screen, its (saved) cursor is tracked approximately and
        // clamped — the shell repaints on SIGWINCH anyway.
        var cur: grid.Cursor = if (!self.on_alt)
            .{ .row = self.row, .col = self.col }
        else if (self.saved_primary) |s|
            .{ .row = @min(s.row, self.primary.screen_rows - 1), .col = s.col }
        else
            .{ .row = 0, .col = 0 };

        // Prompt-aware reflow (RFC 0006): at a marked prompt, the marked
        // region is shell paint — drop it and let SIGWINCH repaint it.
        var prompt: ?grid.PromptRegion = null;
        if (!self.on_alt and self.shell_status == .prompt) {
            if (self.prompt_mark) |mark| {
                if (mark >= self.primary.base_id) {
                    const logical: usize = @intCast(mark - self.primary.base_id);
                    const top = self.primary.len - self.primary.screen_rows;
                    const cursor_logical = top + cur.row;
                    if (logical >= top and logical <= cursor_logical) {
                        prompt = .{
                            .start = logical,
                            .cursor_rel = @intCast(cursor_logical - logical),
                        };
                    }
                }
            }
        }
        if (new_cols != self.cols) self.selection = null; // RFC 0010: reflow clears
        const new_mark = try self.primary.resize(new_cols, new_rows, &cur, prompt);
        if (prompt != null) self.prompt_mark = new_mark orelse self.prompt_mark;

        if (!self.on_alt) {
            self.row = cur.row;
            self.col = cur.col;
        } else {
            self.row = @min(self.row, new_rows - 1);
            self.col = @min(self.col, new_cols - 1);
            if (self.saved_primary) |*s| {
                s.row = cur.row;
                s.col = @min(cur.col, new_cols - 1);
            }
        }
        self.saved_alt = null;

        const tabs = try self.alloc.alloc(bool, new_cols);
        defaultTabs(tabs);
        self.alloc.free(self.tabs);
        self.tabs = tabs;

        self.cols = new_cols;
        self.rows = new_rows;
        self.top = 0;
        self.bot = new_rows - 1;
        self.pending_wrap = false;
        // A resize must always be presentable even if the child was midway
        // through a synchronized update (RFC 0004; Ghostty oracle).
        self.modes.synchronized_output = false;
        self.bumpStateEpoch();
    }

    /// Host-supplied backing-pixel geometry for PTY/window-size reports. This
    /// is data only: the pure VT performs no platform or renderer queries.
    pub fn setPixelSize(self: *Terminal, width: u32, height: u32) void {
        self.pixel_width = width;
        self.pixel_height = height;
    }

    // -- selection (RFC 0010) ------------------------------------------------

    fn viewRowId(self: *const Terminal, r: u16) u64 {
        if (self.on_alt) return r;
        return self.primary.base_id + (self.primary.len - self.primary.screen_rows - self.primary.viewport_offset + r);
    }

    fn screenRowId(self: *const Terminal, r: u16) u64 {
        if (self.on_alt) return r;
        return self.primary.base_id + (self.primary.len - self.primary.screen_rows + r);
    }

    fn idCells(self: *const Terminal, id: u64) ?[]Cell {
        if (self.on_alt) {
            if (id >= self.rows) return null;
            return self.alt.rowSlice(@intCast(id));
        }
        if (id < self.primary.base_id) return null;
        const logical: usize = @intCast(id - self.primary.base_id);
        if (logical >= self.primary.len) return null;
        return self.primary.rowAt(logical).cells;
    }

    fn idWrapped(self: *const Terminal, id: u64) bool {
        if (self.on_alt) return false;
        if (id < self.primary.base_id) return false;
        const logical: usize = @intCast(id - self.primary.base_id);
        if (logical >= self.primary.len) return false;
        return self.primary.rowAt(logical).wrapped;
    }

    pub fn selectionStart(self: *Terminal, view_row: u16, col: u16, mode: SelectionMode) void {
        const p: SelPoint = .{ .id = self.viewRowId(view_row), .col = @min(col, self.cols - 1) };
        self.selection = .{ .on_alt = self.on_alt, .mode = mode, .anchor = p, .head = p };
    }

    pub fn selectionDrag(self: *Terminal, view_row: u16, col: u16) void {
        if (self.selection) |*sel| {
            if (sel.on_alt != self.on_alt) return;
            sel.head = .{ .id = self.viewRowId(view_row), .col = @min(col, self.cols - 1) };
        }
    }

    pub fn selectionClear(self: *Terminal) void {
        self.selection = null;
    }

    /// Normalized, snapped, eviction-clamped range — or null when the
    /// selection is gone (evicted, wrong screen).
    fn selectionRange(self: *const Terminal) ?[2]SelPoint {
        const sel = self.selection orelse return null;
        if (sel.on_alt != self.on_alt) return null;

        var a = sel.anchor;
        var b = sel.head;
        if (b.id < a.id or (b.id == a.id and b.col < a.col)) std.mem.swap(SelPoint, &a, &b);

        if (!self.on_alt) {
            // Eviction clamps the start; a fully evicted range is dead.
            if (b.id < self.primary.base_id) return null;
            if (a.id < self.primary.base_id) a = .{ .id = self.primary.base_id, .col = 0 };
        }

        switch (sel.mode) {
            .char => {},
            .word => {
                a.col = self.snapWordLeft(a);
                b.col = self.snapWordRight(b);
            },
            .line => {
                while (a.id > 0 and self.idWrapped(a.id - 1)) a.id -= 1;
                a.col = 0;
                while (self.idWrapped(b.id)) b.id += 1;
                b.col = self.cols - 1;
            },
        }

        // Wide pairs never split (RFC 0010).
        if (self.idCells(a.id)) |cells| {
            if (a.col > 0 and cells[a.col].flags.wide_spacer) a.col -= 1;
        }
        if (self.idCells(b.id)) |cells| {
            if (cells[b.col].flags.wide and b.col + 1 < self.cols) b.col += 1;
        }
        return .{ a, b };
    }

    fn cellIsWordChar(cell: Cell) bool {
        return cell.flags.wide_spacer or (cell.cp != ' ' and !cell.flags.wide_pad);
    }

    fn snapWordLeft(self: *const Terminal, p: SelPoint) u16 {
        const cells = self.idCells(p.id) orelse return p.col;
        if (!cellIsWordChar(cells[p.col])) return p.col;
        var c = p.col;
        while (c > 0 and cellIsWordChar(cells[c - 1])) c -= 1;
        return c;
    }

    fn snapWordRight(self: *const Terminal, p: SelPoint) u16 {
        const cells = self.idCells(p.id) orelse return p.col;
        if (!cellIsWordChar(cells[p.col])) return p.col;
        var c = p.col;
        while (c + 1 < self.cols and cellIsWordChar(cells[c + 1])) c += 1;
        return c;
    }

    /// Is this view cell inside the selection? Renderer hot path.
    pub fn viewCellSelected(self: *const Terminal, view_row: u16, col: u16) bool {
        const range = self.selectionRange() orelse return false;
        const id = self.viewRowId(view_row);
        const a = range[0];
        const b = range[1];
        if (id < a.id or id > b.id) return false;
        if (id == a.id and col < a.col) return false;
        if (id == b.id and col > b.col) return false;
        return true;
    }

    pub fn viewCellSearchMatch(_: *const Terminal, _: u16, _: u16) bool {
        return false;
    }

    pub fn viewCellSearchSelected(_: *const Terminal, _: u16, _: u16) bool {
        return false;
    }

    pub fn hasSelection(self: *const Terminal) bool {
        return self.selectionRange() != null;
    }

    /// Extract the selected text (RFC 0010): soft-wrapped rows join with
    /// no newline, hard rows join with \n and trim trailing blanks; wide
    /// spacers and wide_pad filler are skipped. Null when no selection.
    pub fn selectionText(self: *const Terminal, alloc: std.mem.Allocator) !?[]u8 {
        const range = self.selectionRange() orelse return null;
        const a = range[0];
        const b = range[1];

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);

        var id = a.id;
        while (id <= b.id) : (id += 1) {
            const cells = self.idCells(id) orelse break;
            const from: u16 = if (id == a.id) a.col else 0;
            const to: u16 = if (id == b.id) b.col else self.cols - 1;
            const row_start = out.items.len;
            var last_ink = row_start;
            var c = from;
            while (c <= to) : (c += 1) {
                const cell = cells[c];
                if (cell.flags.wide_spacer or cell.flags.wide_pad) continue;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cell.cp, &buf) catch continue;
                try out.appendSlice(alloc, buf[0..n]);
                for (self.cellGrapheme(cell)) |suffix| {
                    const suffix_n = std.unicode.utf8Encode(suffix, &buf) catch continue;
                    try out.appendSlice(alloc, buf[0..suffix_n]);
                }
                if (cell.cp != ' ' or cell.hasGrapheme()) last_ink = out.items.len;
            }
            if (!self.idWrapped(id)) {
                out.shrinkRetainingCapacity(last_ink);
                if (id != b.id) try out.append(alloc, '\n');
            }
        }
        return try out.toOwnedSlice(alloc);
    }

    // -- terminal-text search (RFC 0016) -----------------------------------

    /// Search retained terminal text in chronological order. The result pins
    /// refer to absolute primary-grid row ids (or fixed alt-screen rows), so
    /// the host can reveal/highlight them without copying scrollback into the
    /// viewer. Matching itself is pure and uses zg's canonical caseless
    /// search; soft wraps are joined and storage-only cells are omitted.
    pub fn searchText(
        self: *const Terminal,
        alloc: std.mem.Allocator,
        query: []const u8,
    ) !search_mod.Results {
        var corpus = try self.searchCorpus(alloc);
        defer corpus.deinit(alloc);
        return corpus.find(alloc, query);
    }

    pub fn searchCorpus(
        self: *const Terminal,
        alloc: std.mem.Allocator,
    ) !search_mod.Corpus {
        const descriptor = self.searchCorpusDescriptor();
        var corpus = try search_mod.Corpus.init(alloc, descriptor);
        errdefer corpus.deinit(alloc);
        if (!self.copySearchCorpusGraphemes(descriptor, corpus.graphemes) or
            !self.copySearchCorpusRows(descriptor, &corpus, 0, descriptor.row_count))
            return error.SearchCorpusChanged;
        return corpus;
    }

    pub fn searchCorpusDescriptor(self: *const Terminal) search_mod.CorpusDescriptor {
        return .{
            .state_epoch = self.state_epoch,
            .on_alt = self.on_alt,
            .cols = self.cols,
            .screen_rows = self.rows,
            .row_count = if (self.on_alt) self.rows else self.primary.len,
            .base_id = if (self.on_alt) 0 else self.primary.base_id,
            .grapheme_len = self.graphemes.items.len,
        };
    }

    pub fn copySearchCorpusGraphemes(
        self: *const Terminal,
        descriptor: search_mod.CorpusDescriptor,
        out: []u21,
    ) bool {
        if (self.state_epoch != descriptor.state_epoch or
            self.on_alt != descriptor.on_alt or self.cols != descriptor.cols or
            self.rows != descriptor.screen_rows or out.len != descriptor.grapheme_len or
            self.graphemes.items.len < descriptor.grapheme_len)
            return false;
        @memcpy(out, self.graphemes.items[0..descriptor.grapheme_len]);
        return true;
    }

    pub fn copySearchCorpusRows(
        self: *const Terminal,
        descriptor: search_mod.CorpusDescriptor,
        corpus: *search_mod.Corpus,
        start: usize,
        count: usize,
    ) bool {
        if (self.state_epoch != descriptor.state_epoch or
            self.on_alt != descriptor.on_alt or self.cols != descriptor.cols or
            self.rows != descriptor.screen_rows or start + count > descriptor.row_count)
            return false;
        var offset: usize = 0;
        while (offset < count) : (offset += 1) {
            const target = start + offset;
            var source: []const Cell = undefined;
            var wrapped = false;
            if (descriptor.on_alt) {
                if (target >= self.rows) return false;
                source = self.alt.rowSlice(@intCast(target));
            } else {
                const id = descriptor.base_id + target;
                if (id < self.primary.base_id) return false;
                const logical: usize = @intCast(id - self.primary.base_id);
                if (logical >= self.primary.len) return false;
                const row = self.primary.rowAt(logical);
                source = row.cells;
                wrapped = row.wrapped;
            }
            @memcpy(corpus.cells[target * descriptor.cols ..][0..descriptor.cols], source);
            corpus.rows[target] = .{
                .id = if (descriptor.on_alt) target else descriptor.base_id + target,
                .wrapped = wrapped,
            };
        }
        return true;
    }

    pub fn searchViewTopId(self: *const Terminal) u64 {
        return self.viewRowId(0);
    }

    /// Reveal a still-live semantic result pin. This is viewport-only state:
    /// cursor, selection, modes, and child-visible bytes are unchanged.
    pub fn revealSearchMatch(self: *Terminal, match: search_mod.Match) bool {
        if (self.on_alt) return match.start.row_id < self.rows;
        if (match.start.row_id < self.primary.base_id) return false;
        const target: usize = @intCast(match.start.row_id - self.primary.base_id);
        if (target >= self.primary.len) return false;
        const live_top = self.primary.len - self.primary.screen_rows;
        const context = @as(usize, self.rows) / 3;
        const desired_top = @min(target -| context, live_top);
        self.primary.viewport_offset = live_top - desired_top;
        self.bumpStateEpoch();
        return true;
    }

    pub fn bumpStateEpoch(self: *Terminal) void {
        self.state_epoch +%= 1;
        if (self.state_epoch == 0) self.state_epoch = 1;
    }

    pub fn searchMatchLive(self: *const Terminal, match: search_mod.Match) bool {
        if (match.start.col >= self.cols or match.end.col >= self.cols) return false;
        if (self.on_alt)
            return match.start.row_id < self.rows and match.end.row_id < self.rows;
        const end_id = self.primary.base_id + self.primary.len;
        return match.start.row_id >= self.primary.base_id and match.end.row_id < end_id;
    }

    // -- row access ---------------------------------------------------------

    fn rowCells(self: *const Terminal, r: u16) []Cell {
        if (self.on_alt) return self.alt.rowSlice(r);
        return self.primary.screenRow(r).cells;
    }

    fn setWrapped(self: *Terminal, r: u16, wrapped: bool) void {
        if (!self.on_alt) self.primary.screenRow(r).wrapped = wrapped;
    }

    fn copyRowInto(self: *Terminal, src: u16, dst: u16) void {
        @memcpy(self.rowCells(dst), self.rowCells(src));
        if (!self.on_alt) {
            self.primary.screenRow(dst).wrapped = self.primary.screenRow(src).wrapped;
        }
    }

    fn clearRow(self: *Terminal, r: u16) void {
        @memset(self.rowCells(r), self.blankCell());
        self.setWrapped(r, false);
        // A cleared row cannot be a continuation (RFC 0003 wrap-flag
        // ownership rule 2).
        if (r > 0) self.setWrapped(r - 1, false);
    }

    // -- parser handler interface -------------------------------------------

    pub fn print(self: *Terminal, cp_in: u21) void {
        var cp = cp_in;
        if (self.charsets[self.active_charset] == .dec_special) {
            cp = decSpecial(cp);
        }

        // Full-Unicode mode may join a non-zero-width codepoint (ZWJ emoji,
        // RI pairs, Indic conjuncts, Hangul) to the preceding cell. Keep the
        // ASCII path table-free: no printable ASCII pair can join here.
        if (self.modes.grapheme_cluster and cp > 0xff) {
            if (self.appendFullGrapheme(cp)) return;
        }

        const width = charWidth(cp);
        if (width == 0) {
            // Legacy mode still preserves ordinary combining suffixes without
            // changing the application's wcwidth cursor model.
            if (!self.modes.grapheme_cluster) self.appendLegacySuffix(cp);
            return;
        }

        if (self.pending_wrap and self.modes.autowrap) {
            self.setWrapped(self.row, true);
            self.col = 0;
            self.index();
            self.pending_wrap = false;
        }

        if (width == 2 and self.col == self.cols - 1) {
            // A wide char cannot straddle the edge: pad the last column
            // and wrap (or clip when autowrap is off).
            self.rowCells(self.row)[self.col] = .{
                .bg = self.attrs.bg,
                .flags = .{ .wide_pad = true },
            };
            if (!self.modes.autowrap) return;
            self.setWrapped(self.row, true);
            self.col = 0;
            self.index();
        }

        var flags = self.attrs.flags;
        flags.wide = width == 2;
        flags.wide_spacer = false;
        flags.content = true;
        self.clearWideAt(self.row, self.col);
        const cells = self.rowCells(self.row);
        cells[self.col] = .{
            .cp = cp,
            .flags = flags,
            .fg = self.attrs.fg,
            .bg = self.attrs.bg,
            .underline_color = self.attrs.underline_color,
            .hyperlink_id = self.active_hyperlink_id,
        };
        if (width == 2) {
            var spacer_flags = self.attrs.flags;
            spacer_flags.wide_spacer = true;
            spacer_flags.content = false;
            self.clearWideAt(self.row, self.col + 1);
            cells[self.col + 1] = .{
                .cp = ' ',
                .flags = spacer_flags,
                .fg = self.attrs.fg,
                .bg = self.attrs.bg,
                .underline_color = self.attrs.underline_color,
                .hyperlink_id = self.active_hyperlink_id,
            };
        }

        self.last_printed = cp;
        const next = @as(u32, self.col) + width;
        if (next >= self.cols) {
            // The row's end was rewritten: any stale continuation claim
            // dies here; a real wrap event re-sets it (RFC 0003 rule 1).
            self.setWrapped(self.row, false);
            self.col = self.cols - 1;
            self.pending_wrap = self.modes.autowrap;
        } else {
            self.col = @intCast(next);
        }
    }

    const PreviousCell = struct { row: u16, col: u16 };

    fn previousContentCell(self: *Terminal) ?PreviousCell {
        if (self.col == 0 and !self.pending_wrap) return null;

        var col: u16 = if (self.pending_wrap)
            self.col
        else if (!self.modes.autowrap and self.col == self.cols - 1 and
            self.rowCells(self.row)[self.col].flags.content)
            self.col
        else
            self.col - 1;

        const cells = self.rowCells(self.row);
        if (cells[col].flags.wide_spacer) {
            if (col == 0) return null;
            col -= 1;
        }
        if (cells[col].flags.wide_pad or !cells[col].flags.content) return null;
        return .{ .row = self.row, .col = col };
    }

    fn appendLegacySuffix(self: *Terminal, cp: u21) void {
        const pos = self.previousContentCell() orelse return;
        const cell = &self.rowCells(pos.row)[pos.col];
        // A variation selector on a non-emoji base is malformed terminal
        // input; consuming it without widening matches the Ghostty oracle.
        if ((cp == 0xfe0e or cp == 0xfe0f) and !Graphemes.isEmoji(cell.cp)) return;
        self.appendSuffix(cell, cp) catch {};
    }

    /// Returns true when `cp` belongs to (or was consumed as an over-limit
    /// continuation of) the preceding cluster.
    fn appendFullGrapheme(self: *Terminal, cp: u21) bool {
        const pos = self.previousContentCell() orelse return false;
        const cells = self.rowCells(pos.row);
        const current = cells[pos.col];

        var state: Graphemes.IterState = .{};
        var previous = current.cp;
        for (self.cellGrapheme(current)) |suffix| {
            _ = Graphemes.graphemeBreak(previous, suffix, &state);
            previous = suffix;
        }
        if (Graphemes.graphemeBreak(previous, cp, &state)) return false;

        if ((cp == 0xfe0e or cp == 0xfe0f) and !Graphemes.isEmoji(current.cp)) {
            return true;
        }
        if (current.grapheme_len >= max_grapheme_codepoints - 1) return true;

        const old_width: u2 = if (current.flags.wide) 2 else 1;
        const new_width = self.graphemeWidthWith(current, cp);
        if (old_width == 1 and new_width == 2 and
            pos.col == self.cols - 1 and !self.modes.autowrap)
        {
            return true;
        }

        self.appendSuffix(&cells[pos.col], cp) catch return true;
        if (new_width != old_width) self.changeClusterWidth(pos, old_width, new_width);
        return true;
    }

    fn graphemeWidthWith(self: *const Terminal, cell: Cell, cp: u21) u2 {
        var utf8: [max_grapheme_codepoints * 4]u8 = undefined;
        var len: usize = 0;
        len += std.unicode.utf8Encode(cell.cp, utf8[len..][0..4]) catch return 1;
        for (self.cellGrapheme(cell)) |suffix| {
            len += std.unicode.utf8Encode(suffix, utf8[len..][0..4]) catch continue;
        }
        len += std.unicode.utf8Encode(cp, utf8[len..][0..4]) catch return 1;
        const width = DisplayWidth.graphemeWidth(utf8[0..len]);
        if (width <= 0) return 1;
        return if (width == 1) 1 else 2;
    }

    fn changeClusterWidth(
        self: *Terminal,
        pos: PreviousCell,
        old_width: u2,
        new_width: u2,
    ) void {
        if (old_width == 1 and new_width == 2) {
            if (pos.col == self.cols - 1) {
                // The one-cell cluster was pending at the edge. Turn that
                // location into explicit wrap padding and move the complete
                // cluster to the next row before adding its spacer.
                const moved = self.rowCells(pos.row)[pos.col];
                var pad = self.blankCell();
                pad.bg = moved.bg;
                pad.flags.wide_pad = true;
                self.rowCells(pos.row)[pos.col] = pad;
                self.setWrapped(pos.row, true);
                self.col = 0;
                self.index();
                self.pending_wrap = false;

                var head = moved;
                head.flags.wide = true;
                head.flags.wide_spacer = false;
                self.clearWideAt(self.row, 0);
                self.rowCells(self.row)[0] = head;
                self.writeWideSpacer(self.row, 1, head);
                self.advanceAfterCluster(0, 2);
                return;
            }

            const head = &self.rowCells(pos.row)[pos.col];
            head.flags.wide = true;
            self.writeWideSpacer(pos.row, pos.col + 1, head.*);
            self.advanceAfterCluster(pos.col, 2);
            return;
        }

        if (old_width == 2 and new_width == 1) {
            const head = &self.rowCells(pos.row)[pos.col];
            head.flags.wide = false;
            if (pos.col + 1 < self.cols) {
                self.rowCells(pos.row)[pos.col + 1] = self.blankCell();
            }
            self.col = pos.col + 1;
            self.pending_wrap = false;
        }
    }

    fn writeWideSpacer(self: *Terminal, row: u16, col: u16, head: Cell) void {
        self.clearWideAt(row, col);
        var spacer_flags = head.flags;
        spacer_flags.wide = false;
        spacer_flags.wide_spacer = true;
        spacer_flags.content = false;
        self.rowCells(row)[col] = .{
            .flags = spacer_flags,
            .fg = head.fg,
            .bg = head.bg,
            .underline_color = head.underline_color,
            .hyperlink_id = head.hyperlink_id,
        };
    }

    fn advanceAfterCluster(self: *Terminal, head_col: u16, width: u2) void {
        const next = @as(u32, head_col) + width;
        if (next >= self.cols) {
            self.col = self.cols - 1;
            self.pending_wrap = self.modes.autowrap;
        } else {
            self.col = @intCast(next);
            self.pending_wrap = false;
        }
    }

    fn appendSuffix(self: *Terminal, cell: *Cell, cp: u21) !void {
        if (cell.grapheme_len >= max_grapheme_codepoints - 1) return;
        self.maybeCompactGraphemes() catch {};

        var old: [max_grapheme_codepoints - 1]u21 = undefined;
        const old_len: usize = cell.grapheme_len;
        @memcpy(old[0..old_len], self.cellGrapheme(cell.*));
        const offset = self.graphemes.items.len;
        if (offset > std.math.maxInt(u32)) return error.OutOfMemory;
        try self.graphemes.ensureUnusedCapacity(self.alloc, old_len + 1);
        self.graphemes.appendSliceAssumeCapacity(old[0..old_len]);
        self.graphemes.appendAssumeCapacity(cp);
        cell.grapheme_offset = @intCast(offset);
        cell.grapheme_len += 1;
    }

    fn maybeCompactGraphemes(self: *Terminal) !void {
        if (self.graphemes.items.len < self.grapheme_gc_at) return;

        var live: usize = 0;
        var i: usize = 0;
        while (i < self.primary.len) : (i += 1) {
            for (self.primary.rowAt(i).cells) |cell| live += cell.grapheme_len;
        }
        for (self.alt.cells) |cell| live += cell.grapheme_len;

        var fresh: std.ArrayList(u21) = .empty;
        errdefer fresh.deinit(self.alloc);
        try fresh.ensureTotalCapacity(self.alloc, live);

        i = 0;
        while (i < self.primary.len) : (i += 1) {
            self.compactCellSlice(&fresh, self.primary.rowAt(i).cells);
        }
        self.compactCellSlice(&fresh, self.alt.cells);

        self.graphemes.deinit(self.alloc);
        self.graphemes = fresh;
        self.grapheme_gc_at = @max(@as(usize, 4096), self.graphemes.items.len * 2);
    }

    fn compactCellSlice(self: *Terminal, fresh: *std.ArrayList(u21), cells: []Cell) void {
        for (cells) |*cell| {
            if (!cell.hasGrapheme()) continue;
            const suffix = self.cellGrapheme(cell.*);
            cell.grapheme_offset = @intCast(fresh.items.len);
            fresh.appendSliceAssumeCapacity(suffix);
        }
    }

    fn oscHyperlink(self: *Terminal, data: []const u8) void {
        const separator = std.mem.indexOfScalar(u8, data, ';') orelse return;
        const params = data[0..separator];
        const uri = data[separator + 1 ..];
        if (!hyperlink_mod.validPrintableAscii(params) or
            !hyperlink_mod.validPrintableAscii(uri)) return;

        if (uri.len == 0) {
            if (params.len == 0) self.active_hyperlink_id = 0;
            return;
        }
        if (uri.len > hyperlink_mod.max_uri_bytes) return;

        var explicit_id: []const u8 = &.{};
        var options = std.mem.splitScalar(u8, params, ':');
        while (options.next()) |option| {
            const equals = std.mem.indexOfScalar(u8, option, '=') orelse continue;
            if (!std.mem.eql(u8, option[0..equals], "id")) continue;
            const value = option[equals + 1 ..];
            if (value.len > hyperlink_mod.max_explicit_id_bytes) return;
            explicit_id = value;
        }

        self.active_hyperlink_id = self.internHyperlink(explicit_id, uri) catch 0;
    }

    fn internHyperlink(self: *Terminal, explicit_id: []const u8, uri: []const u8) !u32 {
        // Explicit identity deliberately survives noncontiguous repaint. An
        // implicit opening always creates a fresh run, per the OSC 8
        // convention's VTE-shaped recommendation.
        if (explicit_id.len != 0) {
            for (self.hyperlinks.items, 1..) |link, link_index| {
                if (std.mem.eql(u8, link.explicit_id, explicit_id) and
                    std.mem.eql(u8, link.uri, uri)) return @intCast(link_index);
            }
        }

        const added_bytes = explicit_id.len + uri.len;
        if (self.hyperlinks.items.len >= hyperlink_mod.max_entries or
            added_bytes > hyperlink_mod.max_metadata_bytes -| self.hyperlink_bytes)
        {
            try self.compactHyperlinks();
        }
        if (self.hyperlinks.items.len >= hyperlink_mod.max_entries or
            added_bytes > hyperlink_mod.max_metadata_bytes -| self.hyperlink_bytes)
            return error.HyperlinkCapacity;

        const id_copy = try self.alloc.dupe(u8, explicit_id);
        errdefer self.alloc.free(id_copy);
        const uri_copy = try self.alloc.dupe(u8, uri);
        errdefer self.alloc.free(uri_copy);
        try self.hyperlinks.append(self.alloc, .{
            .explicit_id = id_copy,
            .uri = uri_copy,
        });
        self.hyperlink_bytes += added_bytes;
        return @intCast(self.hyperlinks.items.len);
    }

    fn compactHyperlinks(self: *Terminal) !void {
        const count = self.hyperlinks.items.len;
        if (count == 0) return;
        const live = try self.alloc.alloc(bool, count + 1);
        defer self.alloc.free(live);
        @memset(live, false);

        markHyperlink(live, self.active_hyperlink_id);
        if (self.saved_primary) |saved| markHyperlink(live, saved.hyperlink_id);
        if (self.saved_alt) |saved| markHyperlink(live, saved.hyperlink_id);
        var row_index: usize = 0;
        while (row_index < self.primary.len) : (row_index += 1) {
            for (self.primary.rowAt(row_index).cells) |cell| markHyperlink(live, cell.hyperlink_id);
        }
        for (self.alt.cells) |cell| markHyperlink(live, cell.hyperlink_id);

        var live_count: usize = 0;
        for (live[1..]) |is_live| live_count += @intFromBool(is_live);
        var remap = try self.alloc.alloc(u32, count + 1);
        defer self.alloc.free(remap);
        @memset(remap, 0);
        var fresh: std.ArrayList(Hyperlink) = .empty;
        errdefer fresh.deinit(self.alloc);
        try fresh.ensureTotalCapacity(self.alloc, live_count);

        var fresh_bytes: usize = 0;
        for (self.hyperlinks.items, 1..) |link, old_id| {
            if (!live[old_id]) continue;
            fresh.appendAssumeCapacity(link);
            remap[old_id] = @intCast(fresh.items.len);
            fresh_bytes += link.byteLen();
        }

        self.active_hyperlink_id = remapHyperlink(remap, self.active_hyperlink_id);
        if (self.saved_primary) |*saved|
            saved.hyperlink_id = remapHyperlink(remap, saved.hyperlink_id);
        if (self.saved_alt) |*saved|
            saved.hyperlink_id = remapHyperlink(remap, saved.hyperlink_id);
        row_index = 0;
        while (row_index < self.primary.len) : (row_index += 1) {
            remapHyperlinkCells(remap, self.primary.rowAt(row_index).cells);
        }
        remapHyperlinkCells(remap, self.alt.cells);

        for (self.hyperlinks.items, 1..) |*link, old_id| {
            if (!live[old_id]) link.deinit(self.alloc);
        }
        self.hyperlinks.deinit(self.alloc);
        self.hyperlinks = fresh;
        self.hyperlink_bytes = fresh_bytes;
    }

    fn clearHyperlinks(self: *Terminal) void {
        for (self.hyperlinks.items) |*link| link.deinit(self.alloc);
        self.hyperlinks.clearRetainingCapacity();
        self.hyperlink_bytes = 0;
    }

    fn markHyperlink(live: []bool, id: u32) void {
        if (id > 0 and id < live.len) live[id] = true;
    }

    fn remapHyperlink(remap: []const u32, id: u32) u32 {
        return if (id < remap.len) remap[id] else 0;
    }

    fn remapHyperlinkCells(remap: []const u32, cells: []Cell) void {
        for (cells) |*cell| cell.hyperlink_id = remapHyperlink(remap, cell.hyperlink_id);
    }

    pub fn execute(self: *Terminal, byte: u8) void {
        switch (byte) {
            0x07 => self.push(.bell),
            0x08 => { // BS
                if (self.col > 0) self.col -= 1;
                self.pending_wrap = false;
            },
            0x09 => self.horizontalTab(),
            0x0A, 0x0B, 0x0C => self.index(), // LF, VT, FF
            0x0D => { // CR
                self.col = 0;
                self.pending_wrap = false;
            },
            0x0E => self.active_charset = 1, // SO -> G1
            0x0F => self.active_charset = 0, // SI -> G0
            else => {},
        }
    }

    pub fn escDispatch(self: *Terminal, final: u8, intermediates: []const u8) void {
        if (intermediates.len == 1) {
            switch (intermediates[0]) {
                '#' => {
                    if (final == '8') self.decAlign(); // DECALN
                    return;
                },
                '(' => {
                    self.charsets[0] = designate(final);
                    return;
                },
                ')' => {
                    self.charsets[1] = designate(final);
                    return;
                },
                '*', '+' => return, // G2/G3 unsupported, consumed
                else => return,
            }
        }
        if (intermediates.len != 0) return;
        switch (final) {
            '7' => self.saveCursor(),
            '8' => self.restoreCursor(),
            'D' => self.index(), // IND
            'E' => { // NEL
                self.col = 0;
                self.pending_wrap = false;
                self.index();
            },
            'M' => self.reverseIndex(), // RI
            'H' => self.tabs[self.col] = true, // HTS
            'c' => self.fullReset(), // RIS
            '=' => self.modes.keypad_application = true,
            '>' => self.modes.keypad_application = false,
            else => {},
        }
    }

    pub fn csiDispatch(self: *Terminal, final: u8, intermediates: []const u8, params: *const Params) void {
        const private = intermediates.len > 0 and intermediates[0] == '?';
        const gt = intermediates.len > 0 and intermediates[0] == '>';
        const trailing: ?u8 = if (intermediates.len > 0 and intermediates[intermediates.len - 1] >= 0x20 and intermediates[intermediates.len - 1] <= 0x2F)
            intermediates[intermediates.len - 1]
        else
            null;

        switch (final) {
            'A' => self.cursorUp(params.get(0, 1)),
            'B' => self.cursorDown(params.get(0, 1)),
            'C' => self.cursorRight(params.get(0, 1)),
            'D' => self.cursorLeft(params.get(0, 1)),
            'E' => {
                self.cursorDown(params.get(0, 1));
                self.col = 0;
            },
            'F' => {
                self.cursorUp(params.get(0, 1));
                self.col = 0;
            },
            'G', '`' => { // CHA / HPA
                self.col = @min(params.get(0, 1) - 1, self.cols - 1);
                self.pending_wrap = false;
            },
            'H', 'f' => self.setPos(params.get(0, 1) - 1, params.get(1, 1) - 1),
            'd' => { // VPA
                const r = params.get(0, 1) - 1;
                self.row = self.clampRowOrigin(r);
                self.pending_wrap = false;
            },
            'I' => { // CHT
                var n = params.get(0, 1);
                while (n > 0) : (n -= 1) self.horizontalTab();
            },
            'Z' => { // CBT
                var n = params.get(0, 1);
                while (n > 0) : (n -= 1) self.backTab();
            },
            'J' => self.eraseDisplay(params.raw(0)),
            'K' => self.eraseLine(params.raw(0)),
            'L' => self.insertLines(params.get(0, 1)),
            'M' => self.deleteLines(params.get(0, 1)),
            '@' => self.insertChars(params.get(0, 1)),
            'P' => self.deleteChars(params.get(0, 1)),
            'X' => self.eraseChars(params.get(0, 1)),
            'S' => self.scrollUp(params.get(0, 1), false),
            'T' => self.scrollDown(params.get(0, 1)),
            'b' => { // REP
                if (self.last_printed) |cp| {
                    var n = @min(params.get(0, 1), @as(u16, 4096));
                    while (n > 0) : (n -= 1) self.print(cp);
                }
            },
            'c' => {
                if (private) return;
                if (gt) {
                    self.reply("\x1b[>1;10;0c"); // DA2: VT220-class, version 10
                } else {
                    self.reply("\x1b[?6c"); // DA1: VT102
                }
            },
            'g' => switch (params.raw(0)) {
                0 => self.tabs[self.col] = false,
                3 => @memset(self.tabs, false),
                else => {},
            },
            'h' => self.setModes(private, params, true),
            'l' => self.setModes(private, params, false),
            'm' => {
                if (private or gt) return; // XTMODKEYS etc: consumed
                self.sgr(params);
            },
            'n' => switch (params.raw(0)) {
                5 => self.reply("\x1b[0n"),
                6 => self.cursorPositionReport(),
                else => {},
            },
            'r' => { // DECSTBM
                if (private) return;
                const t = params.get(0, 1) - 1;
                const b = params.get(1, self.rows) - 1;
                if (t >= b or b >= self.rows) {
                    // Full-screen reset when args are degenerate/default.
                    if (params.len == 0 or (t == 0 and b >= self.rows - 1)) {
                        self.top = 0;
                        self.bot = self.rows - 1;
                        self.setPos(0, 0);
                    }
                    return;
                }
                self.top = t;
                self.bot = b;
                self.setPos(0, 0);
            },
            's' => {
                if (intermediates.len == 0) self.saveCursor(); // SCOSC
            },
            'u' => {
                if (intermediates.len == 0) {
                    self.restoreCursor(); // SCORC
                } else if (intermediates.len == 1) switch (intermediates[0]) {
                    '?' => if (params.len == 0) self.replyFmt("\x1b[?{d}u", .{self.keyboardFlags().bits()}),
                    '>' => if (plainParams(params) and params.len <= 1) {
                        self.activeKeyboardStack().push(if (params.len == 0) 0 else params.raw(0));
                    },
                    '<' => if (plainParams(params) and params.len <= 1) {
                        self.activeKeyboardStack().pop(if (params.len == 0) 1 else params.raw(0));
                    },
                    '=' => if (plainParams(params) and params.len <= 2) {
                        const mode: keyboard_mod.SetMode = switch (params.get(1, 1)) {
                            1 => .replace,
                            2 => .union_set,
                            3 => .subtract,
                            else => return,
                        };
                        self.activeKeyboardStack().set(mode, params.raw(0));
                    },
                    else => {},
                };
            },
            'p' => {
                if (trailing != null and trailing.? == '!') {
                    self.softReset(); // DECSTR
                } else if (!gt and trailing != null and trailing.? == '$' and params.len == 1) {
                    self.reportMode(private, params.raw(0)); // DECRQM
                }
            },
            'q' => {
                // XTVERSION. DEC's other q-family controls remain consumed.
                if (gt and params.len <= 1 and params.raw(0) == 0) {
                    self.reply(version.xtversion_reply);
                }
            },
            'y' => {
                // DECRQCRA: the conformance oracle's measuring instrument.
                if (trailing != null and trailing.? == '*') self.checksumRectangle(params);
            },
            't' => {
                // XTWINOPS report subset. Pixel metrics come from the host's
                // latest PTY resize; the pure VT never guesses font geometry.
                if (private or gt or trailing != null) return;
                switch (params.raw(0)) {
                    4 => {}, // resize-by-pixels: ignored
                    8 => self.push(.{ .resize_request = .{
                        .cols = @min(params.get(2, self.cols), 1000),
                        .rows = @min(params.get(1, self.rows), 1000),
                    } }),
                    11 => self.reply("\x1b[1t"),
                    13 => self.reply("\x1b[3;0;0t"),
                    14 => if (self.pixel_width > 0 and self.pixel_height > 0)
                        self.replyFmt("\x1b[4;{d};{d}t", .{ self.pixel_height, self.pixel_width }),
                    15 => self.reply("\x1b[5;768;1024t"),
                    16 => if (self.pixel_width >= self.cols and self.pixel_height >= self.rows)
                        self.replyFmt("\x1b[6;{d};{d}t", .{
                            self.pixel_height / self.rows,
                            self.pixel_width / self.cols,
                        }),
                    18 => self.replyFmt("\x1b[8;{d};{d}t", .{ self.rows, self.cols }),
                    19 => self.replyFmt("\x1b[9;{d};{d}t", .{ self.rows, self.cols }),
                    else => {}, // moves/iconify/title stack: never act
                }
            },
            else => {},
        }
    }

    pub fn oscDispatch(self: *Terminal, data: []const u8, terminator: parser_mod.OscTerminator) void {
        const semi = std.mem.indexOfScalar(u8, data, ';') orelse return;
        const code = std.fmt.parseInt(u16, data[0..semi], 10) catch return;
        const rest = data[semi + 1 ..];
        switch (code) {
            0, 1, 2 => {
                const title = self.alloc.dupe(u8, rest) catch return;
                self.push(.{ .set_title = title });
            },
            7 => {
                if (rest.len > max_cwd_uri_bytes) return;
                const uri = self.alloc.dupe(u8, rest) catch return;
                self.push(.{ .cwd_report = uri });
            },
            8 => self.oscHyperlink(rest),
            9 => {
                // OSC 9;4;... is iTerm2's progress protocol, not a user
                // notification. It gets its own surface when progress state
                // is designed; never misroute it as attention.
                if (!std.mem.startsWith(u8, rest, "4;")) self.notify("", rest);
            },
            10, 11, 12 => if (std.mem.eql(u8, rest, "?"))
                self.dynamicColorQuery(code, terminator),
            22 => {
                const shape = mouse_mod.PointerShape.parse(rest);
                self.pointer_shape = shape;
            },
            133 => self.semanticPrompt(rest),
            777 => {
                if (!std.mem.startsWith(u8, rest, "notify;")) return;
                const payload = rest["notify;".len..];
                const split = std.mem.indexOfScalar(u8, payload, ';') orelse return;
                self.notify(payload[0..split], payload[split + 1 ..]);
            },
            else => {}, // consumed
        }
    }

    pub fn dcsDispatch(self: *Terminal, final: u8, intermediates: []const u8, params: *const Params, data: []const u8) void {
        if (final != 'q' or params.len != 0) return;
        if (std.mem.eql(u8, intermediates, "$")) {
            const response = self.buildStatusStringReply(data) catch return;
            self.push(.{ .pty_write = response });
        } else if (std.mem.eql(u8, intermediates, "+")) {
            const response = self.buildTermcapReply(data) catch return;
            self.push(.{ .pty_write = response });
        }
    }

    pub fn apcDispatch(self: *Terminal, data: []const u8) void {
        if (self.graphics.consume(
            self.alloc,
            data,
            self.on_alt,
            self.screenRowId(0),
            self.screenRowId(self.row),
            self.col,
        )) |command| self.push(.{ .graphics = command });
    }

    fn buildTermcapReply(self: *Terminal, data: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.alloc);
        try out.appendSlice(self.alloc, "\x1bP1+r");

        var any = false;
        var names = std.mem.splitScalar(u8, data, ';');
        while (names.next()) |encoded_name| {
            var name_buf: [32]u8 = undefined;
            const name = decodeHex(encoded_name, &name_buf) orelse break;
            const value = termcap.lookup(name) orelse break;
            if (any) try out.append(self.alloc, ';');
            try appendHex(&out, self.alloc, name);
            try out.append(self.alloc, '=');
            try appendHex(&out, self.alloc, value);
            any = true;
        }

        if (!any) {
            out.deinit(self.alloc);
            return self.alloc.dupe(u8, "\x1bP0+r\x1b\\");
        }
        try out.appendSlice(self.alloc, "\x1b\\");
        return out.toOwnedSlice(self.alloc);
    }

    fn buildStatusStringReply(self: *Terminal, data: []const u8) ![]u8 {
        if (!std.mem.eql(u8, data, "m") and !std.mem.eql(u8, data, "r")) {
            return self.alloc.dupe(u8, "\x1bP0$r\x1b\\");
        }

        var buf: [max_decrqss_reply_bytes]u8 = undefined;
        var len: usize = 0;
        try appendFixed(&buf, &len, "\x1bP1$r");
        if (data[0] == 'm') {
            try self.appendSgrStatus(&buf, &len);
            try appendFixed(&buf, &len, "m");
        } else {
            try appendFixedFmt(&buf, &len, "{d};{d}r", .{ self.top + 1, self.bot + 1 });
        }
        try appendFixed(&buf, &len, "\x1b\\");
        return self.alloc.dupe(u8, buf[0..len]);
    }

    fn appendSgrStatus(self: *const Terminal, buf: []u8, len: *usize) !void {
        try appendFixed(buf, len, "0");
        if (self.attrs.flags.bold) try appendFixed(buf, len, ";1");
        if (self.attrs.flags.dim) try appendFixed(buf, len, ";2");
        if (self.attrs.flags.italic) try appendFixed(buf, len, ";3");
        if (self.attrs.flags.underline) try appendFixed(buf, len, ";4");
        if (self.attrs.flags.reverse) try appendFixed(buf, len, ";7");
        if (self.attrs.flags.hidden) try appendFixed(buf, len, ";8");
        if (self.attrs.flags.strike) try appendFixed(buf, len, ";9");
        try appendSgrColor(buf, len, self.attrs.fg, .foreground);
        try appendSgrColor(buf, len, self.attrs.bg, .background);
        try appendSgrColor(buf, len, self.attrs.underline_color, .underline);
    }

    fn decodeHex(encoded: []const u8, out: []u8) ?[]const u8 {
        if (encoded.len == 0 or encoded.len % 2 != 0 or encoded.len / 2 > out.len) return null;
        var i: usize = 0;
        while (i < encoded.len) : (i += 2) {
            const hi = hexNibble(encoded[i]) orelse return null;
            const lo = hexNibble(encoded[i + 1]) orelse return null;
            out[i / 2] = (hi << 4) | lo;
        }
        return out[0 .. encoded.len / 2];
    }

    fn hexNibble(byte: u8) ?u8 {
        return switch (byte) {
            '0'...'9' => byte - '0',
            'a'...'f' => byte - 'a' + 10,
            'A'...'F' => byte - 'A' + 10,
            else => null,
        };
    }

    fn appendHex(out: *std.ArrayList(u8), alloc: std.mem.Allocator, bytes: []const u8) !void {
        const digits = "0123456789ABCDEF";
        try out.ensureUnusedCapacity(alloc, bytes.len * 2);
        for (bytes) |byte| {
            out.appendAssumeCapacity(digits[byte >> 4]);
            out.appendAssumeCapacity(digits[byte & 0x0f]);
        }
    }

    fn dynamicColorQuery(self: *Terminal, code: u16, terminator: parser_mod.OscTerminator) void {
        const color = switch (code) {
            10 => colors.default_scheme.fg,
            11 => colors.default_scheme.bg,
            12 => colors.default_scheme.cursor,
            else => unreachable,
        };
        const end = if (terminator == .bel) "\x07" else "\x1b\\";
        const msg = std.fmt.allocPrint(
            self.alloc,
            "\x1b]{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}{s}",
            .{ code, color.r, color.r, color.g, color.g, color.b, color.b, end },
        ) catch return;
        self.push(.{ .pty_write = msg });
    }

    /// OSC 133;A/B/C/D — semantic prompt marks (RFC 0006).
    fn semanticPrompt(self: *Terminal, data: []const u8) void {
        if (data.len == 0) return;
        switch (data[0]) {
            'A' => { // prompt start
                self.shell_status = .prompt;
                if (!self.on_alt) {
                    const top = self.primary.len - self.primary.screen_rows;
                    self.prompt_mark = self.primary.base_id + top + self.row;
                }
                self.push(.{ .prompt_mark = .prompt_start });
            },
            'B' => self.push(.{ .prompt_mark = .command_start }),
            'C' => { // command output begins: content, never droppable
                self.shell_status = .executing;
                self.prompt_mark = null;
                self.push(.{ .prompt_mark = .command_executed });
            },
            'D' => {
                self.last_exit = if (data.len >= 3 and data[1] == ';')
                    std.fmt.parseInt(u16, data[2..], 10) catch null
                else
                    null;
                self.push(.{ .prompt_mark = .{ .command_finished = self.last_exit } });
            },
            else => {},
        }
    }

    // -- cursor and grid mechanics ------------------------------------------

    /// Overwriting half of a wide pair must not leave the orphan half
    /// rendering a stale glyph.
    fn clearWideAt(self: *Terminal, r: u16, c: u16) void {
        const cells = self.rowCells(r);
        const cell = cells[c];
        if (cell.flags.wide and c + 1 < self.cols) {
            cells[c + 1] = self.blankCell();
        } else if (cell.flags.wide_spacer and c > 0) {
            cells[c - 1] = self.blankCell();
        }
    }

    fn blankCell(self: *const Terminal) Cell {
        // BCE: erased cells take the current background, nothing else.
        return .{ .bg = self.attrs.bg };
    }

    fn index(self: *Terminal) void {
        if (self.row == self.bot) {
            self.scrollUp(1, true);
        } else if (self.row < self.rows - 1) {
            self.row += 1;
        }
    }

    fn reverseIndex(self: *Terminal) void {
        if (self.row == self.top) {
            self.scrollDown(1);
        } else if (self.row > 0) {
            self.row -= 1;
        }
    }

    /// Any upward scroll of a full-width primary region anchored at row
    /// zero feeds history. A partial bottom margin leaves the rows below
    /// it visually fixed (RFC 0003 amendment, 2026-08-16). Indexing keeps
    /// a possible autowrap continuation into the new blank row; editing
    /// operations break that boundary.
    fn scrollUp(self: *Terminal, n_in: u16, preserve_wrap: bool) void {
        const region_rows = self.bot - self.top + 1;
        const n = @min(n_in, region_rows);
        if (self.on_alt) self.graphics.scrollAlt(self.top, self.bot, n, true);
        if (!self.on_alt and self.top == 0) {
            var i: u16 = 0;
            while (i < n) : (i += 1) {
                const live_top_id = self.primary.base_id + self.primary.len - self.primary.screen_rows;
                const fixed_first_id = live_top_id + self.bot + 1;
                const old_bottom_id = live_top_id + self.rows - 1;
                if (!self.primary.scrollTopRegionUpOne(self.bot, self.blankCell())) return;
                if (!preserve_wrap and self.bot > 0) self.primary.screenRow(self.bot - 1).wrapped = false;
                self.remapFixedPrimaryPins(fixed_first_id, old_bottom_id);
                self.graphics.prunePrimary(self.primary.base_id);
            }
            return;
        }
        var r = self.top;
        while (r + n <= self.bot) : (r += 1) {
            self.copyRowInto(r + n, r);
        }
        var rr = self.bot + 1 - n;
        while (rr <= self.bot) : (rr += 1) self.clearRow(rr);
    }

    fn remapFixedPrimaryPins(self: *Terminal, first: u64, last: u64) void {
        if (first > last) return;
        if (self.prompt_mark) |*mark| {
            if (mark.* >= first and mark.* <= last) mark.* += 1;
        }
        if (self.selection) |*sel| {
            if (sel.on_alt) return;
            if (sel.anchor.id >= first and sel.anchor.id <= last) sel.anchor.id += 1;
            if (sel.head.id >= first and sel.head.id <= last) sel.head.id += 1;
        }
    }

    fn scrollDown(self: *Terminal, n_in: u16) void {
        const region_rows = self.bot - self.top + 1;
        const n = @min(n_in, region_rows);
        if (self.on_alt) self.graphics.scrollAlt(self.top, self.bot, n, false);
        var r = self.bot;
        while (r >= self.top + n) : (r -= 1) {
            self.copyRowInto(r - n, r);
            if (r == 0) break;
        }
        var rr = self.top;
        while (rr < self.top + n) : (rr += 1) self.clearRow(rr);
    }

    fn cursorUp(self: *Terminal, n: u16) void {
        const bound: u16 = if (self.row >= self.top) self.top else 0;
        self.row = if (self.row > bound + n - 1) self.row - n else bound;
        self.pending_wrap = false;
    }

    fn cursorDown(self: *Terminal, n: u16) void {
        const bound: u16 = if (self.row <= self.bot) self.bot else self.rows - 1;
        self.row = @intCast(@min(@as(u32, self.row) + n, bound));
        self.pending_wrap = false;
    }

    fn cursorRight(self: *Terminal, n: u16) void {
        self.col = @intCast(@min(@as(u32, self.col) + n, self.cols - 1));
        self.pending_wrap = false;
    }

    fn cursorLeft(self: *Terminal, n: u16) void {
        self.col = if (self.col > n) self.col - n else 0;
        self.pending_wrap = false;
    }

    fn clampRowOrigin(self: *const Terminal, r: u32) u16 {
        if (self.modes.origin) {
            return @intCast(@min(@as(u32, self.top) + r, self.bot));
        }
        return @intCast(@min(r, self.rows - 1));
    }

    fn setPos(self: *Terminal, r: u32, c: u32) void {
        self.row = self.clampRowOrigin(r);
        self.col = @intCast(@min(c, self.cols - 1));
        self.pending_wrap = false;
    }

    fn horizontalTab(self: *Terminal) void {
        var c = self.col + 1;
        while (c < self.cols) : (c += 1) {
            if (self.tabs[c]) break;
        }
        self.col = @min(c, self.cols - 1);
        self.pending_wrap = false;
    }

    fn backTab(self: *Terminal) void {
        var c: u16 = self.col;
        while (c > 0) {
            c -= 1;
            if (self.tabs[c]) break;
        }
        self.col = c;
        self.pending_wrap = false;
    }

    fn eraseDisplay(self: *Terminal, mode: u16) void {
        switch (mode) {
            0 => {
                self.eraseLine(0);
                var r = self.row + 1;
                while (r < self.rows) : (r += 1) self.clearRow(r);
            },
            1 => {
                var r: u16 = 0;
                while (r < self.row) : (r += 1) self.clearRow(r);
                self.eraseLine(1);
            },
            2 => {
                var r: u16 = 0;
                while (r < self.rows) : (r += 1) self.clearRow(r);
                self.graphics.clearScreen(self.on_alt);
            },
            // ED 3 erases *saved lines* — scrollback only, screen intact
            // (xterm semantics; esctest test_ED_3 is the oracle here).
            3 => if (!self.on_alt) self.primary.clearScrollback(),
            else => {},
        }
    }

    fn eraseLine(self: *Terminal, mode: u16) void {
        const cells = self.rowCells(self.row);
        switch (mode) {
            0 => {
                @memset(cells[self.col..self.cols], self.blankCell());
                // Erased through the end: continuation broken (rule 1);
                // a full clear also frees the row above's claim (rule 2).
                self.setWrapped(self.row, false);
                if (self.col == 0 and self.row > 0) self.setWrapped(self.row - 1, false);
            },
            1 => @memset(cells[0 .. self.col + 1], self.blankCell()),
            2 => {
                @memset(cells, self.blankCell());
                self.setWrapped(self.row, false);
                if (self.row > 0) self.setWrapped(self.row - 1, false);
            },
            else => {},
        }
    }

    fn insertLines(self: *Terminal, n: u16) void {
        if (self.row < self.top or self.row > self.bot) return;
        const saved_top = self.top;
        self.top = self.row;
        self.scrollDown(n);
        self.top = saved_top;
        self.col = 0;
        self.pending_wrap = false;
    }

    fn deleteLines(self: *Terminal, n: u16) void {
        if (self.row < self.top or self.row > self.bot) return;
        const saved_top = self.top;
        self.top = self.row;
        self.scrollUp(n, false);
        self.top = saved_top;
        self.col = 0;
        self.pending_wrap = false;
    }

    fn insertChars(self: *Terminal, n_in: u16) void {
        const line = self.rowCells(self.row);
        const n = @min(n_in, self.cols - self.col);
        var c: usize = self.cols - 1;
        while (c >= self.col + n) : (c -= 1) {
            line[c] = line[c - n];
            if (c == 0) break;
        }
        @memset(line[self.col .. self.col + n], self.blankCell());
        self.setWrapped(self.row, false); // tail shifted (rule 1)
        self.pending_wrap = false;
    }

    fn deleteChars(self: *Terminal, n_in: u16) void {
        const line = self.rowCells(self.row);
        const n = @min(n_in, self.cols - self.col);
        var c: usize = self.col;
        while (c + n < self.cols) : (c += 1) {
            line[c] = line[c + n];
        }
        @memset(line[self.cols - n .. self.cols], self.blankCell());
        self.setWrapped(self.row, false); // tail shifted (rule 1)
        self.pending_wrap = false;
    }

    fn eraseChars(self: *Terminal, n_in: u16) void {
        const line = self.rowCells(self.row);
        const n = @min(n_in, self.cols - self.col);
        @memset(line[self.col .. self.col + n], self.blankCell());
        if (self.col + n >= self.cols) self.setWrapped(self.row, false); // rule 1
        self.pending_wrap = false;
    }

    fn saveCursor(self: *Terminal) void {
        const saved: SavedCursor = .{
            .col = self.col,
            .row = self.row,
            .attrs = self.attrs,
            .origin = self.modes.origin,
            .pending_wrap = self.pending_wrap,
            .charsets = self.charsets,
            .active_charset = self.active_charset,
            .hyperlink_id = self.active_hyperlink_id,
        };
        if (self.on_alt) self.saved_alt = saved else self.saved_primary = saved;
    }

    fn restoreCursor(self: *Terminal) void {
        const slot = if (self.on_alt) self.saved_alt else self.saved_primary;
        if (slot) |s| {
            self.col = @min(s.col, self.cols - 1);
            self.row = @min(s.row, self.rows - 1);
            self.attrs = s.attrs;
            self.modes.origin = s.origin;
            self.pending_wrap = s.pending_wrap;
            self.charsets = s.charsets;
            self.active_charset = s.active_charset;
            self.active_hyperlink_id = s.hyperlink_id;
        } else {
            self.setPos(0, 0);
            self.attrs = .{};
            self.active_hyperlink_id = 0;
        }
    }

    fn decAlign(self: *Terminal) void {
        var r: u16 = 0;
        while (r < self.rows) : (r += 1) {
            @memset(self.rowCells(r), .{ .cp = 'E', .flags = .{ .content = true } });
            self.setWrapped(r, false);
        }
        self.top = 0;
        self.bot = self.rows - 1;
        self.setPos(0, 0);
    }

    fn softReset(self: *Terminal) void {
        self.attrs = .{};
        self.active_hyperlink_id = 0;
        self.modes.origin = false;
        self.modes.cursor_visible = true;
        // TODO(lookup): DEC STD 070 resets DECAWM off in DECSTR; modern
        // expectations differ. Verify via the lookup ritual.
        self.modes.autowrap = true;
        self.top = 0;
        self.bot = self.rows - 1;
        self.pending_wrap = false;
        self.charsets = .{ .ascii, .ascii };
        self.active_charset = 0;
    }

    fn fullReset(self: *Terminal) void {
        self.primary.clearScrollback();
        var r: u16 = 0;
        while (r < self.primary.screen_rows) : (r += 1) {
            const row = self.primary.screenRow(r);
            @memset(row.cells, Cell{});
            row.wrapped = false;
        }
        self.alt.clearAll(.{});
        self.graphemes.clearRetainingCapacity();
        self.grapheme_gc_at = 4096;
        self.on_alt = false;
        self.col = 0;
        self.row = 0;
        self.pending_wrap = false;
        self.attrs = .{};
        self.clearHyperlinks();
        self.active_hyperlink_id = 0;
        self.top = 0;
        self.bot = self.rows - 1;
        self.modes = .{};
        self.pointer_shape = .text;
        self.keyboard_primary.reset();
        self.keyboard_alt.reset();
        self.graphics.reset(self.alloc);
        defaultTabs(self.tabs);
        self.charsets = .{ .ascii, .ascii };
        self.active_charset = 0;
        self.saved_primary = null;
        self.saved_alt = null;
        self.last_printed = null;
        self.shell_status = .unknown;
        self.last_exit = null;
        self.prompt_mark = null;
        self.selection = null;
    }

    // -- modes ---------------------------------------------------------------

    fn activeKeyboardStack(self: *Terminal) *keyboard_mod.FlagStack {
        return if (self.on_alt) &self.keyboard_alt else &self.keyboard_primary;
    }

    fn setModes(self: *Terminal, private: bool, params: *const Params, set: bool) void {
        var i: usize = 0;
        while (i < params.len) : (i += 1) {
            self.setMode(private, params.raw(i), set);
        }
    }

    fn setMode(self: *Terminal, private: bool, mode: u16, set: bool) void {
        if (!private) return; // IRM/LNM etc. consumed
        switch (mode) {
            1 => self.modes.cursor_keys = set,
            6 => {
                self.modes.origin = set;
                self.setPos(0, 0);
            },
            7 => {
                self.modes.autowrap = set;
                if (!set) self.pending_wrap = false;
            },
            25 => self.modes.cursor_visible = set,
            47 => self.switchScreen(set, false, false),
            1047 => self.switchScreen(set, set, false),
            1048 => if (set) self.saveCursor() else self.restoreCursor(),
            1049 => self.switchScreen(set, set, true),
            1004 => self.modes.focus_reporting = set,
            1000, 1002, 1003 => {
                const tracking: mouse_mod.Tracking = switch (mode) {
                    1000 => .normal,
                    1002 => .button,
                    1003 => .any,
                    else => unreachable,
                };
                if (set) {
                    self.modes.mouse_tracking = tracking;
                } else if (self.modes.mouse_tracking == tracking) {
                    self.modes.mouse_tracking = .none;
                }
            },
            1006 => if (set) {
                self.modes.mouse_encoding = .sgr;
            } else if (self.modes.mouse_encoding == .sgr) {
                self.modes.mouse_encoding = .legacy;
            },
            1016 => if (set) {
                self.modes.mouse_encoding = .sgr_pixels;
            } else if (self.modes.mouse_encoding == .sgr_pixels) {
                self.modes.mouse_encoding = .legacy;
            },
            2004 => self.modes.bracketed_paste = set,
            2026 => {
                self.modes.synchronized_output = set;
                if (set) self.sync_output_epoch +%= 1;
            },
            2027 => self.modes.grapheme_cluster = set,
            else => {}, // consumed and ignored, never printed
        }
    }

    fn switchScreen(self: *Terminal, to_alt: bool, clear_alt: bool, cursor_dance: bool) void {
        self.selection = null; // RFC 0010: screen switch clears
        if (to_alt) {
            if (cursor_dance) self.saveCursorPrimary();
            if (!self.on_alt) self.on_alt = true;
            if (clear_alt) {
                self.alt.clearAll(self.blankCell());
                self.graphics.clearScreen(true);
            }
            self.primary.viewportToBottom();
            self.pending_wrap = false;
        } else {
            if (!self.on_alt) return;
            self.on_alt = false;
            if (cursor_dance) self.restoreCursorPrimary();
            self.pending_wrap = false;
        }
    }

    fn saveCursorPrimary(self: *Terminal) void {
        const was_alt = self.on_alt;
        self.on_alt = false;
        self.saveCursor();
        self.on_alt = was_alt;
    }

    fn restoreCursorPrimary(self: *Terminal) void {
        std.debug.assert(!self.on_alt);
        self.restoreCursor();
    }

    // -- SGR -----------------------------------------------------------------

    fn sgr(self: *Terminal, params: *const Params) void {
        if (params.len == 0) {
            self.attrs = .{};
            return;
        }
        var i: usize = 0;
        while (i < params.len) {
            const p = params.raw(i);
            // A colon-linked run belongs to the parameter that opens it.
            const run_end = colonRunEnd(params, i);
            switch (p) {
                0 => self.attrs = .{},
                1 => self.attrs.flags.bold = true,
                2 => self.attrs.flags.dim = true,
                3 => self.attrs.flags.italic = true,
                4 => {
                    // 4:0 turns underline off; any other 4[:x] turns it on.
                    if (run_end > i + 1 and params.raw(i + 1) == 0) {
                        self.attrs.flags.underline = false;
                    } else {
                        self.attrs.flags.underline = true;
                    }
                },
                5, 6 => {}, // blink: consumed
                7 => self.attrs.flags.reverse = true,
                8 => self.attrs.flags.hidden = true,
                9 => self.attrs.flags.strike = true,
                21 => self.attrs.flags.underline = true, // double -> single
                22 => {
                    self.attrs.flags.bold = false;
                    self.attrs.flags.dim = false;
                },
                23 => self.attrs.flags.italic = false,
                24 => self.attrs.flags.underline = false,
                25 => {},
                27 => self.attrs.flags.reverse = false,
                28 => self.attrs.flags.hidden = false,
                29 => self.attrs.flags.strike = false,
                30...37 => self.attrs.fg = .{ .indexed = @intCast(p - 30) },
                38 => {
                    if (extendedColor(params, i, run_end)) |ext| {
                        self.attrs.fg = ext.c;
                        i = ext.next;
                        continue;
                    }
                },
                39 => self.attrs.fg = .default,
                40...47 => self.attrs.bg = .{ .indexed = @intCast(p - 40) },
                48 => {
                    if (extendedColor(params, i, run_end)) |ext| {
                        self.attrs.bg = ext.c;
                        i = ext.next;
                        continue;
                    }
                },
                49 => self.attrs.bg = .default,
                58 => {
                    if (extendedColor(params, i, run_end)) |ext| {
                        self.attrs.underline_color = ext.c;
                        i = ext.next;
                        continue;
                    }
                },
                59 => self.attrs.underline_color = .default,
                90...97 => self.attrs.fg = .{ .indexed = @intCast(p - 90 + 8) },
                100...107 => self.attrs.bg = .{ .indexed = @intCast(p - 100 + 8) },
                else => {},
            }
            i = run_end;
        }
    }

    const ExtColor = struct { c: Color, next: usize };

    /// Parse SGR 38/48/58 extended color in both forms:
    ///   `38;5;n`  `38;2;r;g;b`  (semicolon)
    ///   `38:5:n`  `38:2:r:g:b`  `38:2:cs:r:g:b`  (colon, optional space id)
    fn extendedColor(params: *const Params, i: usize, run_end: usize) ?ExtColor {
        const colon_form = run_end > i + 1;
        if (colon_form) {
            const n = run_end - i; // includes the leading 38/48
            if (n < 2) return null;
            switch (params.raw(i + 1)) {
                5 => {
                    if (n < 3) return null;
                    return .{ .c = .{ .indexed = @intCast(@min(params.raw(i + 2), 255)) }, .next = run_end };
                },
                2 => {
                    // 5 params: 38:2:r:g:b — 6+: 38:2:cs:r:g:b.
                    const base: usize = if (n >= 6) i + 3 else i + 2;
                    if (base + 2 >= run_end) return null;
                    return .{ .c = .{ .rgb = .{
                        .r = @intCast(@min(params.raw(base), 255)),
                        .g = @intCast(@min(params.raw(base + 1), 255)),
                        .b = @intCast(@min(params.raw(base + 2), 255)),
                    } }, .next = run_end };
                },
                else => return null,
            }
        }
        // Semicolon form consumes following top-level params.
        if (i + 1 >= params.len) return null;
        switch (params.raw(i + 1)) {
            5 => {
                if (i + 2 >= params.len) return null;
                return .{ .c = .{ .indexed = @intCast(@min(params.raw(i + 2), 255)) }, .next = i + 3 };
            },
            2 => {
                if (i + 4 >= params.len) return null;
                return .{ .c = .{ .rgb = .{
                    .r = @intCast(@min(params.raw(i + 2), 255)),
                    .g = @intCast(@min(params.raw(i + 3), 255)),
                    .b = @intCast(@min(params.raw(i + 4), 255)),
                } }, .next = i + 5 };
            },
            else => return null,
        }
    }

    fn colonRunEnd(params: *const Params, i: usize) usize {
        var j = i + 1;
        while (j < params.len and params.colon[j]) : (j += 1) {}
        return j;
    }

    fn plainParams(params: *const Params) bool {
        for (params.colon[0..params.len]) |is_subparam| {
            if (is_subparam) return false;
        }
        return true;
    }

    // -- replies -------------------------------------------------------------

    /// Reply `DCS Pid ! ~ XXXX ST`. Checksum algorithm follows modern
    /// xterm (patch 334+, what esctest --xterm-checksum=334 expects):
    /// positive 16-bit sum of codepoints (blanks count as 0x20) plus
    /// attribute weights 0x80 bold / 0x10 underline / 0x20 reverse.
    fn checksumRectangle(self: *Terminal, params: *const Params) void {
        const id = params.raw(0);
        // params[1] is the page number; single-page terminal, ignored.
        var t = @min(params.get(2, 1), self.rows) - 1;
        const l = @min(params.get(3, 1), self.cols) - 1;
        var b = @min(params.get(4, self.rows), self.rows) - 1;
        const r = @min(params.get(5, self.cols), self.cols) - 1;
        if (self.modes.origin) {
            t = @min(t + self.top, self.bot);
            b = @min(b + self.top, self.bot);
        }

        var sum: u32 = 0;
        if (t <= b and l <= r) {
            var row = t;
            while (row <= b) : (row += 1) {
                var col = l;
                while (col <= r) : (col += 1) {
                    const cell = self.cellAt(row, col);
                    sum +%= cell.cp;
                    if (cell.flags.bold) sum +%= 0x80;
                    if (cell.flags.underline) sum +%= 0x10;
                    if (cell.flags.reverse) sum +%= 0x20;
                }
            }
        }
        const checksum: u16 = @truncate(sum);
        self.replyFmt("\x1bP{d}!~{X:0>4}\x1b\\", .{ id, checksum });
    }

    fn cursorPositionReport(self: *Terminal) void {
        const r = if (self.modes.origin) self.row - self.top + 1 else self.row + 1;
        const c = self.col + 1;
        self.replyFmt("\x1b[{d};{d}R", .{ r, c });
    }

    /// DECRPM for authoritative stored modes. Deliberately fixed modes report
    /// permanent state; one-shot and unknown modes report not recognized (0).
    fn reportMode(self: *Terminal, private: bool, mode: u16) void {
        const state: u8 = if (!private) 0 else switch (mode) {
            1 => modeState(self.modes.cursor_keys),
            3, 1005, 1015 => 4,
            6 => modeState(self.modes.origin),
            7 => modeState(self.modes.autowrap),
            25 => modeState(self.modes.cursor_visible),
            47, 1047, 1049 => modeState(self.on_alt),
            1004 => modeState(self.modes.focus_reporting),
            1000 => modeState(self.modes.mouse_tracking == .normal),
            1002 => modeState(self.modes.mouse_tracking == .button),
            1003 => modeState(self.modes.mouse_tracking == .any),
            1006 => modeState(self.modes.mouse_encoding == .sgr),
            1016 => modeState(self.modes.mouse_encoding == .sgr_pixels),
            2004 => modeState(self.modes.bracketed_paste),
            2026 => modeState(self.modes.synchronized_output),
            2027 => modeState(self.modes.grapheme_cluster),
            else => 0,
        };
        if (private) {
            self.replyFmt("\x1b[?{d};{d}$y", .{ mode, state });
        } else {
            self.replyFmt("\x1b[{d};{d}$y", .{ mode, state });
        }
    }

    fn modeState(active: bool) u8 {
        return if (active) 1 else 2;
    }

    fn replyFmt(self: *Terminal, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        self.push(.{ .pty_write = msg });
    }

    fn reply(self: *Terminal, bytes: []const u8) void {
        const copy = self.alloc.dupe(u8, bytes) catch return;
        self.push(.{ .pty_write = copy });
    }

    fn notify(self: *Terminal, title: []const u8, body: []const u8) void {
        const title_copy = self.alloc.dupe(u8, title) catch return;
        const body_copy = self.alloc.dupe(u8, body) catch {
            self.alloc.free(title_copy);
            return;
        };
        self.push(.{ .notify = .{ .title = title_copy, .body = body_copy } });
    }

    fn push(self: *Terminal, action: Action) void {
        self.actions.append(self.alloc, action) catch {
            switch (action) {
                .set_title => |t| self.alloc.free(t),
                .cwd_report => |uri| self.alloc.free(uri),
                .notify => |notification| {
                    self.alloc.free(notification.title);
                    self.alloc.free(notification.body);
                },
                .pty_write => |w| self.alloc.free(w),
                .graphics => |command| command.deinit(self.alloc),
                .bell, .prompt_mark, .resize_request => {},
            }
        };
    }
};

const SgrColorSlot = enum {
    foreground,
    background,
    underline,
};

fn appendSgrColor(buf: []u8, len: *usize, color: Color, slot: SgrColorSlot) !void {
    const extended_code: u8 = switch (slot) {
        .foreground => 38,
        .background => 48,
        .underline => 58,
    };
    switch (color) {
        .default => {},
        .indexed => |index| switch (slot) {
            .foreground => if (index < 8)
                try appendFixedFmt(buf, len, ";3{d}", .{index})
            else if (index < 16)
                try appendFixedFmt(buf, len, ";9{d}", .{index - 8})
            else
                try appendFixedFmt(buf, len, ";{d}:5:{d}", .{ extended_code, index }),
            .background => if (index < 8)
                try appendFixedFmt(buf, len, ";4{d}", .{index})
            else if (index < 16)
                try appendFixedFmt(buf, len, ";10{d}", .{index - 8})
            else
                try appendFixedFmt(buf, len, ";{d}:5:{d}", .{ extended_code, index }),
            .underline => try appendFixedFmt(buf, len, ";{d}:5:{d}", .{ extended_code, index }),
        },
        .rgb => |rgb| try appendFixedFmt(buf, len, ";{d}:2::{d}:{d}:{d}", .{
            extended_code,
            rgb.r,
            rgb.g,
            rgb.b,
        }),
    }
}

fn appendFixed(buf: []u8, len: *usize, bytes: []const u8) !void {
    if (len.* > buf.len or bytes.len > buf.len - len.*) return error.NoSpaceLeft;
    @memcpy(buf[len.*..][0..bytes.len], bytes);
    len.* += bytes.len;
}

fn appendFixedFmt(buf: []u8, len: *usize, comptime format: []const u8, args: anytype) !void {
    if (len.* > buf.len) return error.NoSpaceLeft;
    const written = try std.fmt.bufPrint(buf[len.*..], format, args);
    len.* += written.len;
}

fn defaultTabs(tabs: []bool) void {
    for (tabs, 0..) |*t, i| t.* = i % 8 == 0 and i != 0;
}

fn designate(final: u8) Charset {
    return switch (final) {
        '0' => .dec_special,
        else => .ascii, // 'B' and everything else we don't translate
    };
}

/// DEC Special Graphics (`ESC ( 0`): 0x5F..0x7E onto Unicode line drawing.
fn decSpecial(cp: u21) u21 {
    if (cp < 0x5F or cp > 0x7E) return cp;
    const table = [_]u21{
        0x00A0, 0x25C6, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0x00B0, // _ ` a b c d e f
        0x00B1, 0x2424, 0x240B, 0x2518, 0x2510, 0x250C, 0x2514, 0x253C, // g h i j k l m n
        0x23BA, 0x23BB, 0x2500, 0x23BC, 0x23BD, 0x251C, 0x2524, 0x2534, // o p q r s t u v
        0x252C, 0x2502, 0x2264, 0x2265, 0x03C0, 0x2260, 0x00A3, 0x00B7, // w x y z { | } ~
    };
    return table[cp - 0x5F];
}

/// Unicode 16.0.0 codepoint width from zg 0.16.2. Terminal storage is limited
/// to one or two cells; zg's unusual three-cell punctuation is clamped to two.
/// Grapheme-level VS/ZWJ/flag adjustments belong to the cluster path that
/// follows this codepoint-table replacement (unicode-width.md).
pub fn charWidth(cp: u21) u2 {
    // UAX #51 flags are pairs. A lone regional indicator is one column;
    // mode 2027's pair is widened by graphemeWidth once the second arrives.
    if (Graphemes.gbp(cp) == .Regional_Indicator) return 1;
    const width = DisplayWidth.codePointWidth(cp);
    if (width <= 0) return 0;
    return if (width == 1) 1 else 2;
}
