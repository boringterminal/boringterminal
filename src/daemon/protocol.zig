//! Private GUI ↔ boringterminald protocol (RFC 0012). The codec is explicit:
//! no native struct layout crosses the process boundary.

const std = @import("std");
const vt = @import("../vt.zig");
const graphics_limits = @import("../graphics_limits.zig");
const display_registry = @import("display_registry.zig");
const c = std.c;

pub const version: u16 = 18;
pub const max_payload: usize = 128 * 1024 * 1024;
pub const max_working_directory_bytes: usize = 1024;
const magic = "BTD1";
const header_len = 12;

pub const Tag = enum(u16) {
    list = 1,
    create = 2,
    snapshot = 3,
    write = 4,
    resize = 5,
    focus = 6,
    close = 7,
    foreground = 8,
    clear_scrollback = 9,
    force_sync = 10,
    scroll = 11,
    selection_start = 12,
    selection_drag = 13,
    selection_clear = 14,
    selection_text = 15,
    subscribe = 16,
    mouse = 17,
    key = 18,
    paste = 19,
    image = 20,
    pair = 21,
    separate = 22,
    display_focus = 23,
    display_ratio = 24,
    display_move = 25,
    display_swap = 26,
    display_transfer = 27,
    display_extract = 28,
    graphics_attach = 29,
    stage_image = 30,
    release_staged_image = 31,
    search = 32,
    create_beside = 33,
    display_zoom = 34,

    ok = 64,
    protocol_error = 65,
    session_list = 66,
    metadata = 67,
    snapshot_result = 68,
    bool_result = 69,
    bytes_result = 70,
    image_result = 71,
    graphics_ready = 72,
    staged_image = 73,
    graphics_busy = 74,
    search_result = 75,

    event = 100,
};

pub const EventFlags = packed struct(u8) {
    grid: bool = false,
    metadata: bool = false,
    bell: bool = false,
    lifecycle: bool = false,
    registry: bool = false,
    _pad: u3 = 0,
};

pub const DisplayItem = display_registry.Item;
pub const Pair = display_registry.Pair;
pub const FocusedMember = display_registry.FocusedMember;

pub const RegistrySnapshot = struct {
    sessions: []Metadata,
    display_items: []DisplayItem,

    pub fn deinit(self: *RegistrySnapshot, alloc: std.mem.Allocator) void {
        for (self.sessions) |*metadata| metadata.deinit(alloc);
        alloc.free(self.sessions);
        alloc.free(self.display_items);
        self.* = undefined;
    }
};

pub const Metadata = struct {
    id: u64,
    title: []u8,
    exited: bool,
    working: bool,
    attention: bool,
    cwd: ?[]u8 = null,

    pub fn deinit(self: *Metadata, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        if (self.cwd) |cwd| alloc.free(cwd);
        self.* = undefined;
    }
};

pub const CreateRequest = struct {
    cols: u16,
    rows: u16,
    cwd: ?[]const u8,
};

pub const CreateBesideRequest = struct {
    existing_id: u64,
    create: CreateRequest,
};

pub const SearchOperation = enum(u8) {
    initial,
    refresh,
    next,
    previous,
};

pub const SearchRequest = struct {
    id: u64,
    operation: SearchOperation,
    query: []const u8,
    current: ?vt.search.Match,
};

pub fn encodeSearchRequest(enc: *Encoder, request: SearchRequest) !void {
    try vt.search.validateQuery(request.query);
    try enc.int(u64, request.id);
    try enc.byte(@intFromEnum(request.operation));
    try enc.bytes(request.query);
    try enc.boolean(request.current != null);
    if (request.current) |current| try encodeSearchMatch(enc, current);
}

pub fn decodeSearchRequest(dec: *Decoder) !SearchRequest {
    const id = try dec.int(u64);
    if (id == 0) return error.InvalidSearchRequest;
    const operation = std.enums.fromInt(SearchOperation, try dec.byte()) orelse
        return error.InvalidSearchRequest;
    const query_len = try dec.int(u32);
    if (query_len == 0 or query_len > vt.search.max_query_bytes)
        return error.InvalidSearchRequest;
    const query = try dec.slice(query_len);
    vt.search.validateQuery(query) catch return error.InvalidSearchRequest;
    const current = if (try dec.boolean()) try decodeSearchMatch(dec) else null;
    try dec.finish();
    return .{ .id = id, .operation = operation, .query = query, .current = current };
}

fn encodeSearchPoint(enc: *Encoder, point: vt.search.Point) !void {
    try enc.int(u64, point.row_id);
    try enc.int(u16, point.col);
}

fn decodeSearchPoint(dec: *Decoder) !vt.search.Point {
    return .{ .row_id = try dec.int(u64), .col = try dec.int(u16) };
}

fn encodeSearchMatch(enc: *Encoder, match: vt.search.Match) !void {
    try encodeSearchPoint(enc, match.start);
    try encodeSearchPoint(enc, match.end);
}

fn decodeSearchMatch(dec: *Decoder) !vt.search.Match {
    const match: vt.search.Match = .{
        .start = try decodeSearchPoint(dec),
        .end = try decodeSearchPoint(dec),
    };
    if (match.end.row_id < match.start.row_id or
        (match.end.row_id == match.start.row_id and match.end.col < match.start.col))
        return error.InvalidSearchResult;
    return match;
}

pub const SearchResult = struct {
    cols: u16,
    rows: u16,
    grid_epoch: u64,
    total: u32,
    truncated: bool,
    selected_index: ?u32,
    selected: ?vt.search.Match,
    matches: []bool,
    selected_cells: []bool,

    pub fn deinit(self: *SearchResult, alloc: std.mem.Allocator) void {
        alloc.free(self.matches);
        alloc.free(self.selected_cells);
        self.* = undefined;
    }

    pub fn encode(self: *const SearchResult, enc: *Encoder) !void {
        const expected = @as(usize, self.cols) * self.rows;
        if (self.cols < 2 or self.rows < 1 or self.matches.len != expected or
            self.selected_cells.len != expected or
            (self.selected == null) != (self.selected_index == null))
            return error.InvalidSearchResult;
        if (self.selected_index) |index| if (index >= self.total) return error.InvalidSearchResult;
        try enc.int(u16, self.cols);
        try enc.int(u16, self.rows);
        try enc.int(u64, self.grid_epoch);
        try enc.int(u32, self.total);
        try enc.boolean(self.truncated);
        try enc.boolean(self.selected != null);
        if (self.selected) |selected| {
            try enc.int(u32, self.selected_index.?);
            try encodeSearchMatch(enc, selected);
        }
        for (self.matches, self.selected_cells) |is_match, is_selected| {
            try enc.boolean(is_match);
            try enc.boolean(is_selected);
        }
    }

    pub fn decode(dec: *Decoder, alloc: std.mem.Allocator) !SearchResult {
        const cols = try dec.int(u16);
        const rows = try dec.int(u16);
        if (cols < 2 or rows < 1) return error.InvalidSearchResult;
        const expected = std.math.mul(usize, cols, rows) catch return error.InvalidSearchResult;
        if (expected > max_payload / 2) return error.InvalidSearchResult;
        const grid_epoch = try dec.int(u64);
        const total = try dec.int(u32);
        const truncated = try dec.boolean();
        const has_selected = try dec.boolean();
        const selected_index = if (has_selected) try dec.int(u32) else null;
        const selected = if (has_selected) try decodeSearchMatch(dec) else null;
        if (selected_index) |index| if (index >= total) return error.InvalidSearchResult;
        const matches = try alloc.alloc(bool, expected);
        errdefer alloc.free(matches);
        const selected_cells = try alloc.alloc(bool, expected);
        errdefer alloc.free(selected_cells);
        for (matches, selected_cells) |*is_match, *is_selected| {
            is_match.* = try dec.boolean();
            is_selected.* = try dec.boolean();
            if (is_selected.* and !is_match.*) return error.InvalidSearchResult;
        }
        return .{
            .cols = cols,
            .rows = rows,
            .grid_epoch = grid_epoch,
            .total = total,
            .truncated = truncated,
            .selected_index = selected_index,
            .selected = selected,
            .matches = matches,
            .selected_cells = selected_cells,
        };
    }
};

pub fn encodeMouseEvent(enc: *Encoder, event: vt.mouse.Event) !void {
    try enc.byte(@intFromEnum(event.kind));
    try enc.byte(@intFromEnum(event.button));
    const modifiers: u3 = @bitCast(event.modifiers);
    try enc.byte(@intCast(modifiers));
    try enc.int(u16, event.col);
    try enc.int(u16, event.row);
    try enc.int(u32, event.pixel_x);
    try enc.int(u32, event.pixel_y);
}

