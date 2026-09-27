//! Frozen v0.6.0 (8c83190145da83c6961ffcb379a007a4918a9d83) / v19 codec.
const std = @import("std");
const protocol = @import("../../../daemon/protocol.zig");
const vt = @import("../../../vt.zig");
const Decoder = protocol.Decoder;
const Metadata = protocol.Metadata;
const RegistrySnapshot = protocol.RegistrySnapshot;
const DisplayItem = protocol.DisplayItem;
const FocusedMember = protocol.FocusedMember;
const Snapshot = protocol.Snapshot;
const SnapshotModes = protocol.SnapshotModes;
const max_working_directory_bytes = 1024;
pub const version: u16 = 19;
pub fn decodeSnapshot(dec: *Decoder, alloc: std.mem.Allocator) !Snapshot {
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
    if (modes.reserved != 0) return error.InvalidSnapshot;
    const pointer_byte = try dec.byte();
    if (pointer_byte > 33) return error.InvalidSnapshot;
    const pointer_shape = std.enums.fromInt(vt.mouse.PointerShape, pointer_byte) orelse
        return error.InvalidSnapshot;
    return protocol.Snapshot.decodeBody(dec, alloc, .{
        .id = id,
        .cols = cols,
        .rows = rows,
        .col = col,
        .row = row,
        .viewport_offset = viewport_offset,
        .sync_output_epoch = sync_output_epoch,
        .grid_epoch = grid_epoch,
        .modes = modes,
        .pointer_shape = pointer_shape,
        .exited = try dec.boolean(),
        .working = try dec.boolean(),
        .attention = try dec.boolean(),
    });
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
