//! Frozen metadata/registry shape shared by the public v10 and v13 attach
//! dialects. Both ended metadata after the attention byte; current cwd state
//! is therefore translated to null (RFC 0019 / RFC 0020).

const std = @import("std");
const protocol = @import("../../../daemon/protocol.zig");

pub fn decodeMetadata(dec: *protocol.Decoder, alloc: std.mem.Allocator) !protocol.Metadata {
    const id = try dec.int(u64);
    const title = try dec.allocBytes(alloc, 4096);
    errdefer alloc.free(title);
    return .{
        .id = id,
        .title = title,
        .exited = try dec.boolean(),
        .working = try dec.boolean(),
        .attention = try dec.boolean(),
        .cwd = null,
    };
}

pub fn decodeRegistry(
    dec: *protocol.Decoder,
    alloc: std.mem.Allocator,
) !protocol.RegistrySnapshot {
    const session_count = try dec.int(u32);
    if (session_count > 10_000) return error.LengthLimit;
    const sessions = try alloc.alloc(protocol.Metadata, session_count);
    errdefer alloc.free(sessions);
    var initialized: usize = 0;
    errdefer for (sessions[0..initialized]) |*metadata| metadata.deinit(alloc);
    while (initialized < sessions.len) : (initialized += 1)
        sessions[initialized] = try decodeMetadata(dec, alloc);

    const item_count = try dec.int(u32);
    if (item_count > session_count) return error.InvalidRegistry;
    const items = try alloc.alloc(protocol.DisplayItem, item_count);
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

fn decodeDisplayItem(dec: *protocol.Decoder) !protocol.DisplayItem {
    return switch (try dec.byte()) {
        0 => blk: {
            const id = try dec.int(u64);
            if (id == 0) return error.InvalidDisplayItem;
            break :blk .{ .single = id };
        },
        1 => blk: {
            const left = try dec.int(u64);
            const right = try dec.int(u64);
            const focused = std.enums.fromInt(protocol.FocusedMember, try dec.byte()) orelse
                return error.InvalidDisplayItem;
            const ratio = try dec.int(u16);
            if (left == 0 or right == 0 or left == right or ratio == 0 or
                ratio == std.math.maxInt(u16)) return error.InvalidDisplayItem;
            break :blk .{ .pair = .{
                .left = left,
                .right = right,
                .focused = focused,
                .ratio = ratio,
                .zoomed = false,
            } };
        },
        else => error.InvalidDisplayItem,
    };
}

fn validateMembership(
    known: *const std.AutoHashMap(u64, void),
    membership: *std.AutoHashMap(u64, void),
    id: u64,
) !void {
    if (!known.contains(id) or membership.contains(id)) return error.InvalidRegistry;
    try membership.put(id, {});
}

test "legacy metadata translates absent cwd to null" {
    const alloc = std.testing.allocator;
    var enc = protocol.Encoder.init(alloc);
    defer enc.deinit();
    try enc.int(u64, 7);
    try enc.bytes("old shell");
    try enc.boolean(false);
    try enc.boolean(true);
    try enc.boolean(false);
    var dec: protocol.Decoder = .{ .bytes = enc.slice() };
    var metadata = try decodeMetadata(&dec, alloc);
    defer metadata.deinit(alloc);
    try dec.finish();
    try std.testing.expectEqual(@as(u64, 7), metadata.id);
    try std.testing.expect(metadata.cwd == null);
}

test "legacy pair translates absent zoom to false" {
    const alloc = std.testing.allocator;
    var enc = protocol.Encoder.init(alloc);
    defer enc.deinit();
    try enc.int(u32, 2);
    for ([_]u64{ 1, 2 }) |id| {
        try enc.int(u64, id);
        try enc.bytes("shell");
        try enc.boolean(false);
        try enc.boolean(false);
        try enc.boolean(false);
    }
    try enc.int(u32, 1);
    try enc.byte(1);
    try enc.int(u64, 1);
    try enc.int(u64, 2);
    try enc.byte(@intFromEnum(protocol.FocusedMember.right));
    try enc.int(u16, 40000);

    var dec: protocol.Decoder = .{ .bytes = enc.slice() };
    var registry = try decodeRegistry(&dec, alloc);
    defer registry.deinit(alloc);
    try std.testing.expect(!registry.display_items[0].pair.zoomed);
    try std.testing.expectEqual(@as(u64, 2), registry.display_items[0].pair.focusedId());
}