pub fn decodeMouseEvent(dec: *Decoder) !vt.mouse.Event {
    const kind = std.enums.fromInt(vt.mouse.Kind, try dec.byte()) orelse
        return error.InvalidMouseEvent;
    const button = std.enums.fromInt(vt.mouse.Button, try dec.byte()) orelse
        return error.InvalidMouseEvent;
    const modifiers_raw = try dec.byte();
    if (modifiers_raw > 0b111) return error.InvalidMouseEvent;
    const modifiers: vt.mouse.Modifiers = @bitCast(@as(u3, @truncate(modifiers_raw)));
    const col = try dec.int(u16);
    const row = try dec.int(u16);
    const pixel_x = try dec.int(u32);
    const pixel_y = try dec.int(u32);
    try dec.finish();
    return .{
        .kind = kind,
        .button = button,
        .modifiers = modifiers,
        .col = col,
        .row = row,
        .pixel_x = pixel_x,
        .pixel_y = pixel_y,
    };
}

pub fn encodeKeyEvent(enc: *Encoder, event: vt.keyboard.Event) !void {
    try validateKeyEvent(event);
    try enc.byte(@intFromEnum(event.code));
    try enc.byte(@intFromEnum(event.action));
    try enc.byte(@bitCast(event.modifiers));
    try enc.int(u32, event.codepoint);
    try enc.int(u32, event.shifted_codepoint);
    try enc.int(u32, event.base_layout_codepoint);
    try enc.bytes(event.text);
}

pub fn decodeKeyEvent(dec: *Decoder) !vt.keyboard.Event {
    const code = std.enums.fromInt(vt.keyboard.Code, try dec.byte()) orelse
        return error.InvalidKeyEvent;
    const action = std.enums.fromInt(vt.keyboard.Action, try dec.byte()) orelse
        return error.InvalidKeyEvent;
    const modifiers_raw = try dec.byte();
    if (modifiers_raw & 0b1100_0000 != 0) return error.InvalidKeyEvent;
    const modifiers: vt.keyboard.Modifiers = @bitCast(modifiers_raw);
    const codepoint = try dec.int(u32);
    const shifted_codepoint = try dec.int(u32);
    const base_layout_codepoint = try dec.int(u32);
    if (codepoint > 0x10ffff or shifted_codepoint > 0x10ffff or
        base_layout_codepoint > 0x10ffff)
        return error.InvalidKeyEvent;
    const text_len = try dec.int(u32);
    if (text_len > vt.keyboard.max_text_bytes) return error.InvalidKeyEvent;
    const text = try dec.slice(text_len);
    try dec.finish();
    const event: vt.keyboard.Event = .{
        .code = code,
        .action = action,
        .modifiers = modifiers,
        .codepoint = @intCast(codepoint),
        .shifted_codepoint = @intCast(shifted_codepoint),
        .base_layout_codepoint = @intCast(base_layout_codepoint),
        .text = text,
    };
    try validateKeyEvent(event);
    return event;
}

fn validateKeyEvent(event: vt.keyboard.Event) !void {
    if (event.text.len > vt.keyboard.max_text_bytes) return error.InvalidKeyEvent;
    _ = std.unicode.Utf8View.init(event.text) catch return error.InvalidKeyEvent;
    if (event.action == .release and event.text.len != 0) return error.InvalidKeyEvent;

    switch (event.code) {
        .text => if (event.codepoint != 0 or event.shifted_codepoint != 0 or
            event.base_layout_codepoint != 0 or event.text.len == 0)
            return error.InvalidKeyEvent,
        .codepoint => {
            if (event.codepoint == 0 or !validScalar(event.codepoint)) return error.InvalidKeyEvent;
            if ((event.shifted_codepoint != 0 and !validScalar(event.shifted_codepoint)) or
                (event.base_layout_codepoint != 0 and !validScalar(event.base_layout_codepoint)))
                return error.InvalidKeyEvent;
        },
        else => if (event.codepoint != 0 or event.shifted_codepoint != 0 or
            event.base_layout_codepoint != 0)
            return error.InvalidKeyEvent,
    }
}

pub fn encodeCreateRequest(enc: *Encoder, request: CreateRequest) !void {
    try encodeCreateFields(enc, request);
}

fn encodeCreateFields(enc: *Encoder, request: CreateRequest) !void {
    try enc.int(u16, request.cols);
    try enc.int(u16, request.rows);
    try enc.boolean(request.cwd != null);
    if (request.cwd) |cwd| try enc.bytes(cwd);
}

pub fn decodeCreateRequest(dec: *Decoder) !CreateRequest {
    const request = try decodeCreateFields(dec);
    try dec.finish();
    return request;
}

fn decodeCreateFields(dec: *Decoder) !CreateRequest {
    const cols = try dec.int(u16);
    const rows = try dec.int(u16);
    const cwd = if (try dec.boolean()) blk: {
        const len = try dec.int(u32);
        if (len == 0 or len > max_working_directory_bytes) return error.InvalidWorkingDirectory;
        const path = try dec.slice(len);
        if (!validWorkingDirectory(path)) return error.InvalidWorkingDirectory;
        break :blk path;
    } else null;
    return .{ .cols = cols, .rows = rows, .cwd = cwd };
}

pub fn encodeCreateBesideRequest(enc: *Encoder, request: CreateBesideRequest) !void {
    if (request.existing_id == 0) return error.InvalidSession;
    try enc.int(u64, request.existing_id);
    try encodeCreateFields(enc, request.create);
}

pub fn decodeCreateBesideRequest(dec: *Decoder) !CreateBesideRequest {
    const existing_id = try dec.int(u64);
    if (existing_id == 0) return error.InvalidSession;
    const create = try decodeCreateFields(dec);
    try dec.finish();
    return .{ .existing_id = existing_id, .create = create };
}

pub const SnapshotModes = packed struct(u8) {
    on_alt: bool = false,
    cursor_visible: bool = true,
    synchronized_output: bool = false,
    grapheme_cluster: bool = false,
    focus_reporting: bool = false,
    mouse_reporting: bool = false,
    pointer_shape: vt.mouse.PointerShape = .text,
};

pub const ImageRef = struct {
    id: u32,
    generation: u64,
    width: u32,
    height: u32,
};

pub const Image = struct {
    id: u32,
    generation: u64,
    width: u32,
    height: u32,
    rgba: []u8,
    /// Allocation that owns `rgba`. Ordinary decode owns the RGBA slice
    /// itself; frame decode adopts the complete socket payload so the image
    /// bytes are not copied a second time in the viewer.
    backing: ?[]u8 = null,

    pub fn deinit(self: *Image, alloc: std.mem.Allocator) void {
        if (self.backing) |bytes| alloc.free(bytes) else alloc.free(self.rgba);
        self.* = undefined;
    }
};

pub const StagedImage = struct {
    slot_index: u8,
    lease_token: u64,
    id: u32,
    generation: u64,
    width: u32,
    height: u32,
    bytes_per_row: u32,
    byte_length: u64,
};

pub fn encodeStagedImage(enc: *Encoder, image: StagedImage) !void {
    try enc.byte(image.slot_index);
    try enc.int(u64, image.lease_token);
    try enc.int(u32, image.id);
    try enc.int(u64, image.generation);
    try enc.int(u32, image.width);
    try enc.int(u32, image.height);
    try enc.int(u32, image.bytes_per_row);
    try enc.int(u64, image.byte_length);
}

pub fn decodeStagedImage(dec: *Decoder) !StagedImage {
    const image: StagedImage = .{
        .slot_index = try dec.byte(),
        .lease_token = try dec.int(u64),
        .id = try dec.int(u32),
        .generation = try dec.int(u64),
        .width = try dec.int(u32),
        .height = try dec.int(u32),
        .bytes_per_row = try dec.int(u32),
        .byte_length = try dec.int(u64),
    };
    if (image.slot_index >= 3 or image.lease_token == 0)
        return error.InvalidStagedImage;
    const active_row = std.math.mul(u64, image.width, 4) catch
        return error.InvalidStagedImage;
    if (image.id == 0 or image.generation == 0 or image.width == 0 or
        image.height == 0 or image.width > vt.graphics.max_dimension or
        image.height > vt.graphics.max_dimension or
        @as(u64, image.bytes_per_row) < active_row)
        return error.InvalidStagedImage;
    const expected = std.math.mul(u64, image.bytes_per_row, image.height) catch
        return error.InvalidStagedImage;
    if (image.byte_length != expected or expected > max_payload)
        return error.InvalidStagedImage;
    return image;
}

pub fn encodeImage(enc: *Encoder, image: Image) !void {
    try enc.int(u32, image.id);
    try enc.int(u64, image.generation);
    try enc.int(u32, image.width);
    try enc.int(u32, image.height);
    try enc.bytes(image.rgba);
}

