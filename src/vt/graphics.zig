//! Pure Kitty graphics protocol state for RFC 0013.
//! The VT parses bounded APC commands and owns cell-anchored placements.
//! Named-medium I/O, base64/zlib decoding, and pixel resources remain
//! host-owned.

const std = @import("std");
pub const unicode = @import("graphics_unicode.zig");
pub const unicode_placeholder = unicode.placeholder;

pub const max_apc_bytes: usize = 8 * 1024;
pub const max_encoded_upload: usize = 32 * 1024 * 1024;
pub const max_placements: usize = 256;
pub const max_parent_depth: usize = 8;
/// Metal's cross-family 2D texture ceiling; hosts reject larger dimensions
/// before a resource can enter an attach snapshot or renderer cache.
pub const max_dimension: u32 = 16_384;

pub const Format = enum(u8) { rgb = 24, rgba = 32, png = 100 };
pub const Compression = enum(u8) { none, zlib };
pub const Medium = enum(u8) { direct, file, temporary, shared, unsupported };

pub const Load = struct {
    query: bool,
    display: bool,
    image_id: u32,
    image_number: u32 = 0,
    placement_id: u32,
    format: Format,
    compression: Compression,
    medium: Medium,
    width: u32,
    height: u32,
    data_size: u32,
    data_offset: u32,
    quiet: u2,
    cursor_no_move: bool,
    z: i32,
    source_x: u32 = 0,
    source_y: u32 = 0,
    source_width: u32 = 0,
    source_height: u32 = 0,
    cell_offset_x: u32 = 0,
    cell_offset_y: u32 = 0,
    columns: u32 = 0,
    rows: u32 = 0,
    virtual: bool = false,
    transient: bool = false,
    parent_image_id: u32 = 0,
    parent_placement_id: u32 = 0,
    parent_offset_x: i32 = 0,
    parent_offset_y: i32 = 0,
    on_alt: bool,
    row_id: u64,
    col: u16,
    encoded: []u8,
};

pub const Put = struct {
    image_id: u32,
    image_number: u32 = 0,
    placement_id: u32,
    quiet: u2,
    cursor_no_move: bool,
    z: i32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
    cell_offset_x: u32,
    cell_offset_y: u32,
    columns: u32,
    rows: u32,
    virtual: bool = false,
    parent_image_id: u32 = 0,
    parent_placement_id: u32 = 0,
    parent_offset_x: i32 = 0,
    parent_offset_y: i32 = 0,
    on_alt: bool,
    row_id: u64,
    col: u16,
};

pub const DeleteSelector = union(enum) {
    all,
    image: struct { image_id: u32, placement_id: u32 },
    newest: struct { image_number: u32, placement_id: u32 },
    cursor,
    animation_frames: struct { image_id: u32, image_number: u32, frame: u32 },
    cell: struct { x: u32, y: u32 },
    cell_z: struct { x: u32, y: u32, z: i32 },
    range: struct { first: u32, last: u32 },
    column: u32,
    row: u32,
    z: i32,
};

pub const Delete = struct {
    selector: DeleteSelector,
    free: bool,
    quiet: u2,
    on_alt: bool,
    view_top_row_id: u64,
    cursor_row_id: u64,
    cursor_col: u16,
};

pub const FrameLoad = struct {
    image_id: u32,
    image_number: u32,
    format: Format,
    compression: Compression,
    medium: Medium,
    width: u32,
    height: u32,
    data_size: u32,
    data_offset: u32,
    quiet: u2,
    x: u32,
    y: u32,
    base_frame: u32,
    edit_frame: u32,
    gap_ms: i32,
    overwrite: bool,
    background_rgba: u32,
    transient: bool,
    encoded: []u8,
};

pub const AnimationState = enum(u2) { unchanged = 0, stopped = 1, loading = 2, running = 3 };

pub const AnimationControl = struct {
    image_id: u32,
    image_number: u32,
    quiet: u2,
    state: AnimationState,
    frame: u32,
    gap_ms: i32,
    current_frame: u32,
    loops: u32,
};

pub const FrameCompose = struct {
    image_id: u32,
    image_number: u32,
    quiet: u2,
    source_frame: u32,
    destination_frame: u32,
    destination_x: u32,
    destination_y: u32,
    width: u32,
    height: u32,
    source_x: u32,
    source_y: u32,
    overwrite: bool,
};

pub const Command = union(enum) {
    load: Load,
    put: Put,
    delete: Delete,
    frame_load: FrameLoad,
    animation: AnimationControl,
    frame_compose: FrameCompose,

    pub fn deinit(self: Command, alloc: std.mem.Allocator) void {
        switch (self) {
            .load => |load| alloc.free(load.encoded),
            .frame_load => |load| alloc.free(load.encoded),
            .put => {},
            .delete => {},
            .animation, .frame_compose => {},
        }
    }
};

pub const Placement = struct {
    internal_id: u64 = 0,
    image_id: u32,
    image_number: u32 = 0,
    placement_id: u32,
    generation: u64,
    image_width: u32 = 0,
    image_height: u32 = 0,
    source_x: u32 = 0,
    source_y: u32 = 0,
    source_width: u32 = 0,
    source_height: u32 = 0,
    cell_offset_x: u32 = 0,
    cell_offset_y: u32 = 0,
    columns: u32 = 0,
    rows: u32 = 0,
    virtual: bool = false,
    parent_internal_id: u64 = 0,
    parent_offset_x: i32 = 0,
    parent_offset_y: i32 = 0,
    on_alt: bool,
    row_id: u64,
    col: u16,
    z: i32,
};

pub const Resource = struct {
    image_id: u32,
    image_number: u32,
    generation: u64,
    width: u32,
    height: u32,
};

pub const Geometry = struct {
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
    dest_width: u32,
    dest_height: u32,
    grid_cols: u32,
    grid_rows: u32,
};

pub const CommitError = error{
    InvalidPlacement,
    PlacementQuota,
    ParentNotFound,
    ParentCycle,
    ParentTooDeep,
};

pub const DeleteResult = struct {
    image_ids: [max_placements]u32 = @splat(0),
    len: usize = 0,
    orphan_image_ids: [max_placements]u32 = @splat(0),
    orphan_len: usize = 0,

    pub fn items(self: *const DeleteResult) []const u32 {
        return self.image_ids[0..self.len];
    }

    fn add(self: *DeleteResult, id: u32) void {
        for (self.items()) |existing| if (existing == id) return;
        if (self.len == self.image_ids.len) return;
        self.image_ids[self.len] = id;
        self.len += 1;
    }

    pub fn orphanItems(self: *const DeleteResult) []const u32 {
        return self.orphan_image_ids[0..self.orphan_len];
    }

    fn addOrphan(self: *DeleteResult, id: u32) void {
        for (self.orphanItems()) |existing| if (existing == id) return;
        if (self.orphan_len == self.orphan_image_ids.len) return;
        self.orphan_image_ids[self.orphan_len] = id;
        self.orphan_len += 1;
    }
};

const Meta = struct {
    query: bool = false,
    display: bool = false,
    image_id: u32 = 0,
    image_number: u32 = 0,
    placement_id: u32 = 0,
    format: Format = .rgba,
    compression: Compression = .none,
    medium: Medium = .direct,
    width: u32 = 0,
    height: u32 = 0,
    data_size: u32 = 0,
    data_offset: u32 = 0,
    quiet: u2 = 0,
    more: bool = false,
    cursor_no_move: bool = false,
    z: i32 = 0,
    source_x: u32 = 0,
    source_y: u32 = 0,
    source_width: u32 = 0,
    source_height: u32 = 0,
    cell_offset_x: u32 = 0,
    cell_offset_y: u32 = 0,
    columns: u32 = 0,
    rows: u32 = 0,
    virtual: bool = false,
    transient: bool = false,
    transient_present: bool = false,
    parent_image_id: u32 = 0,
    parent_placement_id: u32 = 0,
    parent_offset_x: i32 = 0,
    parent_offset_y: i32 = 0,
    frame_load: bool = false,
};

