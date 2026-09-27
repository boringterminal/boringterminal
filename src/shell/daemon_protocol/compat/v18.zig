//! Frozen viewer-side snapshot adapter for the v18 public attach dialect
//! shipped by v0.5.0. Metadata/registry share the frozen v19 layout.

const std = @import("std");
const protocol = @import("../../../daemon/protocol.zig");
const vt = @import("../../../vt.zig");

pub const version: u16 = 18;

const WireModes = packed struct(u8) {
    on_alt: bool,
    cursor_visible: bool,
    synchronized_output: bool,
    grapheme_cluster: bool,
    focus_reporting: bool,
    mouse_reporting: bool,
    pointer_shape: u2,
};

pub fn decodeSnapshot(dec: *protocol.Decoder, alloc: std.mem.Allocator) !protocol.Snapshot {
    const id = try dec.int(u64);
    const cols = try dec.int(u16);
    const rows = try dec.int(u16);
    if (cols < 2 or rows < 1) return error.InvalidSnapshot;
    const col = try dec.int(u16);
    const row = try dec.int(u16);
    const viewport_offset = try dec.int(u64);
    const sync_output_epoch = try dec.int(u64);
    const grid_epoch = try dec.int(u64);
    const wire: WireModes = @bitCast(try dec.byte());
    const pointer_shape: vt.mouse.PointerShape = switch (wire.pointer_shape) {
        0 => .text,
        1 => .default,
        2 => .pointer,
        3 => .crosshair,
    };
    return protocol.Snapshot.decodeBody(dec, alloc, .{
        .id = id,
        .cols = cols,
        .rows = rows,
        .col = col,
        .row = row,
        .viewport_offset = viewport_offset,
        .sync_output_epoch = sync_output_epoch,
        .grid_epoch = grid_epoch,
        .modes = .{
            .on_alt = wire.on_alt,
            .cursor_visible = wire.cursor_visible,
            .synchronized_output = wire.synchronized_output,
            .grapheme_cluster = wire.grapheme_cluster,
            .focus_reporting = wire.focus_reporting,
            .mouse_reporting = wire.mouse_reporting,
        },
        .pointer_shape = pointer_shape,
        .exited = try dec.boolean(),
        .working = try dec.boolean(),
        .attention = try dec.boolean(),
    });
}

test "v18 wire pointer values remain frozen" {
    try std.testing.expectEqual(@as(u8, 18), version);
    inline for (0..4) |value| {
        const wire: WireModes = @bitCast(@as(u8, value << 6));
        try std.testing.expectEqual(@as(u2, value), wire.pointer_shape);
    }
}