pub fn decodeImage(dec: *Decoder, alloc: std.mem.Allocator) !Image {
    const id = try dec.int(u32);
    const generation = try dec.int(u64);
    const width = try dec.int(u32);
    const height = try dec.int(u32);
    const expected = imageByteLen(id, generation, width, height) catch
        return error.InvalidImage;
    const rgba = try dec.allocBytes(alloc, graphics_limits.max_image_bytes);
    errdefer alloc.free(rgba);
    if (rgba.len != expected) return error.InvalidImage;
    return .{
        .id = id,
        .generation = generation,
        .width = width,
        .height = height,
        .rgba = rgba,
        .backing = rgba,
    };
}

/// Decode an image by adopting the already allocated frame payload. The
/// returned RGBA slice aliases that backing, and `frame` relinquishes it.
pub fn decodeImageFrame(frame: *Frame) !Image {
    var dec: Decoder = .{ .bytes = frame.payload };
    const id = try dec.int(u32);
    const generation = try dec.int(u64);
    const width = try dec.int(u32);
    const height = try dec.int(u32);
    const expected = imageByteLen(id, generation, width, height) catch
        return error.InvalidImage;
    const rgba_len = try dec.int(u32);
    if (@as(usize, rgba_len) != expected or
        @as(usize, rgba_len) > graphics_limits.max_image_bytes)
        return error.InvalidImage;
    const rgba_const = try dec.slice(@intCast(rgba_len));
    try dec.finish();
    const backing = frame.payload;
    frame.owns_payload = false;
    return .{
        .id = id,
        .generation = generation,
        .width = width,
        .height = height,
        .rgba = @constCast(rgba_const),
        .backing = backing,
    };
}

fn imageByteLen(id: u32, generation: u64, width: u32, height: u32) !usize {
    if (id == 0 or generation == 0 or width == 0 or height == 0 or
        width > vt.graphics.max_dimension or height > vt.graphics.max_dimension)
        return error.InvalidImage;
    const pixels = try std.math.mul(usize, width, height);
    const rgba_len = try std.math.mul(usize, pixels, 4);
    if (rgba_len > graphics_limits.max_image_bytes) return error.InvalidImage;
    return rgba_len;
}

pub const Placement = struct {
    image_id: u32,
    generation: u64,
    placement_id: u32,
    row: i32,
    col: u16,
    cell_offset_x: u32,
    cell_offset_y: u32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
    dest_width: u32,
    dest_height: u32,
    z: i32,
};

pub const Hyperlink = struct {
    /// Empty for an implicit per-opening OSC 8 identity.
    explicit_id: []u8,
    uri: []u8,

    pub fn deinit(self: *Hyperlink, alloc: std.mem.Allocator) void {
        alloc.free(self.explicit_id);
        alloc.free(self.uri);
        self.* = undefined;
    }
};