const Upload = struct {
    meta: Meta,
    encoded: std.ArrayList(u8) = .empty,

    fn deinit(self: *Upload, alloc: std.mem.Allocator) void {
        self.encoded.deinit(alloc);
        self.* = undefined;
    }
};

pub const State = struct {
    upload: ?Upload = null,
    placements: std.ArrayList(Placement) = .empty,
    next_placement_id: u64 = 1,
    pending_orphans: DeleteResult = .{},

    pub fn deinit(self: *State, alloc: std.mem.Allocator) void {
        if (self.upload) |*upload| upload.deinit(alloc);
        self.placements.deinit(alloc);
        self.* = .{};
    }

    pub fn reset(self: *State, alloc: std.mem.Allocator) void {
        self.abortUpload(alloc);
        for (self.placements.items) |placement| {
            if (placement.parent_internal_id != 0) self.pending_orphans.addOrphan(placement.image_id);
        }
        self.placements.clearRetainingCapacity();
    }

    pub fn drainPendingOrphans(self: *State) DeleteResult {
        const result = self.pending_orphans;
        self.pending_orphans = .{};
        return result;
    }

    pub fn removeImagePlacements(self: *State, image_id: u32) DeleteResult {
        return self.deleteImage(image_id);
    }

    pub fn consume(
        self: *State,
        alloc: std.mem.Allocator,
        data: []const u8,
        on_alt: bool,
        view_top_row_id: u64,
        row_id: u64,
        col: u16,
    ) ?Command {
        if (data.len == 0 or data[0] != 'G') return null;
        const body = data[1..];
        const semicolon = std.mem.indexOfScalar(u8, body, ';');
        const controls = if (semicolon) |at| body[0..at] else body;
        const payload = if (semicolon) |at| body[at + 1 ..] else &.{};

        // A continuation contains only m=<0|1>. Any other control list starts
        // a new command and aborts an unfinished transfer, per the protocol.
        if (parseContinuation(controls)) |continuation| {
            if (self.upload) |*upload| {
                if (upload.meta.frame_load != continuation.frame_load) {
                    self.abortUpload(alloc);
                    return null;
                }
                if (continuation.quiet) |quiet| upload.meta.quiet = quiet;
                if (!appendBounded(&upload.encoded, alloc, payload)) {
                    self.abortUpload(alloc);
                    return null;
                }
                if (continuation.more) return null;
                var complete = self.upload.?;
                self.upload = null;
                return finishUpload(alloc, &complete, on_alt, row_id, col);
            }
            return null;
        }

        self.abortUpload(alloc);
        const parsed = parseControls(controls) orelse return null;
        if (parsed.delete) |delete| {
            return .{ .delete = .{
                .selector = delete.selector,
                .free = delete.free,
                .quiet = delete.quiet,
                .on_alt = on_alt,
                .view_top_row_id = view_top_row_id,
                .cursor_row_id = row_id,
                .cursor_col = col,
            } };
        }
        if (parsed.put) {
            return .{ .put = putFromMeta(parsed.meta, on_alt, row_id, col) };
        }
        if (parsed.animation) return .{ .animation = animationFromMeta(parsed.meta) };
        if (parsed.frame_compose) return .{ .frame_compose = composeFromMeta(parsed.meta) };
        var upload: Upload = .{ .meta = parsed.meta };
        if (!appendBounded(&upload.encoded, alloc, payload)) {
            upload.deinit(alloc);
            return null;
        }
        // Chunking applies only to direct payload data. Local media carry a
        // single base64-encoded name; the published protocol says to ignore
        // m for file, temporary-file, and shared-memory references.
        if (upload.meta.more and upload.meta.medium == .direct) {
            self.upload = upload;
            return null;
        }
        return finishUpload(alloc, &upload, on_alt, row_id, col);
    }

    pub fn commitLoad(
        self: *State,
        alloc: std.mem.Allocator,
        load: *const Load,
        resource: Resource,
        pixel_width: u32,
        pixel_height: u32,
        terminal_cols: u16,
        terminal_rows: u16,
    ) CommitError!?Geometry {
        _ = self.deleteImage(resource.image_id);
        if (!load.display) return null;
        const put = putFromLoad(load);
        return try self.commitPut(alloc, &put, resource, pixel_width, pixel_height, terminal_cols, terminal_rows);
    }

    pub fn commitPut(
        self: *State,
        alloc: std.mem.Allocator,
        put: *const Put,
        resource: Resource,
        pixel_width: u32,
        pixel_height: u32,
        terminal_cols: u16,
        terminal_rows: u16,
    ) CommitError!Geometry {
        const geometry = if (put.virtual)
            try geometryForVirtual(put, resource, pixel_width, pixel_height, terminal_cols, terminal_rows)
        else
            try geometryForPut(put, resource, pixel_width, pixel_height, terminal_cols, terminal_rows);
        const replace_index = if (put.placement_id != 0)
            self.namedPlacementIndex(resource.image_id, put.placement_id)
        else
            null;
        const internal_id = if (replace_index) |index|
            self.placements.items[index].internal_id
        else
            self.allocatePlacementId() orelse return error.PlacementQuota;
        const parent_internal_id = try self.resolveParent(put, internal_id);
        const placement = placementFromPut(put, resource, internal_id, parent_internal_id);
        if (replace_index) |index| {
            self.placements.items[index] = placement;
        } else {
            if (self.placements.items.len >= max_placements) return error.PlacementQuota;
            self.placements.append(alloc, placement) catch return error.PlacementQuota;
        }
        return geometry;
    }

    pub fn clearScreen(self: *State, on_alt: bool) void {
        var removed: DeleteResult = .{};
        var write: usize = 0;
        for (self.placements.items) |placement| {
            if (placement.virtual) {
                self.placements.items[write] = placement;
                write += 1;
                continue;
            }
            if (placement.on_alt == on_alt) {
                removed.add(placement.image_id);
                continue;
            }
            self.placements.items[write] = placement;
            write += 1;
        }
        self.placements.items.len = write;
        self.cascadeMissingParents(&removed);
        self.rememberOrphans(removed);
    }

    pub fn prunePrimary(self: *State, base_id: u64) void {
        var removed: DeleteResult = .{};
        var write: usize = 0;
        for (self.placements.items) |placement| {
            if (placement.virtual) {
                self.placements.items[write] = placement;
                write += 1;
                continue;
            }
            if (!placement.on_alt and placement.row_id < base_id) {
                removed.add(placement.image_id);
                continue;
            }
            self.placements.items[write] = placement;
            write += 1;
        }
        self.placements.items.len = write;
        self.cascadeMissingParents(&removed);
        self.rememberOrphans(removed);
    }

    pub fn scrollAlt(self: *State, top: u16, bottom: u16, amount: u16, up: bool) void {
        var removed: DeleteResult = .{};
        var write: usize = 0;
        for (self.placements.items) |source| {
            var placement = source;
            if (placement.virtual) {
                self.placements.items[write] = placement;
                write += 1;
                continue;
            }
            if (placement.on_alt and placement.row_id >= top and placement.row_id <= bottom) {
                if (up) {
                    if (placement.row_id < @as(u64, top) + amount) {
                        removed.add(placement.image_id);
                        continue;
                    }
                    placement.row_id -= amount;
                } else {
                    if (placement.row_id + amount > bottom) {
                        removed.add(placement.image_id);
                        continue;
                    }
                    placement.row_id += amount;
                }
            }
            self.placements.items[write] = placement;
            write += 1;
        }
        self.placements.items.len = write;
        self.cascadeMissingParents(&removed);
        self.rememberOrphans(removed);
    }

    fn abortUpload(self: *State, alloc: std.mem.Allocator) void {
        if (self.upload) |*upload| upload.deinit(alloc);
        self.upload = null;
    }

    pub fn applyDelete(
        self: *State,
        delete: Delete,
        resolved_image_id: ?u32,
        pixel_width: u32,
        pixel_height: u32,
        terminal_cols: u16,
        terminal_rows: u16,
    ) DeleteResult {
        var result: DeleteResult = .{};
        var write: usize = 0;
        for (self.placements.items) |placement| {
            if (matchesDelete(
                placement,
                delete,
                resolved_image_id,
                pixel_width,
                pixel_height,
                terminal_cols,
                terminal_rows,
            )) {
                result.add(placement.image_id);
                continue;
            }
            self.placements.items[write] = placement;
            write += 1;
        }
        self.placements.items.len = write;
        self.cascadeMissingParents(&result);
        self.rememberOrphans(result);
        return result;
    }

    fn deleteImage(self: *State, image_id: u32) DeleteResult {
        var removed: DeleteResult = .{};
        var write: usize = 0;
        for (self.placements.items) |placement| {
            if (placement.image_id == image_id) {
                removed.add(placement.image_id);
                continue;
            }
            self.placements.items[write] = placement;
            write += 1;
        }
        self.placements.items.len = write;
        self.cascadeMissingParents(&removed);
        self.rememberOrphans(removed);
        return removed;
    }

    fn namedPlacementIndex(self: *const State, image_id: u32, placement_id: u32) ?usize {
        for (self.placements.items, 0..) |placement, index| {
            if (placement.image_id == image_id and placement.placement_id == placement_id)
                return index;
        }
        return null;
    }

    fn allocatePlacementId(self: *State) ?u64 {
        var attempts: usize = 0;
        while (attempts <= max_placements) : (attempts += 1) {
            const candidate = self.next_placement_id;
            self.next_placement_id +%= 1;
            if (self.next_placement_id == 0) self.next_placement_id = 1;
            if (candidate != 0 and self.placementByInternalId(candidate) == null) return candidate;
        }
        return null;
    }

    fn placementByInternalId(self: *const State, internal_id: u64) ?*const Placement {
        for (self.placements.items) |*placement| {
            if (placement.internal_id == internal_id) return placement;
        }
        return null;
    }

    fn resolveParent(self: *const State, put: *const Put, child_internal_id: u64) CommitError!u64 {
        if (put.parent_image_id == 0) return 0;
        if (put.virtual) return error.InvalidPlacement;
        var parent: ?*const Placement = null;
        for (self.placements.items) |*candidate| {
            if (candidate.image_id != put.parent_image_id) continue;
            if (put.parent_placement_id == 0 or candidate.placement_id == put.parent_placement_id) {
                parent = candidate;
                break;
            }
        }
        var current = parent orelse return error.ParentNotFound;
        var depth: usize = 1;
        while (true) {
            if (current.internal_id == child_internal_id) return error.ParentCycle;
            if (current.parent_internal_id == 0) break;
            if (depth >= max_parent_depth) return error.ParentTooDeep;
            current = self.placementByInternalId(current.parent_internal_id) orelse
                return error.ParentNotFound;
            depth += 1;
        }
        return parent.?.internal_id;
    }

    fn cascadeMissingParents(self: *State, result: *DeleteResult) void {
        var changed = true;
        while (changed) {
            changed = false;
            var write: usize = 0;
            for (self.placements.items) |placement| {
                if (placement.parent_internal_id != 0 and
                    self.placementByInternalId(placement.parent_internal_id) == null)
                {
                    result.add(placement.image_id);
                    result.addOrphan(placement.image_id);
                    changed = true;
                    continue;
                }
                self.placements.items[write] = placement;
                write += 1;
            }
            self.placements.items.len = write;
        }
        var orphan_write: usize = 0;
        for (result.orphanItems()) |image_id| {
            var still_placed = false;
            for (self.placements.items) |placement| {
                if (placement.image_id == image_id) {
                    still_placed = true;
                    break;
                }
            }
            if (still_placed) continue;
            result.orphan_image_ids[orphan_write] = image_id;
            orphan_write += 1;
        }
        result.orphan_len = orphan_write;
    }

    fn rememberOrphans(self: *State, result: DeleteResult) void {
        for (result.orphanItems()) |id| self.pending_orphans.addOrphan(id);
    }

    /// Resolve the exact named virtual prototype, or the oldest virtual
    /// prototype for an image when the placeholder omitted a placement id.
    pub fn virtualPlacement(
        self: *const State,
        image_id: u32,
        placement_id: u32,
        on_alt: bool,
    ) ?Placement {
        for (self.placements.items) |placement| {
            if (!placement.virtual or placement.on_alt != on_alt or placement.image_id != image_id)
                continue;
            if (placement_id == 0 or placement.placement_id == placement_id) return placement;
        }
        return null;
    }
};

