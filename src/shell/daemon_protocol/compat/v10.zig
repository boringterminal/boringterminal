//! Frozen viewer-side adapter for the v10 public attach dialect shipped by
//! v0.2.0 and v0.3.0. Snapshot decoding translates the exact old schema into
//! the current canonical viewer model; no v10 shape escapes this capsule.

const std = @import("std");
const protocol = @import("../../../daemon/protocol.zig");
const graphics_limits = @import("../../../graphics_limits.zig");
const vt = @import("../../../vt.zig");

pub const version: u16 = 10;

const WireCode = enum(u8) {
    codepoint,
    escape,
    enter,
    tab,
    backspace,
    insert,
    delete_forward,
    up,
    down,
    right,
    left,
    home,
    end,
    page_up,
    page_down,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

pub const KeyEncoding = union(enum) {
    semantic: WireCode,
    raw: []const u8,
    ignored,
};

/// Public v10 used the same cell-only semantic mouse request as v13.
pub fn encodeMouseEvent(enc: *protocol.Encoder, event: vt.mouse.Event) !void {
    try enc.byte(@intFromEnum(event.kind));
    try enc.byte(@intFromEnum(event.button));
    const modifiers: u3 = @bitCast(event.modifiers);
    try enc.byte(@intCast(modifiers));
    try enc.int(u16, event.col);
    try enc.int(u16, event.row);
}

pub fn classifyKey(event: vt.keyboard.Event) KeyEncoding {
    if (event.code == .text) {
        if (event.action == .release) return .ignored;
        return .{ .raw = event.text };
    }
    // v10 cannot carry AppKit's committed text alongside a physical key.
    // Preserve the text lane for ordinary/Option-composed input instead of
    // degrading it to a bare key identity. Control and Super remain semantic
    // because their committed bytes represent bindings, not inserted text.
    if (event.action != .release and event.text.len != 0 and
        !event.modifiers.control and !event.modifiers.super)
    {
        return .{ .raw = event.text };
    }
    if (wireCode(event.code)) |code| return .{ .semantic = code };
    if (event.action != .release and event.text.len != 0) return .{ .raw = event.text };
    return .ignored;
}

pub fn encodeSemanticKey(enc: *protocol.Encoder, code: WireCode, event: vt.keyboard.Event) !void {
    try enc.byte(@intFromEnum(code));
    try enc.byte(@intFromEnum(event.action));
    try enc.byte(@bitCast(event.modifiers));
    try enc.int(u32, event.codepoint);
}

fn wireCode(code: vt.keyboard.Code) ?WireCode {
    return switch (code) {
        .codepoint => .codepoint,
        .escape => .escape,
        .enter => .enter,
        .tab => .tab,
        .backspace => .backspace,
        .insert => .insert,
        .delete_forward => .delete_forward,
        .up => .up,
        .down => .down,
        .right => .right,
        .left => .left,
        .home => .home,
        .end => .end,
        .page_up => .page_up,
        .page_down => .page_down,
        .f1 => .f1,
        .f2 => .f2,
        .f3 => .f3,
        .f4 => .f4,
        .f5 => .f5,
        .f6 => .f6,
        .f7 => .f7,
        .f8 => .f8,
        .f9 => .f9,
        .f10 => .f10,
        .f11 => .f11,
        .f12 => .f12,
        else => null,
    };
}

pub fn decodeSnapshot(dec: *protocol.Decoder, alloc: std.mem.Allocator) !protocol.Snapshot {
    const id = try dec.int(u64);
    const cols = try dec.int(u16);
    const rows = try dec.int(u16);
    if (cols < 2 or rows < 1) return error.InvalidSnapshot;
    const col = try dec.int(u16);
    const row = try dec.int(u16);
    const viewport_offset = try dec.int(u64);
    const sync_output_epoch = try dec.int(u64);
    const modes: protocol.SnapshotModes = @bitCast(try dec.byte());
    if (modes.pointer_shape != .text) return error.InvalidSnapshot;
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
            .hyperlink_id = 0,
        };
        is_selected.* = try dec.boolean();
    }
    var cell_i: usize = 0;
    while (cell_i < cells.len) : (cell_i += 1) {
        const cell_col = cell_i % cols;
        if (cells[cell_i].flags.wide and
            (cell_col + 1 >= cols or !cells[cell_i + 1].flags.wide_spacer))
            return error.InvalidSnapshot;
        if (cells[cell_i].flags.wide_spacer and
            (cell_col == 0 or !cells[cell_i - 1].flags.wide))
            return error.InvalidSnapshot;
    }
    const image_count = try dec.int(u16);
    if (image_count > graphics_limits.max_images) return error.InvalidSnapshot;
    const images = try alloc.alloc(protocol.ImageRef, image_count);
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
        for (images[0..image_index]) |existing|
            if (existing.id == image_id) return error.InvalidSnapshot;
        image.* = .{ .id = image_id, .generation = generation, .width = width, .height = height };
    }
    const placement_count = try dec.int(u32);
    if (placement_count > expected + vt.graphics.max_placements) return error.InvalidSnapshot;
    const placements = try alloc.alloc(protocol.Placement, placement_count);
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
    const hyperlinks = try alloc.alloc(protocol.Hyperlink, 0);
    errdefer alloc.free(hyperlinks);
    return .{
        .id = id,
        .cols = cols,
        .rows = rows,
        .col = col,
        .row = row,
        .viewport_offset = viewport_offset,
        .sync_output_epoch = sync_output_epoch,
        .grid_epoch = 0,
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

fn decodeColor(dec: *protocol.Decoder) !vt.Color {
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

fn findImage(images: []const protocol.ImageRef, id: u32, generation: u64) ?*const protocol.ImageRef {
    for (images) |*image| if (image.id == id and image.generation == generation) return image;
    return null;
}

fn validScalar(cp: u32) bool {
    return cp <= 0x10ffff and !(cp >= 0xd800 and cp <= 0xdfff);
}

test "v10 wire codes stay frozen" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(WireCode.codepoint));
    try std.testing.expectEqual(@as(u8, 26), @intFromEnum(WireCode.f12));
}

test "v10 committed key text uses raw input" {
    const keyed_text = classifyKey(.{
        .code = .codepoint,
        .codepoint = 'h',
        .text = "h",
    });
    try std.testing.expectEqualStrings("h", keyed_text.raw);

    const control_key = classifyKey(.{
        .code = .codepoint,
        .codepoint = 'c',
        .modifiers = .{ .control = true },
        .text = "\x03",
    });
    try std.testing.expect(control_key == .semantic);
}