/// Renderer-ready visible state. Scrollback stays authoritative in the daemon;
/// viewport commands change which rows are captured here.
pub const Snapshot = struct {
    id: u64,
    cols: u16,
    rows: u16,
    col: u16,
    row: u16,
    viewport_offset: u64,
    sync_output_epoch: u64,
    grid_epoch: u64 = 0,
    modes: SnapshotModes,
    exited: bool,
    working: bool,
    attention: bool,
    title: []u8,
    cells: []vt.Cell,
    graphemes: []u21,
    hyperlinks: []Hyperlink,
    selected: []bool,
    /// Viewer-local renderer layers. They are populated by a separate search
    /// result and intentionally are not part of the authoritative snapshot
    /// wire shape.
    search_matches: ?[]bool = null,
    search_selected: ?[]bool = null,
    images: []ImageRef,
    placements: []Placement,

    pub fn deinit(self: *Snapshot, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        alloc.free(self.cells);
        alloc.free(self.graphemes);
        for (self.hyperlinks) |*link| link.deinit(alloc);
        alloc.free(self.hyperlinks);
        alloc.free(self.selected);
        if (self.search_matches) |mask| alloc.free(mask);
        if (self.search_selected) |mask| alloc.free(mask);
        alloc.free(self.images);
        alloc.free(self.placements);
        self.* = undefined;
    }

    pub fn viewportOffset(self: *const Snapshot) usize {
        return @intCast(self.viewport_offset);
    }

    pub fn viewCellAt(self: *const Snapshot, row: u16, col: u16) vt.Cell {
        return self.cells[@as(usize, row) * self.cols + col];
    }

    pub fn viewCellSelected(self: *const Snapshot, row: u16, col: u16) bool {
        return self.selected[@as(usize, row) * self.cols + col];
    }

    pub fn viewCellSearchMatch(self: *const Snapshot, row: u16, col: u16) bool {
        const mask = self.search_matches orelse return false;
        return mask[@as(usize, row) * self.cols + col];
    }

    pub fn viewCellSearchSelected(self: *const Snapshot, row: u16, col: u16) bool {
        const mask = self.search_selected orelse return false;
        return mask[@as(usize, row) * self.cols + col];
    }

    pub fn viewCellGrapheme(self: *const Snapshot, cell: vt.Cell) []const u21 {
        if (cell.grapheme_len == 0) return &.{};
        const offset: usize = cell.grapheme_offset;
        return self.graphemes[offset..][0..cell.grapheme_len];
    }

    pub fn viewCellHyperlink(self: *const Snapshot, cell: vt.Cell) ?*const Hyperlink {
        if (cell.hyperlink_id == 0 or cell.hyperlink_id > self.hyperlinks.len) return null;
        return &self.hyperlinks[cell.hyperlink_id - 1];
    }

    pub fn encode(self: *const Snapshot, enc: *Encoder) !void {
        try enc.int(u64, self.id);
        try enc.int(u16, self.cols);
        try enc.int(u16, self.rows);
        try enc.int(u16, self.col);
        try enc.int(u16, self.row);
        try enc.int(u64, self.viewport_offset);
        try enc.int(u64, self.sync_output_epoch);
        try enc.int(u64, self.grid_epoch);
        try enc.byte(@bitCast(self.modes));
        try enc.boolean(self.exited);
        try enc.boolean(self.working);
        try enc.boolean(self.attention);
        try enc.bytes(self.title);
        try enc.int(u32, @intCast(self.cells.len));
        const hyperlink_referenced = try enc.alloc.alloc(bool, self.hyperlinks.len);
        defer enc.alloc.free(hyperlink_referenced);
        @memset(hyperlink_referenced, false);
        for (self.cells, self.selected) |cell, selected| {
            if (cell.hyperlink_id > self.hyperlinks.len) return error.InvalidSnapshot;
            if (cell.hyperlink_id != 0)
                hyperlink_referenced[cell.hyperlink_id - 1] = true;
            try enc.byte(cell.grapheme_len + 1);
            try enc.int(u32, cell.cp);
            for (self.viewCellGrapheme(cell)) |suffix| try enc.int(u32, suffix);
            try enc.int(u16, @bitCast(cell.flags));
            try encodeColor(enc, cell.fg);
            try encodeColor(enc, cell.bg);
            try encodeColor(enc, cell.underline_color);
            try enc.int(u32, cell.hyperlink_id);
            try enc.boolean(selected);
        }
        if (self.hyperlinks.len > vt.hyperlink.max_entries) return error.InvalidSnapshot;
        for (hyperlink_referenced) |referenced|
            if (!referenced) return error.InvalidSnapshot;
        try enc.int(u16, @intCast(self.hyperlinks.len));
        var hyperlink_bytes: usize = 0;
        for (self.hyperlinks, 0..) |link, link_index| {
            if (link.explicit_id.len > vt.hyperlink.max_explicit_id_bytes or
                link.uri.len == 0 or link.uri.len > vt.hyperlink.max_uri_bytes or
                !vt.hyperlink.validPrintableAscii(link.explicit_id) or
                !vt.hyperlink.validPrintableAscii(link.uri)) return error.InvalidSnapshot;
            hyperlink_bytes = std.math.add(
                usize,
                hyperlink_bytes,
                link.explicit_id.len + link.uri.len,
            ) catch return error.InvalidSnapshot;
            if (hyperlink_bytes > vt.hyperlink.max_metadata_bytes) return error.InvalidSnapshot;
            if (link.explicit_id.len != 0) for (self.hyperlinks[0..link_index]) |existing| {
                if (std.mem.eql(u8, existing.explicit_id, link.explicit_id) and
                    std.mem.eql(u8, existing.uri, link.uri)) return error.InvalidSnapshot;
            };
            try enc.bytes(link.explicit_id);
            try enc.bytes(link.uri);
        }
        try enc.int(u16, @intCast(self.images.len));
        for (self.images) |image| {
            try enc.int(u32, image.id);
            try enc.int(u64, image.generation);
            try enc.int(u32, image.width);
            try enc.int(u32, image.height);
        }
        if (self.placements.len > self.cells.len + vt.graphics.max_placements)
            return error.InvalidSnapshot;
        try enc.int(u32, @intCast(self.placements.len));
        for (self.placements) |placement| {
            try enc.int(u32, placement.image_id);
            try enc.int(u64, placement.generation);
            try enc.int(u32, placement.placement_id);
            try enc.int(i32, placement.row);
            try enc.int(u16, placement.col);
            try enc.int(u32, placement.cell_offset_x);
            try enc.int(u32, placement.cell_offset_y);
            try enc.int(u32, placement.source_x);
            try enc.int(u32, placement.source_y);
            try enc.int(u32, placement.source_width);
            try enc.int(u32, placement.source_height);
            try enc.int(u32, placement.dest_width);
            try enc.int(u32, placement.dest_height);
            try enc.int(i32, placement.z);
        }
    }

    pub fn decode(dec: *Decoder, alloc: std.mem.Allocator) !Snapshot {
        const id = try dec.int(u64);
        const cols = try dec.int(u16);
        const rows = try dec.int(u16);
        if (cols < 2 or rows < 1) return error.InvalidSnapshot;
        const col = try dec.int(u16);
        const row = try dec.int(u16);
        const viewport_offset = try dec.int(u64);
        const sync_output_epoch = try dec.int(u64);
        const grid_epoch = try dec.int(u64);
        const modes: SnapshotModes = @bitCast(try dec.byte());
        const exited = try dec.boolean();
        const working = try dec.boolean();
        const attention = try dec.boolean();
        const title = try dec.allocBytes(alloc, 4096);
        errdefer alloc.free(title);
        const count = try dec.int(u32);
        const expected = @as(usize, cols) * rows;
        if (count != expected) return error.InvalidSnapshot;
        const cells = try alloc.alloc(vt.Cell, expected);
        errdefer alloc.free(cells);
        const selected = try alloc.alloc(bool, expected);
        errdefer alloc.free(selected);
        var graphemes: std.ArrayList(u21) = .empty;
        errdefer graphemes.deinit(alloc);
        for (cells, selected) |*cell, *is_selected| {
            const cp_count = try dec.byte();
            if (cp_count == 0 or cp_count > vt.max_grapheme_codepoints)
                return error.InvalidSnapshot;
            const cp = try dec.int(u32);
            if (!validScalar(cp)) return error.InvalidSnapshot;
            const offset = graphemes.items.len;
            var suffix_i: u8 = 1;
            while (suffix_i < cp_count) : (suffix_i += 1) {
                const suffix = try dec.int(u32);
                if (!validScalar(suffix)) return error.InvalidSnapshot;
                try graphemes.append(alloc, @intCast(suffix));
            }
            const flags: vt.Flags = @bitCast(try dec.int(u16));
            if (flags.wide and flags.wide_spacer) return error.InvalidSnapshot;
            if ((flags.wide_spacer or flags.wide_pad) and
                (cp_count != 1 or cp != ' ' or flags.content))
                return error.InvalidSnapshot;
            cell.* = .{
                .cp = @intCast(cp),
                .grapheme_offset = if (cp_count == 1) 0 else @intCast(offset),
                .grapheme_len = cp_count - 1,
                .flags = flags,
                .fg = try decodeColor(dec),
                .bg = try decodeColor(dec),
                .underline_color = try decodeColor(dec),
                .hyperlink_id = try dec.int(u32),
            };
            is_selected.* = try dec.boolean();
        }
        const hyperlink_count = try dec.int(u16);
        if (hyperlink_count > vt.hyperlink.max_entries or hyperlink_count > expected)
            return error.InvalidSnapshot;
        const hyperlinks = try alloc.alloc(Hyperlink, hyperlink_count);
        errdefer alloc.free(hyperlinks);
        var decoded_hyperlinks: usize = 0;
        var hyperlink_bytes: usize = 0;
        errdefer for (hyperlinks[0..decoded_hyperlinks]) |*link| link.deinit(alloc);
        for (hyperlinks) |*link| {
            const explicit_id = try dec.allocBytes(alloc, vt.hyperlink.max_explicit_id_bytes);
            errdefer alloc.free(explicit_id);
            const uri = try dec.allocBytes(alloc, vt.hyperlink.max_uri_bytes);
            errdefer alloc.free(uri);
            if (uri.len == 0 or !vt.hyperlink.validPrintableAscii(explicit_id) or
                !vt.hyperlink.validPrintableAscii(uri)) return error.InvalidSnapshot;
            hyperlink_bytes = std.math.add(
                usize,
                hyperlink_bytes,
                explicit_id.len + uri.len,
            ) catch return error.InvalidSnapshot;
            if (hyperlink_bytes > vt.hyperlink.max_metadata_bytes) return error.InvalidSnapshot;
            if (explicit_id.len != 0) for (hyperlinks[0..decoded_hyperlinks]) |existing| {
                if (std.mem.eql(u8, existing.explicit_id, explicit_id) and
                    std.mem.eql(u8, existing.uri, uri)) return error.InvalidSnapshot;
            };
            link.* = .{ .explicit_id = explicit_id, .uri = uri };
            decoded_hyperlinks += 1;
        }
        var cell_i: usize = 0;
        const hyperlink_referenced = try alloc.alloc(bool, hyperlinks.len);
        defer alloc.free(hyperlink_referenced);
        @memset(hyperlink_referenced, false);
        while (cell_i < cells.len) : (cell_i += 1) {
            const cell_col = cell_i % cols;
            if (cells[cell_i].hyperlink_id > hyperlinks.len) return error.InvalidSnapshot;
            if (cells[cell_i].hyperlink_id != 0)
                hyperlink_referenced[cells[cell_i].hyperlink_id - 1] = true;
            if (cells[cell_i].flags.wide) {
                if (cell_col + 1 >= cols or !cells[cell_i + 1].flags.wide_spacer)
                    return error.InvalidSnapshot;
                if (cells[cell_i].hyperlink_id != cells[cell_i + 1].hyperlink_id)
                    return error.InvalidSnapshot;
            }
            if (cells[cell_i].flags.wide_spacer) {
                if (cell_col == 0 or !cells[cell_i - 1].flags.wide)
                    return error.InvalidSnapshot;
            }
        }
        for (hyperlink_referenced) |referenced|
            if (!referenced) return error.InvalidSnapshot;
        const image_count = try dec.int(u16);
        if (image_count > graphics_limits.max_images) return error.InvalidSnapshot;
        const images = try alloc.alloc(ImageRef, image_count);
        errdefer alloc.free(images);
        var visible_image_bytes: usize = 0;
        for (images, 0..) |*image, image_index| {
            const image_id = try dec.int(u32);
            const generation = try dec.int(u64);
            const width = try dec.int(u32);
            const height = try dec.int(u32);
            if (image_id == 0 or generation == 0 or width == 0 or height == 0 or
                width > vt.graphics.max_dimension or height > vt.graphics.max_dimension)
                return error.InvalidSnapshot;
            const pixels = std.math.mul(usize, width, height) catch return error.InvalidSnapshot;
            const rgba_len = std.math.mul(usize, pixels, 4) catch return error.InvalidSnapshot;
            if (rgba_len > graphics_limits.max_image_bytes) return error.InvalidSnapshot;
            visible_image_bytes = std.math.add(usize, visible_image_bytes, rgba_len) catch
                return error.InvalidSnapshot;
            if (visible_image_bytes > graphics_limits.max_total_bytes) return error.InvalidSnapshot;
            for (images[0..image_index]) |existing| {
                if (existing.id == image_id) return error.InvalidSnapshot;
            }
            image.* = .{
                .id = image_id,
                .generation = generation,
                .width = width,
                .height = height,
            };
        }
        const placement_count = try dec.int(u32);
        if (placement_count > expected + vt.graphics.max_placements)
            return error.InvalidSnapshot;
        const placements = try alloc.alloc(Placement, placement_count);
        errdefer alloc.free(placements);
        for (placements) |*placement| {
            placement.* = .{
                .image_id = try dec.int(u32),
                .generation = try dec.int(u64),
                .placement_id = try dec.int(u32),
                .row = try dec.int(i32),
                .col = try dec.int(u16),
                .cell_offset_x = try dec.int(u32),
                .cell_offset_y = try dec.int(u32),
                .source_x = try dec.int(u32),
                .source_y = try dec.int(u32),
                .source_width = try dec.int(u32),
                .source_height = try dec.int(u32),
                .dest_width = try dec.int(u32),
                .dest_height = try dec.int(u32),
                .z = try dec.int(i32),
            };
            const image = findImage(images, placement.image_id, placement.generation) orelse
                return error.InvalidSnapshot;
            if (placement.row >= rows or placement.col >= cols or
                placement.source_width == 0 or placement.source_height == 0 or
                placement.dest_width == 0 or placement.dest_height == 0 or
                placement.source_x > image.width or placement.source_y > image.height or
                placement.source_width > image.width - placement.source_x or
                placement.source_height > image.height - placement.source_y)
                return error.InvalidSnapshot;
        }
        const grapheme_slice = try graphemes.toOwnedSlice(alloc);
        errdefer alloc.free(grapheme_slice);
        return .{
            .id = id,
            .cols = cols,
            .rows = rows,
            .col = col,
            .row = row,
            .viewport_offset = viewport_offset,
            .sync_output_epoch = sync_output_epoch,
            .grid_epoch = grid_epoch,
            .modes = modes,
            .exited = exited,
            .working = working,
            .attention = attention,
            .title = title,
            .cells = cells,
            .graphemes = grapheme_slice,
            .hyperlinks = hyperlinks,
            .selected = selected,
            .images = images,
            .placements = placements,
        };
    }
};