const DeleteRequest = struct { selector: DeleteSelector, free: bool, quiet: u2 };
const Parsed = struct {
    meta: Meta,
    put: bool = false,
    delete: ?DeleteRequest = null,
    animation: bool = false,
    frame_compose: bool = false,
};

fn parseControls(controls: []const u8) ?Parsed {
    var meta: Meta = .{};
    var action: u8 = 't';
    var delete_selector: u8 = 'a';
    var seen: u64 = 0;
    var it = std.mem.splitScalar(u8, controls, ',');
    while (it.next()) |pair| {
        if (pair.len < 3 or pair[1] != '=') return null;
        const key = pair[0];
        const bit = keyBit(key) orelse return null;
        if (seen & bit != 0) return null;
        seen |= bit;
        const value = pair[2..];
        switch (key) {
            'a' => {
                if (value.len != 1) return null;
                action = value[0];
            },
            'd' => {
                if (value.len != 1) return null;
                delete_selector = value[0];
            },
            'f' => meta.format = switch (parseUnsigned(value) orelse return null) {
                24 => .rgb,
                32 => .rgba,
                100 => .png,
                else => return null,
            },
            'o' => if (std.mem.eql(u8, value, "z")) {
                meta.compression = .zlib;
            } else return null,
            't' => meta.medium = if (value.len == 1) switch (value[0]) {
                'd' => .direct,
                'f' => .file,
                't' => .temporary,
                's' => .shared,
                else => .unsupported,
            } else .unsupported,
            's' => meta.width = parseUnsigned(value) orelse return null,
            'v' => meta.height = parseUnsigned(value) orelse return null,
            'S' => meta.data_size = parseUnsigned(value) orelse return null,
            'O' => meta.data_offset = parseUnsigned(value) orelse return null,
            'i' => meta.image_id = parseUnsigned(value) orelse return null,
            'I' => meta.image_number = parseUnsigned(value) orelse return null,
            'p' => meta.placement_id = parseUnsigned(value) orelse return null,
            'q' => {
                const quiet = parseUnsigned(value) orelse return null;
                if (quiet > 2) return null;
                meta.quiet = @intCast(quiet);
            },
            'm' => {
                const more = parseUnsigned(value) orelse return null;
                if (more > 1) return null;
                meta.more = more == 1;
            },
            'C' => {
                const policy = parseUnsigned(value) orelse return null;
                if (policy > 1) return null;
                meta.cursor_no_move = policy == 1;
            },
            'z' => meta.z = parseSigned(value) orelse return null,
            'x' => meta.source_x = parseUnsigned(value) orelse return null,
            'y' => meta.source_y = parseUnsigned(value) orelse return null,
            'w' => meta.source_width = parseUnsigned(value) orelse return null,
            'h' => meta.source_height = parseUnsigned(value) orelse return null,
            'X' => meta.cell_offset_x = parseUnsigned(value) orelse return null,
            'Y' => meta.cell_offset_y = parseUnsigned(value) orelse return null,
            'c' => meta.columns = parseUnsigned(value) orelse return null,
            'r' => meta.rows = parseUnsigned(value) orelse return null,
            'U' => {
                const virtual = parseUnsigned(value) orelse return null;
                if (virtual > 1) return null;
                meta.virtual = virtual == 1;
            },
            'N' => {
                meta.transient = (parseUnsigned(value) orelse return null) & 1 != 0;
                meta.transient_present = true;
            },
            'P' => meta.parent_image_id = parseUnsigned(value) orelse return null,
            'Q' => meta.parent_placement_id = parseUnsigned(value) orelse return null,
            'H' => meta.parent_offset_x = parseSigned(value) orelse return null,
            'V' => meta.parent_offset_y = parseSigned(value) orelse return null,
            else => return null,
        }
    }

    return switch (action) {
        'q' => blk: {
            meta.query = true;
            break :blk .{ .meta = meta };
        },
        'T' => blk: {
            meta.display = true;
            break :blk .{ .meta = meta };
        },
        't' => .{ .meta = meta },
        'p' => if (!meta.transient_present) .{ .meta = meta, .put = true } else null,
        'd' => parseDelete(meta, delete_selector),
        'f' => blk: {
            if (meta.cell_offset_x > 1) return null;
            meta.frame_load = true;
            break :blk .{ .meta = meta };
        },
        'a' => if (!meta.transient_present and meta.width <= 3)
            .{ .meta = meta, .animation = true }
        else
            null,
        'c' => if (!meta.transient_present) .{ .meta = meta, .frame_compose = true } else null,
        else => null,
    };
}

fn parseDelete(meta: Meta, selector: u8) ?Parsed {
    if (meta.transient_present) return null;
    const free = selector >= 'A' and selector <= 'Z';
    const normalized = if (free) selector + ('a' - 'A') else selector;
    const value: DeleteSelector = switch (normalized) {
        'a' => .all,
        'i' => if (meta.image_id != 0)
            .{ .image = .{ .image_id = meta.image_id, .placement_id = meta.placement_id } }
        else
            return null,
        'n' => if (meta.image_number != 0)
            .{ .newest = .{ .image_number = meta.image_number, .placement_id = meta.placement_id } }
        else
            return null,
        'c' => .cursor,
        'f' => if ((meta.image_id != 0) != (meta.image_number != 0))
            .{ .animation_frames = .{
                .image_id = meta.image_id,
                .image_number = meta.image_number,
                .frame = meta.rows,
            } }
        else
            return null,
        'p' => if (meta.source_x != 0 and meta.source_y != 0)
            .{ .cell = .{ .x = meta.source_x, .y = meta.source_y } }
        else
            return null,
        'q' => if (meta.source_x != 0 and meta.source_y != 0)
            .{ .cell_z = .{ .x = meta.source_x, .y = meta.source_y, .z = meta.z } }
        else
            return null,
        'r' => if (meta.source_x != 0 and meta.source_y != 0 and meta.source_x <= meta.source_y)
            .{ .range = .{ .first = meta.source_x, .last = meta.source_y } }
        else
            return null,
        'x' => if (meta.source_x != 0) .{ .column = meta.source_x } else return null,
        'y' => if (meta.source_y != 0) .{ .row = meta.source_y } else return null,
        'z' => .{ .z = meta.z },
        else => return null,
    };
    return .{ .meta = meta, .delete = .{ .selector = value, .free = free, .quiet = meta.quiet } };
}

fn finishUpload(
    alloc: std.mem.Allocator,
    upload: *Upload,
    on_alt: bool,
    row_id: u64,
    col: u16,
) ?Command {
    const encoded = upload.encoded.toOwnedSlice(alloc) catch {
        upload.deinit(alloc);
        return null;
    };
    const meta = upload.meta;
    upload.* = undefined;
    if (meta.frame_load) return .{ .frame_load = .{
        .image_id = meta.image_id,
        .image_number = meta.image_number,
        .format = meta.format,
        .compression = meta.compression,
        .medium = meta.medium,
        .width = meta.width,
        .height = meta.height,
        .data_size = meta.data_size,
        .data_offset = meta.data_offset,
        .quiet = meta.quiet,
        .x = meta.source_x,
        .y = meta.source_y,
        .base_frame = meta.columns,
        .edit_frame = meta.rows,
        .gap_ms = meta.z,
        .overwrite = meta.cell_offset_x == 1,
        .background_rgba = meta.cell_offset_y,
        .transient = meta.transient,
        .encoded = encoded,
    } };
    return .{ .load = .{
        .query = meta.query,
        .display = meta.display,
        .image_id = meta.image_id,
        .image_number = meta.image_number,
        .placement_id = meta.placement_id,
        .format = meta.format,
        .compression = meta.compression,
        .medium = meta.medium,
        .width = meta.width,
        .height = meta.height,
        .data_size = meta.data_size,
        .data_offset = meta.data_offset,
        .quiet = meta.quiet,
        .cursor_no_move = meta.cursor_no_move,
        .z = meta.z,
        .source_x = meta.source_x,
        .source_y = meta.source_y,
        .source_width = meta.source_width,
        .source_height = meta.source_height,
        .cell_offset_x = meta.cell_offset_x,
        .cell_offset_y = meta.cell_offset_y,
        .columns = meta.columns,
        .rows = meta.rows,
        .virtual = meta.virtual,
        .transient = meta.transient,
        .parent_image_id = meta.parent_image_id,
        .parent_placement_id = meta.parent_placement_id,
        .parent_offset_x = meta.parent_offset_x,
        .parent_offset_y = meta.parent_offset_y,
        .on_alt = on_alt,
        .row_id = row_id,
        .col = col,
        .encoded = encoded,
    } };
}

fn animationFromMeta(meta: Meta) AnimationControl {
    return .{
        .image_id = meta.image_id,
        .image_number = meta.image_number,
        .quiet = meta.quiet,
        .state = @enumFromInt(@min(meta.width, 3)),
        .frame = meta.rows,
        .gap_ms = meta.z,
        .current_frame = meta.columns,
        .loops = meta.height,
    };
}

fn composeFromMeta(meta: Meta) FrameCompose {
    return .{
        .image_id = meta.image_id,
        .image_number = meta.image_number,
        .quiet = meta.quiet,
        .source_frame = meta.rows,
        .destination_frame = meta.columns,
        .destination_x = meta.source_x,
        .destination_y = meta.source_y,
        .width = meta.source_width,
        .height = meta.source_height,
        .source_x = meta.cell_offset_x,
        .source_y = meta.cell_offset_y,
        .overwrite = meta.cursor_no_move,
    };
}

fn putFromMeta(meta: Meta, on_alt: bool, row_id: u64, col: u16) Put {
    return .{
        .image_id = meta.image_id,
        .image_number = meta.image_number,
        .placement_id = meta.placement_id,
        .quiet = meta.quiet,
        .cursor_no_move = meta.cursor_no_move,
        .z = meta.z,
        .source_x = meta.source_x,
        .source_y = meta.source_y,
        .source_width = meta.source_width,
        .source_height = meta.source_height,
        .cell_offset_x = meta.cell_offset_x,
        .cell_offset_y = meta.cell_offset_y,
        .columns = meta.columns,
        .rows = meta.rows,
        .virtual = meta.virtual,
        .parent_image_id = meta.parent_image_id,
        .parent_placement_id = meta.parent_placement_id,
        .parent_offset_x = meta.parent_offset_x,
        .parent_offset_y = meta.parent_offset_y,
        .on_alt = on_alt,
        .row_id = row_id,
        .col = col,
    };
}