fn findImage(images: []const ImageRef, id: u32, generation: u64) ?*const ImageRef {
    for (images) |*image| if (image.id == id and image.generation == generation) return image;
    return null;
}

fn validScalar(cp: u32) bool {
    return cp <= 0x10ffff and !(cp >= 0xd800 and cp <= 0xdfff);
}

pub const Frame = struct {
    tag: Tag,
    payload: []u8,
    owns_payload: bool = true,

    pub fn deinit(self: *Frame, alloc: std.mem.Allocator) void {
        if (self.owns_payload) alloc.free(self.payload);
        self.* = undefined;
    }
};

pub const Encoder = struct {
    alloc: std.mem.Allocator,
    bytes_list: std.ArrayList(u8) = .empty,

    pub fn init(alloc: std.mem.Allocator) Encoder {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Encoder) void {
        self.bytes_list.deinit(self.alloc);
    }

    pub fn byte(self: *Encoder, value: u8) !void {
        try self.bytes_list.append(self.alloc, value);
    }

    pub fn boolean(self: *Encoder, value: bool) !void {
        try self.byte(@intFromBool(value));
    }

    pub fn int(self: *Encoder, comptime T: type, value: T) !void {
        const byte_len = @divExact(@bitSizeOf(T), 8);
        var buf: [byte_len]u8 = undefined;
        std.mem.writeInt(T, &buf, value, .little);
        try self.bytes_list.appendSlice(self.alloc, &buf);
    }

    pub fn bytes(self: *Encoder, value: []const u8) !void {
        try self.int(u32, @intCast(value.len));
        try self.bytes_list.appendSlice(self.alloc, value);
    }

    pub fn slice(self: *const Encoder) []const u8 {
        return self.bytes_list.items;
    }
};

pub const Decoder = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn remaining(self: *const Decoder) usize {
        return self.bytes.len - self.pos;
    }

    pub fn finish(self: *const Decoder) !void {
        if (self.pos != self.bytes.len) return error.TrailingData;
    }

    pub fn byte(self: *Decoder) !u8 {
        if (self.pos == self.bytes.len) return error.Truncated;
        defer self.pos += 1;
        return self.bytes[self.pos];
    }

    pub fn boolean(self: *Decoder) !bool {
        return switch (try self.byte()) {
            0 => false,
            1 => true,
            else => error.InvalidBoolean,
        };
    }

    pub fn int(self: *Decoder, comptime T: type) !T {
        const byte_len = @divExact(@bitSizeOf(T), 8);
        const end = std.math.add(usize, self.pos, byte_len) catch return error.Truncated;
        if (end > self.bytes.len) return error.Truncated;
        defer self.pos = end;
        const ptr: *const [byte_len]u8 = @ptrCast(self.bytes[self.pos..end].ptr);
        return std.mem.readInt(T, ptr, .little);
    }

    pub fn slice(self: *Decoder, len: usize) ![]const u8 {
        const end = std.math.add(usize, self.pos, len) catch return error.Truncated;
        if (end > self.bytes.len) return error.Truncated;
        defer self.pos = end;
        return self.bytes[self.pos..end];
    }

    pub fn allocBytes(self: *Decoder, alloc: std.mem.Allocator, limit: usize) ![]u8 {
        const len = try self.int(u32);
        if (len > limit) return error.LengthLimit;
        return alloc.dupe(u8, try self.slice(len));
    }
};

pub fn encodeMetadata(enc: *Encoder, metadata: Metadata) !void {
    try enc.int(u64, metadata.id);
    try enc.bytes(metadata.title);
    try enc.boolean(metadata.exited);
    try enc.boolean(metadata.working);
    try enc.boolean(metadata.attention);
    try enc.boolean(metadata.cwd != null);
    if (metadata.cwd) |cwd| {
        if (!validWorkingDirectory(cwd)) return error.InvalidWorkingDirectory;
        try enc.bytes(cwd);
    }
}

pub fn decodeMetadata(dec: *Decoder, alloc: std.mem.Allocator) !Metadata {
    const id = try dec.int(u64);
    const title = try dec.allocBytes(alloc, 4096);
    errdefer alloc.free(title);
    const exited = try dec.boolean();
    const working = try dec.boolean();
    const attention = try dec.boolean();
    const cwd = if (try dec.boolean()) blk: {
        const path = try dec.allocBytes(alloc, max_working_directory_bytes);
        errdefer alloc.free(path);
        if (!validWorkingDirectory(path)) return error.InvalidWorkingDirectory;
        break :blk path;
    } else null;
    return .{
        .id = id,
        .title = title,
        .exited = exited,
        .working = working,
        .attention = attention,
        .cwd = cwd,
    };
}

fn validWorkingDirectory(path: []const u8) bool {
    if (path.len == 0 or path.len > max_working_directory_bytes or
        !std.fs.path.isAbsolute(path)) return false;
    for (path) |byte| if (byte == 0 or byte < 0x20 or byte == 0x7f) return false;
    return true;
}

pub fn encodeDisplayItem(enc: *Encoder, item: DisplayItem) !void {
    switch (item) {
        .single => |id| {
            try enc.byte(0);
            try enc.int(u64, id);
        },
        .pair => |pair_item| {
            try enc.byte(1);
            try enc.int(u64, pair_item.left);
            try enc.int(u64, pair_item.right);
            try enc.byte(@intFromEnum(pair_item.focused));
            try enc.int(u16, pair_item.ratio);
            try enc.boolean(pair_item.zoomed);
        },
    }
}

pub fn decodeDisplayItem(dec: *Decoder) !DisplayItem {
    return switch (try dec.byte()) {
        0 => blk: {
            const id = try dec.int(u64);
            if (id == 0) return error.InvalidDisplayItem;
            break :blk .{ .single = id };
        },
        1 => blk: {
            const left = try dec.int(u64);
            const right = try dec.int(u64);
            const focused = std.enums.fromInt(FocusedMember, try dec.byte()) orelse
                return error.InvalidDisplayItem;
            const ratio = try dec.int(u16);
            const zoomed = try dec.boolean();
            if (left == 0 or right == 0 or left == right or ratio == 0 or
                ratio == std.math.maxInt(u16)) return error.InvalidDisplayItem;
            break :blk .{ .pair = .{
                .left = left,
                .right = right,
                .focused = focused,
                .ratio = ratio,
                .zoomed = zoomed,
            } };
        },
        else => error.InvalidDisplayItem,
    };
}

pub fn encodeRegistry(enc: *Encoder, sessions: []const Metadata, items: []const DisplayItem) !void {
    try enc.int(u32, @intCast(sessions.len));
    for (sessions) |metadata| try encodeMetadata(enc, metadata);
    try enc.int(u32, @intCast(items.len));
    for (items) |item| try encodeDisplayItem(enc, item);
}

pub fn decodeRegistry(dec: *Decoder, alloc: std.mem.Allocator) !RegistrySnapshot {
    const session_count = try dec.int(u32);
    if (session_count > 10_000) return error.LengthLimit;
    const sessions = try alloc.alloc(Metadata, session_count);
    errdefer alloc.free(sessions);
    var initialized: usize = 0;
    errdefer for (sessions[0..initialized]) |*metadata| metadata.deinit(alloc);
    while (initialized < sessions.len) : (initialized += 1) {
        sessions[initialized] = try decodeMetadata(dec, alloc);
    }

    const item_count = try dec.int(u32);
    if (item_count > session_count) return error.InvalidRegistry;
    const items = try alloc.alloc(DisplayItem, item_count);
    errdefer alloc.free(items);
    for (items) |*item| item.* = try decodeDisplayItem(dec);
    try dec.finish();

    var known = std.AutoHashMap(u64, void).init(alloc);
    defer known.deinit();
    for (sessions) |metadata| {
        if (metadata.id == 0 or known.contains(metadata.id)) return error.InvalidRegistry;
        try known.put(metadata.id, {});
    }
    var membership = std.AutoHashMap(u64, void).init(alloc);
    defer membership.deinit();
    for (items) |item| switch (item) {
        .single => |id| try validateMembership(&known, &membership, id),
        .pair => |pair_item| {
            try validateMembership(&known, &membership, pair_item.left);
            try validateMembership(&known, &membership, pair_item.right);
        },
    };
    if (membership.count() != known.count()) return error.InvalidRegistry;
    return .{ .sessions = sessions, .display_items = items };
}