fn putFromLoad(load: *const Load) Put {
    return .{
        .image_id = load.image_id,
        .image_number = load.image_number,
        .placement_id = load.placement_id,
        .quiet = load.quiet,
        .cursor_no_move = load.cursor_no_move,
        .z = load.z,
        .source_x = load.source_x,
        .source_y = load.source_y,
        .source_width = load.source_width,
        .source_height = load.source_height,
        .cell_offset_x = load.cell_offset_x,
        .cell_offset_y = load.cell_offset_y,
        .columns = load.columns,
        .rows = load.rows,
        .virtual = load.virtual,
        .parent_image_id = load.parent_image_id,
        .parent_placement_id = load.parent_placement_id,
        .parent_offset_x = load.parent_offset_x,
        .parent_offset_y = load.parent_offset_y,
        .on_alt = load.on_alt,
        .row_id = load.row_id,
        .col = load.col,
    };
}

fn placementFromPut(
    put: *const Put,
    resource: Resource,
    internal_id: u64,
    parent_internal_id: u64,
) Placement {
    return .{
        .internal_id = internal_id,
        .image_id = resource.image_id,
        .image_number = resource.image_number,
        .placement_id = put.placement_id,
        .generation = resource.generation,
        .image_width = resource.width,
        .image_height = resource.height,
        .source_x = put.source_x,
        .source_y = put.source_y,
        .source_width = put.source_width,
        .source_height = put.source_height,
        .cell_offset_x = put.cell_offset_x,
        .cell_offset_y = put.cell_offset_y,
        .columns = put.columns,
        .rows = put.rows,
        .virtual = put.virtual,
        .parent_internal_id = parent_internal_id,
        .parent_offset_x = if (parent_internal_id != 0) put.parent_offset_x else 0,
        .parent_offset_y = if (parent_internal_id != 0) put.parent_offset_y else 0,
        .on_alt = put.on_alt,
        .row_id = put.row_id,
        .col = put.col,
        .z = put.z,
    };
}

fn geometryForPut(
    put: *const Put,
    resource: Resource,
    pixel_width: u32,
    pixel_height: u32,
    terminal_cols: u16,
    terminal_rows: u16,
) CommitError!Geometry {
    return placementGeometry(
        placementFromPut(put, resource, 0, 0),
        pixel_width,
        pixel_height,
        terminal_cols,
        terminal_rows,
    );
}

fn geometryForVirtual(
    put: *const Put,
    resource: Resource,
    pixel_width: u32,
    pixel_height: u32,
    terminal_cols: u16,
    terminal_rows: u16,
) CommitError!Geometry {
    if (terminal_cols == 0 or terminal_rows == 0 or
        pixel_width < terminal_cols or pixel_height < terminal_rows or
        resource.width == 0 or resource.height == 0)
        return error.InvalidPlacement;
    const cell_width = pixel_width / terminal_cols;
    const cell_height = pixel_height / terminal_rows;
    if (cell_width == 0 or cell_height == 0) return error.InvalidPlacement;
    return .{
        .source_x = 0,
        .source_y = 0,
        .source_width = resource.width,
        .source_height = resource.height,
        .dest_width = resource.width,
        .dest_height = resource.height,
        .grid_cols = if (put.columns != 0) put.columns else ceilDiv(resource.width, cell_width),
        .grid_rows = if (put.rows != 0) put.rows else ceilDiv(resource.height, cell_height),
    };
}

/// Compute renderer/cell geometry from immutable placement controls. The
/// integer rules mirror the published protocol and Ghostty's independent MIT
/// implementation, with saturating intermediates for hostile control values.
pub fn placementGeometry(
    placement: Placement,
    pixel_width: u32,
    pixel_height: u32,
    terminal_cols: u16,
    terminal_rows: u16,
) CommitError!Geometry {
    if (terminal_cols == 0 or terminal_rows == 0 or
        pixel_width < terminal_cols or pixel_height < terminal_rows)
        return error.InvalidPlacement;
    const cell_width = pixel_width / terminal_cols;
    const cell_height = pixel_height / terminal_rows;
    if (cell_width == 0 or cell_height == 0 or
        placement.cell_offset_x >= cell_width or placement.cell_offset_y >= cell_height)
        return error.InvalidPlacement;

    const source_x = @min(placement.source_x, placement.image_width);
    const source_y = @min(placement.source_y, placement.image_height);
    const available_width = placement.image_width - source_x;
    const available_height = placement.image_height - source_y;
    const source_width = @min(
        if (placement.source_width == 0) available_width else placement.source_width,
        available_width,
    );
    const source_height = @min(
        if (placement.source_height == 0) available_height else placement.source_height,
        available_height,
    );

    var dest_width = source_width;
    var dest_height = source_height;
    if (placement.columns != 0 and placement.rows != 0) {
        dest_width = std.math.mul(u32, cell_width, placement.columns) catch std.math.maxInt(u32);
        dest_height = std.math.mul(u32, cell_height, placement.rows) catch std.math.maxInt(u32);
    } else if (placement.columns != 0) {
        dest_width = std.math.mul(u32, cell_width, placement.columns) catch std.math.maxInt(u32);
        dest_height = scaleDimension(dest_width, source_height, source_width);
    } else if (placement.rows != 0) {
        dest_height = std.math.mul(u32, cell_height, placement.rows) catch std.math.maxInt(u32);
        dest_width = scaleDimension(dest_height, source_width, source_height);
    }

    const grid_cols = if (placement.columns != 0 and placement.rows != 0)
        placement.columns
    else
        ceilDiv(dest_width +| placement.cell_offset_x, cell_width);
    const grid_rows = if (placement.columns != 0 and placement.rows != 0)
        placement.rows
    else
        ceilDiv(dest_height +| placement.cell_offset_y, cell_height);
    return .{
        .source_x = source_x,
        .source_y = source_y,
        .source_width = source_width,
        .source_height = source_height,
        .dest_width = dest_width,
        .dest_height = dest_height,
        .grid_cols = grid_cols,
        .grid_rows = grid_rows,
    };
}

fn scaleDimension(value: u32, numerator: u32, denominator: u32) u32 {
    if (denominator == 0) return 0;
    const rounded = (@as(u64, value) * numerator + denominator / 2) / denominator;
    return std.math.cast(u32, rounded) orelse std.math.maxInt(u32);
}

fn ceilDiv(value: u32, divisor: u32) u32 {
    if (value == 0 or divisor == 0) return 0;
    return 1 + (value - 1) / divisor;
}

fn matchesDelete(
    placement: Placement,
    delete: Delete,
    resolved_image_id: ?u32,
    pixel_width: u32,
    pixel_height: u32,
    terminal_cols: u16,
    terminal_rows: u16,
) bool {
    switch (delete.selector) {
        .image => |target| return placement.image_id == target.image_id and
            (target.placement_id == 0 or placement.placement_id == target.placement_id),
        .newest => |target| return resolved_image_id != null and
            placement.image_id == resolved_image_id.? and
            (target.placement_id == 0 or placement.placement_id == target.placement_id),
        .range => |target| return placement.image_id >= target.first and placement.image_id <= target.last,
        .animation_frames => return false,
        else => {},
    }
    if (placement.virtual) return false;
    if (placement.on_alt != delete.on_alt) return false;
    const geometry = placementGeometry(
        placement,
        pixel_width,
        pixel_height,
        terminal_cols,
        terminal_rows,
    ) catch return false;
    if (geometry.grid_cols == 0 or geometry.grid_rows == 0) return false;
    const last_col = @as(u64, placement.col) + geometry.grid_cols - 1;
    const last_row = placement.row_id +| geometry.grid_rows - 1;

    return switch (delete.selector) {
        .all => blk: {
            const view_last = delete.view_top_row_id +| terminal_rows - 1;
            break :blk last_row >= delete.view_top_row_id and placement.row_id <= view_last and
                placement.col < terminal_cols;
        },
        .cursor => pointInside(placement, last_col, last_row, delete.cursor_col, delete.cursor_row_id),
        .cell => |cell| pointInside(
            placement,
            last_col,
            last_row,
            cell.x - 1,
            delete.view_top_row_id +| cell.y - 1,
        ),
        .cell_z => |cell| placement.z == cell.z and pointInside(
            placement,
            last_col,
            last_row,
            cell.x - 1,
            delete.view_top_row_id +| cell.y - 1,
        ),
        .column => |column| @as(u64, column - 1) >= placement.col and @as(u64, column - 1) <= last_col,
        .row => |row| delete.view_top_row_id +| row - 1 >= placement.row_id and
            delete.view_top_row_id +| row - 1 <= last_row,
        .z => |z| placement.z == z,
        .image, .newest, .range, .animation_frames => unreachable,
    };
}

fn pointInside(placement: Placement, last_col: u64, last_row: u64, col: u64, row_id: u64) bool {
    return col >= placement.col and col <= last_col and row_id >= placement.row_id and row_id <= last_row;
}

fn appendBounded(list: *std.ArrayList(u8), alloc: std.mem.Allocator, bytes: []const u8) bool {
    if (bytes.len > max_encoded_upload - list.items.len) return false;
    list.appendSlice(alloc, bytes) catch return false;
    return true;
}

const Continuation = struct { more: bool, frame_load: bool = false, quiet: ?u2 = null };

fn parseContinuation(controls: []const u8) ?Continuation {
    var result: Continuation = .{ .more = false };
    var saw_more = false;
    var saw_action = false;
    var saw_quiet = false;
    var it = std.mem.splitScalar(u8, controls, ',');
    while (it.next()) |pair| {
        if (pair.len < 3 or pair[1] != '=') return null;
        switch (pair[0]) {
            'a' => {
                if (saw_action or !std.mem.eql(u8, pair[2..], "f")) return null;
                saw_action = true;
                result.frame_load = true;
            },
            'm' => {
                if (saw_more or pair.len != 3) return null;
                result.more = switch (pair[2]) {
                    '0' => false,
                    '1' => true,
                    else => return null,
                };
                saw_more = true;
            },
            'q' => {
                if (saw_quiet) return null;
                const value = parseUnsigned(pair[2..]) orelse return null;
                if (value > 2) return null;
                result.quiet = @intCast(value);
                saw_quiet = true;
            },
            else => return null,
        }
    }
    return if (saw_more) result else null;
}

fn parseUnsigned(bytes: []const u8) ?u32 {
    if (bytes.len == 0) return null;
    return std.fmt.parseInt(u32, bytes, 10) catch null;
}

fn parseSigned(bytes: []const u8) ?i32 {
    if (bytes.len == 0) return null;
    return std.fmt.parseInt(i32, bytes, 10) catch null;
}

fn keyBit(key: u8) ?u64 {
    return switch (key) {
        'a' => 1 << 0,
        'd' => 1 << 1,
        'f' => 1 << 2,
        'o' => 1 << 3,
        't' => 1 << 4,
        's' => 1 << 5,
        'v' => 1 << 6,
        'i' => 1 << 7,
        'p' => 1 << 8,
        'q' => 1 << 9,
        'm' => 1 << 10,
        'C' => 1 << 11,
        'z' => 1 << 12,
        'S' => 1 << 13,
        'O' => 1 << 14,
        'I' => 1 << 15,
        'x' => 1 << 16,
        'y' => 1 << 17,
        'w' => 1 << 18,
        'h' => 1 << 19,
        'X' => 1 << 20,
        'Y' => 1 << 21,
        'c' => 1 << 22,
        'r' => 1 << 23,
        'U' => 1 << 24,
        'N' => 1 << 25,
        'P' => 1 << 26,
        'Q' => 1 << 27,
        'H' => 1 << 28,
        'V' => 1 << 29,
        else => null,
    };
}

test "terminal-browser direct upload is assembled across APC chunks" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    try std.testing.expect(state.consume(
        alloc,
        "Ga=T,f=32,o=z,s=1,v=1,t=d,i=7,p=1,C=1,q=2,m=1;eJ",
        true,
        0,
        3,
        4,
    ) == null);
    const command = state.consume(alloc, "Gm=0;xjYGBgAAAABAAB", true, 0, 9, 6) orelse
        return error.TestExpectedEqual;
    defer command.deinit(alloc);
    const load = command.load;
    try std.testing.expectEqual(@as(u32, 7), load.image_id);
    try std.testing.expectEqual(@as(u32, 1), load.placement_id);
    try std.testing.expect(load.cursor_no_move);
    try std.testing.expectEqual(@as(u32, 0), load.data_size);
    try std.testing.expectEqual(@as(u32, 0), load.data_offset);
    try std.testing.expectEqual(@as(u64, 9), load.row_id);
    try std.testing.expectEqualStrings("eJxjYGBgAAAABAAB", load.encoded);
}

test "animation commands preserve published control-key meanings" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    const frame_command = state.consume(
        alloc,
        "Ga=f,i=9,f=32,s=1,v=1,x=2,y=3,c=4,r=5,z=-1,X=1,Y=4278190335,N=1;AAAAAA==",
        false,
        0,
        0,
        0,
    ) orelse return error.TestExpectedEqual;
    defer frame_command.deinit(alloc);
    const frame = frame_command.frame_load;
    try std.testing.expectEqual(@as(u32, 9), frame.image_id);
    try std.testing.expectEqual(@as(u32, 4), frame.base_frame);
    try std.testing.expectEqual(@as(u32, 5), frame.edit_frame);
    try std.testing.expectEqual(@as(i32, -1), frame.gap_ms);
    try std.testing.expect(frame.overwrite);
    try std.testing.expect(frame.transient);
    try std.testing.expectEqual(@as(u32, 4_278_190_335), frame.background_rgba);

    const animation_command = state.consume(
        alloc,
        "Ga=a,I=7,s=3,r=2,z=48,c=3,v=4",
        false,
        0,
        0,
        0,
    ) orelse return error.TestExpectedEqual;
    defer animation_command.deinit(alloc);
    const animation = animation_command.animation;
    try std.testing.expectEqual(AnimationState.running, animation.state);
    try std.testing.expectEqual(@as(u32, 2), animation.frame);
    try std.testing.expectEqual(@as(u32, 3), animation.current_frame);
    try std.testing.expectEqual(@as(u32, 4), animation.loops);

    const compose_command = state.consume(
        alloc,
        "Ga=c,i=1,r=7,c=9,w=23,h=27,X=4,Y=8,x=1,y=3,C=1",
        false,
        0,
        0,
        0,
    ) orelse return error.TestExpectedEqual;
    defer compose_command.deinit(alloc);
    const compose = compose_command.frame_compose;
    try std.testing.expectEqual(@as(u32, 7), compose.source_frame);
    try std.testing.expectEqual(@as(u32, 9), compose.destination_frame);
    try std.testing.expectEqual(@as(u32, 4), compose.source_x);
    try std.testing.expectEqual(@as(u32, 8), compose.source_y);
    try std.testing.expectEqual(@as(u32, 1), compose.destination_x);
    try std.testing.expectEqual(@as(u32, 3), compose.destination_y);
    try std.testing.expect(compose.overwrite);

    const delete_command = state.consume(
        alloc,
        "Ga=d,d=f,i=5,r=9",
        false,
        0,
        0,
        0,
    ) orelse return error.TestExpectedEqual;
    defer delete_command.deinit(alloc);
    const delete_target = delete_command.delete.selector.animation_frames;
    try std.testing.expectEqual(@as(u32, 5), delete_target.image_id);
    try std.testing.expectEqual(@as(u32, 9), delete_target.frame);

    try std.testing.expect(state.consume(
        alloc,
        "Ga=p,i=5,N=1",
        false,
        0,
        0,
        0,
    ) == null);
}