fn validateMembership(
    known: *const std.AutoHashMap(u64, void),
    membership: *std.AutoHashMap(u64, void),
    id: u64,
) !void {
    if (!known.contains(id) or membership.contains(id)) return error.InvalidRegistry;
    try membership.put(id, {});
}

pub fn socketPath(alloc: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    const home = env.get("HOME") orelse return error.HomeNotSet;
    return std.fmt.allocPrint(
        alloc,
        "{s}/Library/Application Support/boringterminal/daemon.sock",
        .{home},
    );
}

pub fn supportDir(alloc: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    const home = env.get("HOME") orelse return error.HomeNotSet;
    return std.fmt.allocPrint(
        alloc,
        "{s}/Library/Application Support/boringterminal",
        .{home},
    );
}

pub fn writeFrame(fd: c.fd_t, tag: Tag, payload: []const u8) !void {
    return writeFrameVersion(fd, version, tag, payload);
}

/// Write a frame for an explicitly selected attach dialect. The daemon uses
/// `writeFrame`; only the viewer's compatibility dispatch calls this helper.
pub fn writeFrameVersion(fd: c.fd_t, dialect: u16, tag: Tag, payload: []const u8) !void {
    if (payload.len > max_payload) return error.PayloadTooLarge;
    var header: [header_len]u8 = undefined;
    @memcpy(header[0..4], magic);
    std.mem.writeInt(u16, header[4..6], dialect, .little);
    std.mem.writeInt(u16, header[6..8], @intFromEnum(tag), .little);
    std.mem.writeInt(u32, header[8..12], @intCast(payload.len), .little);
    try sendAll(fd, &header);
    try sendAll(fd, payload);
}

pub const descriptor_envelope: u8 = 0x47; // "G"raphics staging envelope.

const RightsControl = extern struct {
    header: c.cmsghdr,
    fd: c.fd_t,
};

comptime {
    // Darwin's CMSG_SPACE(sizeof(int)) is one 12-byte header plus one fd.
    std.debug.assert(@sizeOf(RightsControl) == 16);
}

/// Send the one-byte staging envelope, optionally carrying one descriptor.
/// The ordinary versioned frame follows with `writeFrame`.
pub fn writeDescriptorEnvelope(fd: c.fd_t, descriptor: ?c.fd_t) !void {
    var byte: [1]u8 = .{descriptor_envelope};
    var iov: c.iovec_const = .{ .base = &byte, .len = byte.len };
    var control: RightsControl = undefined;
    var message: c.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iov),
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    if (descriptor) |passed_fd| {
        control = .{
            .header = .{
                .len = @sizeOf(RightsControl),
                .level = c.SOL.SOCKET,
                .type = c.SCM.RIGHTS,
            },
            .fd = passed_fd,
        };
        message.control = &control;
        message.controllen = @sizeOf(RightsControl);
    }
    while (true) {
        const sent = c.sendmsg(fd, &message, c.MSG.NOSIGNAL);
        if (sent == 1) return;
        if (sent < 0 and c.errno(sent) == .INTR) continue;
        return error.DescriptorSendFailed;
    }
}

/// Receive the staging envelope and exactly zero or one descriptor. Any
/// installed descriptors from malformed ancillary data are closed before the
/// error escapes.
pub fn readDescriptorEnvelope(fd: c.fd_t) !?c.fd_t {
    var byte: [1]u8 = undefined;
    var iov: c.iovec = .{ .base = &byte, .len = byte.len };
    var control: [128]u8 align(@alignOf(c.cmsghdr)) = undefined;
    var message: c.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iov),
        .iovlen = 1,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };
    const received = while (true) {
        const n = c.recvmsg(fd, &message, 0);
        if (n < 0 and c.errno(n) == .INTR) continue;
        break n;
    };
    const used: usize = @intCast(message.controllen);
    if (received != 1 or byte[0] != descriptor_envelope or
        (message.flags & c.MSG.CTRUNC) != 0)
    {
        closeReceivedRights(control[0..@min(used, control.len)]);
        return error.InvalidDescriptorEnvelope;
    }
    if (used == 0) return null;
    if (used != @sizeOf(RightsControl)) {
        closeReceivedRights(control[0..@min(used, control.len)]);
        return error.InvalidDescriptorEnvelope;
    }
    const rights: *align(1) const RightsControl = @ptrCast(&control);
    if (rights.header.len != @sizeOf(RightsControl) or
        rights.header.level != c.SOL.SOCKET or rights.header.type != c.SCM.RIGHTS or
        rights.fd < 0)
    {
        closeReceivedRights(control[0..used]);
        return error.InvalidDescriptorEnvelope;
    }
    if (c.fcntl(rights.fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) {
        _ = c.close(rights.fd);
        return error.DescriptorFlagsFailed;
    }
    return rights.fd;
}

fn closeReceivedRights(control: []const u8) void {
    var offset: usize = 0;
    while (offset + @sizeOf(c.cmsghdr) <= control.len) {
        const header: *align(1) const c.cmsghdr = @ptrCast(control[offset..].ptr);
        const control_len: usize = @intCast(header.len);
        if (control_len < @sizeOf(c.cmsghdr) or control_len > control.len - offset) return;
        if (header.level == c.SOL.SOCKET and header.type == c.SCM.RIGHTS) {
            const data = control[offset + @sizeOf(c.cmsghdr) .. offset + control_len];
            var fd_offset: usize = 0;
            while (fd_offset + @sizeOf(c.fd_t) <= data.len) : (fd_offset += @sizeOf(c.fd_t)) {
                const received_fd: *align(1) const c.fd_t = @ptrCast(data[fd_offset..].ptr);
                if (received_fd.* >= 0) _ = c.close(received_fd.*);
            }
        }
        offset += std.mem.alignForward(usize, control_len, @alignOf(c.cmsghdr));
    }
}

/// Event frames are tiny and emitted by PTY reader threads. Never let a slow
/// or dead viewer block one: one nonblocking send either commits the complete
/// frame or the daemon drops that subscription.
pub fn writeFrameNonBlocking(fd: c.fd_t, tag: Tag, payload: []const u8) bool {
    if (payload.len > 244) return false;
    var frame: [256]u8 = undefined;
    @memcpy(frame[0..4], magic);
    std.mem.writeInt(u16, frame[4..6], version, .little);
    std.mem.writeInt(u16, frame[6..8], @intFromEnum(tag), .little);
    std.mem.writeInt(u32, frame[8..12], @intCast(payload.len), .little);
    @memcpy(frame[12..][0..payload.len], payload);
    const len = header_len + payload.len;
    const n = c.send(fd, &frame, len, c.MSG.NOSIGNAL | c.MSG.DONTWAIT);
    return n == len;
}

pub fn readFrame(fd: c.fd_t, alloc: std.mem.Allocator) !Frame {
    return readFrameVersion(fd, version, alloc);
}

/// Read a frame for an explicitly selected attach dialect. Payload codecs
/// remain outside this framing primitive and are selected by the viewer.
pub fn readFrameVersion(fd: c.fd_t, dialect: u16, alloc: std.mem.Allocator) !Frame {
    var header: [header_len]u8 = undefined;
    try readExact(fd, &header);
    if (!std.mem.eql(u8, header[0..4], magic)) return error.InvalidMagic;
    if (std.mem.readInt(u16, header[4..6], .little) != dialect) return error.VersionMismatch;
    const tag = std.enums.fromInt(Tag, std.mem.readInt(u16, header[6..8], .little)) orelse
        return error.UnknownTag;
    const len = std.mem.readInt(u32, header[8..12], .little);
    if (len > max_payload) return error.PayloadTooLarge;
    const payload = try alloc.alloc(u8, len);
    errdefer alloc.free(payload);
    try readExact(fd, payload);
    return .{ .tag = tag, .payload = payload };
}

fn readExact(fd: c.fd_t, out: []u8) !void {
    var rest = out;
    while (rest.len > 0) {
        const n = c.read(fd, rest.ptr, rest.len);
        if (n == 0) return error.EndOfStream;
        if (n < 0) {
            if (c.errno(n) == .INTR) continue;
            return error.ReadFailed;
        }
        rest = rest[@intCast(n)..];
    }
}

fn sendAll(fd: c.fd_t, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = c.send(fd, rest.ptr, rest.len, c.MSG.NOSIGNAL);
        if (n < 0) {
            if (c.errno(n) == .INTR) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        rest = rest[@intCast(n)..];
    }
}

fn encodeColor(enc: *Encoder, color: vt.Color) !void {
    switch (color) {
        .default => {
            try enc.byte(0);
            try enc.int(u24, 0);
        },
        .indexed => |index| {
            try enc.byte(1);
            try enc.byte(index);
            try enc.int(u16, 0);
        },
        .rgb => |rgb| {
            try enc.byte(2);
            try enc.byte(rgb.r);
            try enc.byte(rgb.g);
            try enc.byte(rgb.b);
        },
    }
}

fn decodeColor(dec: *Decoder) !vt.Color {
    const tag = try dec.byte();
    const r = try dec.byte();
    const g = try dec.byte();
    const b = try dec.byte();
    return switch (tag) {
        0 => .default,
        1 => .{ .indexed = r },
        2 => .{ .rgb = .{ .r = r, .g = g, .b = b } },
        else => error.InvalidColor,
    };
}

test "metadata codec rejects trailing input" {
    const alloc = std.testing.allocator;
    var enc = Encoder.init(alloc);
    defer enc.deinit();
    try encodeMetadata(&enc, .{
        .id = 42,
        .title = @constCast("agent"),
        .exited = false,
        .working = true,
        .attention = true,
        .cwd = @constCast("/Users/test/project"),
    });
    try enc.byte(0xff);

    var dec: Decoder = .{ .bytes = enc.slice() };
    var metadata = try decodeMetadata(&dec, alloc);
    defer metadata.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 42), metadata.id);
    try std.testing.expectEqualStrings("agent", metadata.title);
    try std.testing.expect(metadata.working and metadata.attention);
    try std.testing.expectEqualStrings("/Users/test/project", metadata.cwd.?);
    try std.testing.expectError(error.TrailingData, dec.finish());
}

test "display registry codec preserves bounded pairs and rejects duplicate membership" {
    const alloc = std.testing.allocator;
    var enc = Encoder.init(alloc);
    defer enc.deinit();
    const sessions = [_]Metadata{
        .{ .id = 1, .title = @constCast("left"), .exited = false, .working = true, .attention = false },
        .{ .id = 2, .title = @constCast("right"), .exited = false, .working = false, .attention = true },
    };
    const items = [_]DisplayItem{.{ .pair = .{
        .left = 1,
        .right = 2,
        .focused = .right,
        .ratio = 40000,
        .zoomed = true,
    } }};
    try encodeRegistry(&enc, &sessions, &items);
    var dec: Decoder = .{ .bytes = enc.slice() };
    var decoded = try decodeRegistry(&dec, alloc);
    defer decoded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), decoded.sessions.len);
    try std.testing.expectEqual(@as(usize, 1), decoded.display_items.len);
    try std.testing.expectEqual(@as(u64, 2), decoded.display_items[0].pair.focusedId());
    try std.testing.expectEqual(@as(u16, 40000), decoded.display_items[0].pair.ratio);
    try std.testing.expect(decoded.display_items[0].pair.zoomed);

    var invalid = Encoder.init(alloc);
    defer invalid.deinit();
    try invalid.int(u32, 2);
    for (sessions) |metadata| try encodeMetadata(&invalid, metadata);
    try invalid.int(u32, 2);
    try encodeDisplayItem(&invalid, .{ .single = 1 });
    try encodeDisplayItem(&invalid, .{ .pair = .{
        .left = 1,
        .right = 2,
        .focused = .left,
        .ratio = display_registry.default_ratio,
    } });
    var invalid_dec: Decoder = .{ .bytes = invalid.slice() };
    try std.testing.expectError(error.InvalidRegistry, decodeRegistry(&invalid_dec, alloc));
}

test "create request preserves optional absolute cwd" {
    const alloc = std.testing.allocator;
    var enc = Encoder.init(alloc);
    defer enc.deinit();
    try encodeCreateRequest(&enc, .{ .cols = 100, .rows = 28, .cwd = "/Users/test/project" });
    var dec: Decoder = .{ .bytes = enc.slice() };
    const decoded = try decodeCreateRequest(&dec);
    try std.testing.expectEqual(@as(u16, 100), decoded.cols);
    try std.testing.expectEqual(@as(u16, 28), decoded.rows);
    try std.testing.expectEqualStrings("/Users/test/project", decoded.cwd.?);

    var invalid = Encoder.init(alloc);
    defer invalid.deinit();
    try encodeCreateRequest(&invalid, .{ .cols = 80, .rows = 24, .cwd = "relative" });
    var invalid_dec: Decoder = .{ .bytes = invalid.slice() };
    try std.testing.expectError(error.InvalidWorkingDirectory, decodeCreateRequest(&invalid_dec));

    var nul = Encoder.init(alloc);
    defer nul.deinit();
    try encodeCreateRequest(&nul, .{ .cols = 80, .rows = 24, .cwd = "/tmp\x00/hidden" });
    var nul_dec: Decoder = .{ .bytes = nul.slice() };
    try std.testing.expectError(error.InvalidWorkingDirectory, decodeCreateRequest(&nul_dec));
}

test "create beside request preserves target and creation fields" {
    const alloc = std.testing.allocator;
    var enc = Encoder.init(alloc);
    defer enc.deinit();
    try encodeCreateBesideRequest(&enc, .{
        .existing_id = 41,
        .create = .{ .cols = 50, .rows = 30, .cwd = "/tmp/project" },
    });
    var dec: Decoder = .{ .bytes = enc.slice() };
    const decoded = try decodeCreateBesideRequest(&dec);
    try std.testing.expectEqual(@as(u64, 41), decoded.existing_id);
    try std.testing.expectEqual(@as(u16, 50), decoded.create.cols);
    try std.testing.expectEqual(@as(u16, 30), decoded.create.rows);
    try std.testing.expectEqualStrings("/tmp/project", decoded.create.cwd.?);

    var invalid = Encoder.init(alloc);
    defer invalid.deinit();
    try invalid.int(u64, 0);
    try encodeCreateFields(&invalid, .{ .cols = 50, .rows = 30, .cwd = null });
    var invalid_dec: Decoder = .{ .bytes = invalid.slice() };
    try std.testing.expectError(error.InvalidSession, decodeCreateBesideRequest(&invalid_dec));
}

test "mouse event codec validates enums modifiers and trailing data" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    const source: vt.mouse.Event = .{
        .kind = .motion,
        .button = .middle,
        .modifiers = .{ .shift = true, .control = true },
        .col = 42,
        .row = 7,
        .pixel_x = 711,
        .pixel_y = 119,
    };
    try encodeMouseEvent(&enc, source);
    var dec: Decoder = .{ .bytes = enc.slice() };
    const decoded = try decodeMouseEvent(&dec);
    try std.testing.expectEqual(source, decoded);

    var bad = Encoder.init(std.testing.allocator);
    defer bad.deinit();
    try bad.byte(@intFromEnum(vt.mouse.Kind.press));
    try bad.byte(@intFromEnum(vt.mouse.Button.left));
    try bad.byte(0x80);
    try bad.int(u16, 0);
    try bad.int(u16, 0);
    var bad_dec: Decoder = .{ .bytes = bad.slice() };
    try std.testing.expectError(error.InvalidMouseEvent, decodeMouseEvent(&bad_dec));

    var old = Encoder.init(std.testing.allocator);
    defer old.deinit();
    try old.byte(@intFromEnum(vt.mouse.Kind.press));
    try old.byte(@intFromEnum(vt.mouse.Button.left));
    try old.byte(0);
    try old.int(u16, 4);
    try old.int(u16, 2);
    var old_dec: Decoder = .{ .bytes = old.slice() };
    try std.testing.expectError(error.Truncated, decodeMouseEvent(&old_dec));
}

test "key event codec validates tags scalars modifiers and trailing data" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    const source: vt.keyboard.Event = .{
        .code = .codepoint,
        .codepoint = 'c',
        .shifted_codepoint = 'C',
        .base_layout_codepoint = 'x',
        .modifiers = .{ .shift = true, .control = true },
        .action = .repeat,
        .text = "C",
    };
    try encodeKeyEvent(&enc, source);
    var dec: Decoder = .{ .bytes = enc.slice() };
    const decoded = try decodeKeyEvent(&dec);
    try std.testing.expectEqual(source.code, decoded.code);
    try std.testing.expectEqual(source.codepoint, decoded.codepoint);
    try std.testing.expectEqual(source.shifted_codepoint, decoded.shifted_codepoint);
    try std.testing.expectEqual(source.base_layout_codepoint, decoded.base_layout_codepoint);
    try std.testing.expectEqual(source.modifiers, decoded.modifiers);
    try std.testing.expectEqual(source.action, decoded.action);
    try std.testing.expectEqualStrings(source.text, decoded.text);

    var bad = Encoder.init(std.testing.allocator);
    defer bad.deinit();
    try bad.byte(@intFromEnum(vt.keyboard.Code.up));
    try bad.byte(@intFromEnum(vt.keyboard.Action.press));
    try bad.byte(0x80);
    try bad.int(u32, 0);
    var bad_dec: Decoder = .{ .bytes = bad.slice() };
    try std.testing.expectError(error.InvalidKeyEvent, decodeKeyEvent(&bad_dec));

    var bad_scalar = Encoder.init(std.testing.allocator);
    defer bad_scalar.deinit();
    try bad_scalar.byte(@intFromEnum(vt.keyboard.Code.codepoint));
    try bad_scalar.byte(@intFromEnum(vt.keyboard.Action.press));
    try bad_scalar.byte(0);
    try bad_scalar.int(u32, 0x110000);
    try bad_scalar.int(u32, 0);
    try bad_scalar.int(u32, 0);
    try bad_scalar.bytes("");
    var bad_scalar_dec: Decoder = .{ .bytes = bad_scalar.slice() };
    try std.testing.expectError(error.InvalidKeyEvent, decodeKeyEvent(&bad_scalar_dec));

    try std.testing.expectError(error.InvalidKeyEvent, encodeKeyEvent(&enc, .{
        .code = .text,
        .action = .release,
        .text = "x",
    }));
}