test "animation frame continuation repeats the frame action" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    try std.testing.expect(state.consume(
        alloc,
        "Ga=f,i=2,f=32,s=1,v=1,m=1;AAAA",
        false,
        0,
        0,
        0,
    ) == null);
    const command = state.consume(
        alloc,
        "Ga=f,m=0;AA==",
        false,
        0,
        0,
        0,
    ) orelse return error.TestExpectedEqual;
    defer command.deinit(alloc);
    try std.testing.expect(command == .frame_load);
    try std.testing.expectEqualStrings("AAAAAA==", command.frame_load.encoded);
}

test "shared-memory upload preserves bounded byte range in pure action" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    const command = state.consume(
        alloc,
        "Ga=q,f=32,s=1,v=1,t=s,S=4,O=8,i=299;L3B4LXRlc3Q=",
        false,
        0,
        0,
        0,
    ) orelse return error.TestExpectedEqual;
    defer command.deinit(alloc);
    const load = command.load;
    try std.testing.expect(load.query);
    try std.testing.expectEqual(Medium.shared, load.medium);
    try std.testing.expectEqual(@as(u32, 4), load.data_size);
    try std.testing.expectEqual(@as(u32, 8), load.data_offset);
    try std.testing.expectEqualStrings("L3B4LXRlc3Q=", load.encoded);
}

test "local media ignore direct-data continuation flag" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    const command = state.consume(
        alloc,
        "Ga=q,f=32,s=1,v=1,t=f,m=1;L3RtcC9waXhlbHM=",
        false,
        0,
        0,
        0,
    ) orelse return error.TestExpectedEqual;
    defer command.deinit(alloc);
    try std.testing.expectEqual(Medium.file, command.load.medium);
    try std.testing.expectEqualStrings("L3RtcC9waXhlbHM=", command.load.encoded);
    try std.testing.expect(state.upload == null);
}

test "PNG upload keeps dimensions host-derived and chunks direct data" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    try std.testing.expect(state.consume(
        alloc,
        "Ga=T,f=100,s=99,v=88,t=d,i=31,p=1,C=1,m=1;iVBO",
        false,
        0,
        7,
        2,
    ) == null);
    const command = state.consume(alloc, "Gm=0;Rw==", false, 0, 9, 4) orelse
        return error.TestExpectedEqual;
    defer command.deinit(alloc);
    try std.testing.expectEqual(Format.png, command.load.format);
    try std.testing.expectEqual(@as(u32, 99), command.load.width);
    try std.testing.expectEqual(@as(u32, 88), command.load.height);
    try std.testing.expectEqual(@as(u64, 9), command.load.row_id);
    try std.testing.expectEqualStrings("iVBORw==", command.load.encoded);
}

test "delete all removes placements and malformed controls are ignored" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    try state.placements.append(alloc, .{
        .image_id = 2,
        .placement_id = 1,
        .generation = 1,
        .image_width = 1,
        .image_height = 1,
        .on_alt = false,
        .row_id = 0,
        .col = 0,
        .z = 0,
    });
    try std.testing.expect(state.consume(alloc, "Gwat", false, 0, 0, 0) == null);
    const command = state.consume(alloc, "Ga=d,d=A,q=2", false, 0, 0, 0) orelse
        return error.TestExpectedEqual;
    defer command.deinit(alloc);
    const removed = state.applyDelete(command.delete, null, 200, 100, 20, 5);
    try std.testing.expect(removed.len == 1);
    try std.testing.expectEqual(@as(usize, 0), state.placements.items.len);
}

test "put parses image numbers and complete physical placement controls" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    const command = state.consume(
        alloc,
        "Ga=p,I=7,p=3,x=1,y=2,w=30,h=20,X=4,Y=5,c=6,r=7,z=-8,C=1,q=1",
        false,
        100,
        102,
        9,
    ) orelse return error.TestExpectedEqual;
    defer command.deinit(alloc);
    const put = command.put;
    try std.testing.expectEqual(@as(u32, 7), put.image_number);
    try std.testing.expectEqual(@as(u32, 3), put.placement_id);
    try std.testing.expectEqual(@as(u32, 1), put.source_x);
    try std.testing.expectEqual(@as(u32, 2), put.source_y);
    try std.testing.expectEqual(@as(u32, 30), put.source_width);
    try std.testing.expectEqual(@as(u32, 20), put.source_height);
    try std.testing.expectEqual(@as(u32, 4), put.cell_offset_x);
    try std.testing.expectEqual(@as(u32, 5), put.cell_offset_y);
    try std.testing.expectEqual(@as(u32, 6), put.columns);
    try std.testing.expectEqual(@as(u32, 7), put.rows);
    try std.testing.expectEqual(@as(i32, -8), put.z);
    try std.testing.expect(put.cursor_no_move);
    try std.testing.expectEqual(@as(u64, 102), put.row_id);
    try std.testing.expectEqual(@as(u16, 9), put.col);
}

test "placement geometry clips source and preserves aspect ratio" {
    const put: Put = .{
        .image_id = 9,
        .image_number = 4,
        .placement_id = 1,
        .quiet = 0,
        .cursor_no_move = false,
        .z = 0,
        .source_x = 90,
        .source_y = 10,
        .source_width = 40,
        .source_height = 20,
        .cell_offset_x = 0,
        .cell_offset_y = 0,
        .columns = 4,
        .rows = 0,
        .on_alt = false,
        .row_id = 0,
        .col = 0,
    };
    const geometry = try geometryForPut(&put, .{
        .image_id = 9,
        .image_number = 4,
        .generation = 1,
        .width = 100,
        .height = 50,
    }, 100, 100, 10, 5);
    try std.testing.expectEqual(@as(u32, 90), geometry.source_x);
    try std.testing.expectEqual(@as(u32, 10), geometry.source_y);
    try std.testing.expectEqual(@as(u32, 10), geometry.source_width);
    try std.testing.expectEqual(@as(u32, 20), geometry.source_height);
    try std.testing.expectEqual(@as(u32, 40), geometry.dest_width);
    try std.testing.expectEqual(@as(u32, 80), geometry.dest_height);
    try std.testing.expectEqual(@as(u32, 4), geometry.grid_cols);
    try std.testing.expectEqual(@as(u32, 4), geometry.grid_rows);

    var invalid = put;
    invalid.cell_offset_x = 10;
    try std.testing.expectError(
        error.InvalidPlacement,
        geometryForPut(&invalid, .{
            .image_id = 9,
            .image_number = 4,
            .generation = 1,
            .width = 100,
            .height = 50,
        }, 100, 100, 10, 5),
    );
}