test "snapshot codec preserves semantic cells and selection" {
    const alloc = std.testing.allocator;
    const cells = try alloc.alloc(vt.Cell, 3);
    defer alloc.free(cells);
    cells[0] = .{
        .cp = 'A',
        .grapheme_offset = 0,
        .grapheme_len = 1,
        .flags = .{ .bold = true, .underline = true, .content = true },
        .fg = .{ .indexed = 4 },
        .bg = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
        .underline_color = .{ .indexed = 77 },
        .hyperlink_id = 1,
    };
    cells[1] = .{ .cp = 0x6f22, .flags = .{ .wide = true, .content = true } };
    cells[2] = .{ .flags = .{ .wide_spacer = true } };
    const graphemes = try alloc.dupe(u21, &.{0x0301});
    defer alloc.free(graphemes);
    const selected = try alloc.dupe(bool, &.{ true, false, false });
    defer alloc.free(selected);
    var hyperlinks = [_]Hyperlink{.{
        .explicit_id = @constCast("docs"),
        .uri = @constCast("https://example.com/docs"),
    }};
    var images = [_]ImageRef{.{
        .id = 7,
        .generation = 11,
        .width = 4096,
        .height = 4096,
    }};
    var placements = [_]Placement{.{
        .image_id = 7,
        .generation = 11,
        .placement_id = 3,
        .row = 0,
        .col = 2,
        .cell_offset_x = 0,
        .cell_offset_y = 0,
        .source_x = 2,
        .source_y = 3,
        .source_width = 40,
        .source_height = 50,
        .dest_width = 80,
        .dest_height = 100,
        .z = 0,
    }};
    const source: Snapshot = .{
        .id = 9,
        .cols = 3,
        .rows = 1,
        .col = 1,
        .row = 0,
        .viewport_offset = 17,
        .sync_output_epoch = 5,
        .modes = .{ .pointer_shape = .pointer },
        .exited = false,
        .working = true,
        .attention = false,
        .title = @constCast("build"),
        .cells = cells,
        .graphemes = graphemes,
        .hyperlinks = hyperlinks[0..],
        .selected = selected,
        .images = images[0..],
        .placements = placements[0..],
    };

    var enc = Encoder.init(alloc);
    defer enc.deinit();
    try source.encode(&enc);
    // Snapshot size is independent of decoded pixel bytes in protocol v8.
    try std.testing.expect(enc.slice().len < 512);
    var dec: Decoder = .{ .bytes = enc.slice() };
    var decoded = try Snapshot.decode(&dec, alloc);
    defer decoded.deinit(alloc);
    try dec.finish();
    try std.testing.expectEqual(source.id, decoded.id);
    try std.testing.expectEqual(source.viewport_offset, decoded.viewport_offset);
    try std.testing.expectEqual(vt.mouse.PointerShape.pointer, decoded.modes.pointer_shape);
    try std.testing.expectEqual(source.cells[0], decoded.cells[0]);
    try std.testing.expectEqual(source.cells[1], decoded.cells[1]);
    try std.testing.expectEqual(source.cells[2], decoded.cells[2]);
    try std.testing.expectEqualSlices(u21, &.{0x0301}, decoded.viewCellGrapheme(decoded.cells[0]));
    try std.testing.expectEqualStrings("docs", decoded.viewCellHyperlink(decoded.cells[0]).?.explicit_id);
    try std.testing.expectEqualStrings("https://example.com/docs", decoded.viewCellHyperlink(decoded.cells[0]).?.uri);
    try std.testing.expect(decoded.selected[0]);
    try std.testing.expect(!decoded.selected[1]);
    try std.testing.expectEqual(@as(usize, 1), decoded.images.len);
    try std.testing.expectEqual(@as(u32, 7), decoded.images[0].id);
    try std.testing.expectEqual(@as(u64, 11), decoded.images[0].generation);
    try std.testing.expectEqualSlices(Placement, &placements, decoded.placements);

    // The decoder independently rejects a snapshot-local cell id outside the
    // appended table, even if a compromised daemon bypasses Snapshot.encode.
    const corrupted = try alloc.dupe(u8, enc.slice());
    defer alloc.free(corrupted);
    var locator: Decoder = .{ .bytes = corrupted };
    _ = try locator.int(u64);
    inline for (0..4) |_| _ = try locator.int(u16);
    inline for (0..3) |_| _ = try locator.int(u64);
    _ = try locator.byte();
    inline for (0..3) |_| _ = try locator.boolean();
    const title_len = try locator.int(u32);
    _ = try locator.slice(title_len);
    _ = try locator.int(u32);
    const cp_count = try locator.byte();
    var cp_index: u8 = 0;
    while (cp_index < cp_count) : (cp_index += 1) _ = try locator.int(u32);
    _ = try locator.int(u16);
    inline for (0..3) |_| _ = try decodeColor(&locator);
    std.mem.writeInt(u32, corrupted[locator.pos..][0..4], 2, .little);
    var corrupted_dec: Decoder = .{ .bytes = corrupted };
    try std.testing.expectError(error.InvalidSnapshot, Snapshot.decode(&corrupted_dec, alloc));

    const oversized_uri = try alloc.alloc(u8, vt.hyperlink.max_uri_bytes + 1);
    defer alloc.free(oversized_uri);
    @memset(oversized_uri, 'a');
    const valid_uri = hyperlinks[0].uri;
    hyperlinks[0].uri = oversized_uri;
    defer hyperlinks[0].uri = valid_uri;
    var oversized_enc = Encoder.init(alloc);
    defer oversized_enc.deinit();
    try std.testing.expectError(error.InvalidSnapshot, source.encode(&oversized_enc));
    hyperlinks[0].uri = valid_uri;

    var duplicate_hyperlinks = [_]Hyperlink{
        .{ .explicit_id = @constCast("docs"), .uri = @constCast("https://example.com/docs") },
        .{ .explicit_id = @constCast("docs"), .uri = @constCast("https://example.com/docs") },
    };
    cells[1].hyperlink_id = 2;
    cells[2].hyperlink_id = 2;
    defer {
        cells[1].hyperlink_id = 0;
        cells[2].hyperlink_id = 0;
    }
    var duplicate_source = source;
    duplicate_source.hyperlinks = &duplicate_hyperlinks;
    var duplicate_enc = Encoder.init(alloc);
    defer duplicate_enc.deinit();
    try std.testing.expectError(error.InvalidSnapshot, duplicate_source.encode(&duplicate_enc));
}

test "image resource codec validates dimensions and byte count" {
    const alloc = std.testing.allocator;
    var rgba = [_]u8{ 255, 0, 0, 255 };
    const source: Image = .{
        .id = 7,
        .generation = 11,
        .width = 1,
        .height = 1,
        .rgba = &rgba,
    };
    var enc = Encoder.init(alloc);
    defer enc.deinit();
    try encodeImage(&enc, source);
    var dec: Decoder = .{ .bytes = enc.slice() };
    var decoded = try decodeImage(&dec, alloc);
    defer decoded.deinit(alloc);
    try dec.finish();
    try std.testing.expectEqual(source.id, decoded.id);
    try std.testing.expectEqual(source.generation, decoded.generation);
    try std.testing.expectEqual(source.width, decoded.width);
    try std.testing.expectEqual(source.height, decoded.height);
    try std.testing.expectEqualSlices(u8, source.rgba, decoded.rgba);

    var bad = Encoder.init(alloc);
    defer bad.deinit();
    try bad.int(u32, 7);
    try bad.int(u64, 11);
    try bad.int(u32, 2);
    try bad.int(u32, 1);
    try bad.bytes(&rgba);
    var bad_dec: Decoder = .{ .bytes = bad.slice() };
    try std.testing.expectError(error.InvalidImage, decodeImage(&bad_dec, alloc));
}