test "named placements replace while anonymous placements accumulate" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    const resource: Resource = .{
        .image_id = 5,
        .image_number = 2,
        .generation = 7,
        .width = 10,
        .height = 10,
    };
    var put: Put = .{
        .image_id = 5,
        .image_number = 0,
        .placement_id = 3,
        .quiet = 0,
        .cursor_no_move = true,
        .z = 0,
        .source_x = 0,
        .source_y = 0,
        .source_width = 0,
        .source_height = 0,
        .cell_offset_x = 0,
        .cell_offset_y = 0,
        .columns = 1,
        .rows = 1,
        .on_alt = false,
        .row_id = 1,
        .col = 1,
    };
    _ = try state.commitPut(alloc, &put, resource, 100, 100, 10, 5);
    put.row_id = 2;
    _ = try state.commitPut(alloc, &put, resource, 100, 100, 10, 5);
    try std.testing.expectEqual(@as(usize, 1), state.placements.items.len);
    try std.testing.expectEqual(@as(u64, 2), state.placements.items[0].row_id);

    put.placement_id = 0;
    _ = try state.commitPut(alloc, &put, resource, 100, 100, 10, 5);
    _ = try state.commitPut(alloc, &put, resource, 100, 100, 10, 5);
    try std.testing.expectEqual(@as(usize, 3), state.placements.items.len);
}

test "every published deletion selector is parsed" {
    const alloc = std.testing.allocator;
    const commands = [_][]const u8{
        "Ga=d",                  "Ga=d,d=A",              "Ga=d,d=i,i=1",
        "Ga=d,d=I,i=1,p=2",      "Ga=d,d=n,I=3",          "Ga=d,d=N,I=3,p=2",
        "Ga=d,d=c",              "Ga=d,d=C",              "Ga=d,d=f,i=1,r=2",
        "Ga=d,d=F,I=1",          "Ga=d,d=p,x=1,y=2",      "Ga=d,d=P,x=1,y=2",
        "Ga=d,d=q,x=1,y=2,z=-3", "Ga=d,d=Q,x=1,y=2,z=-3", "Ga=d,d=r,x=2,y=9",
        "Ga=d,d=R,x=2,y=9",      "Ga=d,d=x,x=4",          "Ga=d,d=X,x=4",
        "Ga=d,d=y,y=5",          "Ga=d,d=Y,y=5",          "Ga=d,d=z,z=-6",
        "Ga=d,d=Z,z=-6",
    };
    for (commands) |bytes| {
        var state: State = .{};
        defer state.deinit(alloc);
        const command = state.consume(alloc, bytes, false, 0, 0, 0) orelse
            return error.TestExpectedEqual;
        defer command.deinit(alloc);
        try std.testing.expect(command == .delete);
    }
}

test "spatial delete removes only intersecting placements" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    const resource: Resource = .{
        .image_id = 5,
        .image_number = 0,
        .generation = 7,
        .width = 10,
        .height = 10,
    };
    var put: Put = .{
        .image_id = 5,
        .image_number = 0,
        .placement_id = 1,
        .quiet = 0,
        .cursor_no_move = true,
        .z = -2,
        .source_x = 0,
        .source_y = 0,
        .source_width = 0,
        .source_height = 0,
        .cell_offset_x = 0,
        .cell_offset_y = 0,
        .columns = 2,
        .rows = 2,
        .on_alt = false,
        .row_id = 100,
        .col = 3,
    };
    _ = try state.commitPut(alloc, &put, resource, 100, 100, 10, 5);
    put.placement_id = 2;
    put.row_id = 103;
    put.col = 7;
    _ = try state.commitPut(alloc, &put, resource, 100, 100, 10, 5);

    const removed = state.applyDelete(.{
        .selector = .{ .cell_z = .{ .x = 4, .y = 2, .z = -2 } },
        .free = true,
        .quiet = 0,
        .on_alt = false,
        .view_top_row_id = 100,
        .cursor_row_id = 100,
        .cursor_col = 0,
    }, null, 100, 100, 10, 5);
    try std.testing.expectEqualSlices(u32, &.{5}, removed.items());
    try std.testing.expectEqual(@as(usize, 1), state.placements.items.len);
    try std.testing.expectEqual(@as(u32, 2), state.placements.items[0].placement_id);
}

test "relative placement controls and transient hint are parsed" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    const command = state.consume(
        alloc,
        "Ga=T,f=32,s=1,v=1,i=7,p=9,P=3,Q=4,H=-2,V=5,N=5;AAAAAA==",
        false,
        0,
        8,
        6,
    ) orelse return error.TestExpectedEqual;
    defer command.deinit(alloc);
    const load = command.load;
    try std.testing.expect(load.transient);
    try std.testing.expectEqual(@as(u32, 3), load.parent_image_id);
    try std.testing.expectEqual(@as(u32, 4), load.parent_placement_id);
    try std.testing.expectEqual(@as(i32, -2), load.parent_offset_x);
    try std.testing.expectEqual(@as(i32, 5), load.parent_offset_y);
}

test "relative placement graph preserves named parents and rejects cycles" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    const resource_a: Resource = .{ .image_id = 1, .image_number = 0, .generation = 1, .width = 1, .height = 1 };
    const resource_b: Resource = .{ .image_id = 2, .image_number = 0, .generation = 2, .width = 1, .height = 1 };
    var put_a: Put = .{
        .image_id = 1,
        .placement_id = 10,
        .quiet = 0,
        .cursor_no_move = true,
        .z = 0,
        .source_x = 0,
        .source_y = 0,
        .source_width = 0,
        .source_height = 0,
        .cell_offset_x = 0,
        .cell_offset_y = 0,
        .columns = 1,
        .rows = 1,
        .on_alt = false,
        .row_id = 3,
        .col = 4,
    };
    _ = try state.commitPut(alloc, &put_a, resource_a, 100, 100, 10, 10);
    const parent_internal = state.placements.items[0].internal_id;

    var put_b = put_a;
    put_b.image_id = 2;
    put_b.placement_id = 20;
    put_b.parent_image_id = 1;
    put_b.parent_placement_id = 10;
    put_b.parent_offset_x = -2;
    put_b.parent_offset_y = 5;
    _ = try state.commitPut(alloc, &put_b, resource_b, 100, 100, 10, 10);
    try std.testing.expectEqual(parent_internal, state.placements.items[1].parent_internal_id);

    put_a.parent_image_id = 2;
    put_a.parent_placement_id = 20;
    try std.testing.expectError(
        error.ParentCycle,
        state.commitPut(alloc, &put_a, resource_a, 100, 100, 10, 10),
    );
    try std.testing.expectEqual(parent_internal, state.placements.items[0].internal_id);
}

test "deleting a relative parent cascades and reports orphan resources" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    const base_put: Put = .{
        .image_id = 1,
        .placement_id = 1,
        .quiet = 0,
        .cursor_no_move = true,
        .z = 0,
        .source_x = 0,
        .source_y = 0,
        .source_width = 0,
        .source_height = 0,
        .cell_offset_x = 0,
        .cell_offset_y = 0,
        .columns = 1,
        .rows = 1,
        .on_alt = false,
        .row_id = 0,
        .col = 0,
    };
    const resource_a: Resource = .{ .image_id = 1, .image_number = 0, .generation = 1, .width = 1, .height = 1 };
    const resource_b: Resource = .{ .image_id = 2, .image_number = 0, .generation = 2, .width = 1, .height = 1 };
    _ = try state.commitPut(alloc, &base_put, resource_a, 100, 100, 10, 10);
    var child = base_put;
    child.image_id = 2;
    child.placement_id = 2;
    child.parent_image_id = 1;
    child.parent_placement_id = 1;
    _ = try state.commitPut(alloc, &child, resource_b, 100, 100, 10, 10);

    const removed = state.applyDelete(.{
        .selector = .{ .image = .{ .image_id = 1, .placement_id = 1 } },
        .free = false,
        .quiet = 0,
        .on_alt = false,
        .view_top_row_id = 0,
        .cursor_row_id = 0,
        .cursor_col = 0,
    }, 1, 100, 100, 10, 10);
    try std.testing.expectEqual(@as(usize, 0), state.placements.items.len);
    try std.testing.expectEqualSlices(u32, &.{2}, removed.orphanItems());
}
