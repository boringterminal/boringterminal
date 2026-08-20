//! Pure Kitty Unicode-placeholder decoding and aspect-fit geometry.
//!
//! The protocol behavior and diacritic table come from Kitty's published
//! graphics specification. The run coalescing and integer render-geometry
//! model are independently adapted from Ghostty's MIT implementation.

const std = @import("std");
const cell_mod = @import("cell.zig");

pub const placeholder: u21 = 0x10EEEE;

pub const Decoded = struct {
    fg: cell_mod.Color,
    underline_color: cell_mod.Color,
    image_id_low: u32,
    placement_id: u32,
    row: ?u32 = null,
    col: ?u32 = null,
    image_id_high: ?u8 = null,
};

pub const Run = struct {
    screen_row: u16,
    screen_col: u16,
    image_id: u32,
    placement_id: u32,
    image_row: u32,
    image_col: u32,
    width: u32,
};

pub const Builder = struct {
    screen_row: u16,
    screen_col: u16,
    fg: cell_mod.Color,
    underline_color: cell_mod.Color,
    image_id_low: u32,
    placement_id: u32,
    row: u32,
    col: u32,
    image_id_high: u8,
    width: u32 = 1,

    pub fn init(decoded: Decoded, screen_row: u16, screen_col: u16) Builder {
        return .{
            .screen_row = screen_row,
            .screen_col = screen_col,
            .fg = decoded.fg,
            .underline_color = decoded.underline_color,
            .image_id_low = decoded.image_id_low,
            .placement_id = decoded.placement_id,
            .row = decoded.row orelse 0,
            .col = decoded.col orelse 0,
            .image_id_high = decoded.image_id_high orelse 0,
        };
    }

    pub fn append(self: *Builder, decoded: Decoded) bool {
        if (!std.meta.eql(self.fg, decoded.fg) or
            !std.meta.eql(self.underline_color, decoded.underline_color) or
            self.image_id_low != decoded.image_id_low or
            self.placement_id != decoded.placement_id or
            (decoded.row != null and decoded.row.? != self.row) or
            (decoded.col != null and decoded.col.? != self.col + self.width) or
            (decoded.image_id_high != null and decoded.image_id_high.? != self.image_id_high))
            return false;
        self.width += 1;
        return true;
    }

    pub fn complete(self: Builder) Run {
        return .{
            .screen_row = self.screen_row,
            .screen_col = self.screen_col,
            .image_id = self.image_id_low | (@as(u32, self.image_id_high) << 24),
            .placement_id = self.placement_id,
            .image_row = self.row,
            .image_col = self.col,
            .width = self.width,
        };
    }
};

pub fn decode(cell: cell_mod.Cell, suffix: []const u21) Decoded {
    var result: Decoded = .{
        .fg = cell.fg,
        .underline_color = cell.underline_color,
        .image_id_low = colorId(cell.fg),
        .placement_id = colorId(cell.underline_color),
    };
    if (suffix.len > 0) result.row = diacriticIndex(suffix[0]);
    if (suffix.len > 1) result.col = diacriticIndex(suffix[1]);
    if (suffix.len > 2) {
        const high = diacriticIndex(suffix[2]);
        if (high != null and high.? <= std.math.maxInt(u8))
            result.image_id_high = @intCast(high.?);
    }
    return result;
}

fn colorId(color: cell_mod.Color) u32 {
    return switch (color) {
        .default => 0,
        .indexed => |index| index,
        .rgb => |rgb| (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b,
    };
}

pub const RenderGeometry = struct {
    col_advance: u32,
    cell_offset_x: u32,
    cell_offset_y: u32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
    dest_width: u32,
    dest_height: u32,
};

/// Clip one contiguous placeholder run to the aspect-preserving image fitted
/// inside its virtual placement grid. All dimensions are backing pixels.
pub fn renderGeometry(
    run: Run,
    image_width: u32,
    image_height: u32,
    requested_columns: u32,
    requested_rows: u32,
    cell_width: u32,
    cell_height: u32,
) ?RenderGeometry {
    if (image_width == 0 or image_height == 0 or cell_width == 0 or cell_height == 0)
        return null;
    const columns = if (requested_columns != 0)
        requested_columns
    else
        ceilDiv(image_width, cell_width);
    const rows = if (requested_rows != 0)
        requested_rows
    else
        ceilDiv(image_height, cell_height);
    if (columns == 0 or rows == 0 or run.image_col >= columns or run.image_row >= rows)
        return null;

    const visible_width = @min(run.width, columns - run.image_col);
    if (visible_width == 0) return null;

    const canvas_width: f64 = @floatFromInt(@as(u64, columns) * cell_width);
    const canvas_height: f64 = @floatFromInt(@as(u64, rows) * cell_height);
    const image_width_f: f64 = @floatFromInt(image_width);
    const image_height_f: f64 = @floatFromInt(image_height);
    const scale = @min(canvas_width / image_width_f, canvas_height / image_height_f);
    if (!std.math.isFinite(scale) or scale <= 0) return null;
    const fit_width = image_width_f * scale;
    const fit_height = image_height_f * scale;
    const fit_x = (canvas_width - fit_width) / 2.0;
    const fit_y = (canvas_height - fit_height) / 2.0;

    const run_x0: f64 = @floatFromInt(@as(u64, run.image_col) * cell_width);
    const run_x1: f64 = @floatFromInt(@as(u64, run.image_col + visible_width) * cell_width);
    const run_y0: f64 = @floatFromInt(@as(u64, run.image_row) * cell_height);
    const run_y1: f64 = @floatFromInt(@as(u64, run.image_row + 1) * cell_height);
    const x0 = @max(run_x0, fit_x);
    const x1 = @min(run_x1, fit_x + fit_width);
    const y0 = @max(run_y0, fit_y);
    const y1 = @min(run_y1, fit_y + fit_height);
    if (x1 <= x0 or y1 <= y0) return null;

    // Source rectangles are integer texel intervals. Round them outward so a
    // real fragment narrower than one source pixel cannot collapse to zero.
    const source_x0 = flooredU32((x0 - fit_x) / scale, image_width) orelse return null;
    const source_x1 = ceiledU32((x1 - fit_x) / scale, image_width) orelse return null;
    const source_y0 = flooredU32((y0 - fit_y) / scale, image_height) orelse return null;
    const source_y1 = ceiledU32((y1 - fit_y) / scale, image_height) orelse return null;
    const dest_x0 = roundedU32(x0 - run_x0, std.math.maxInt(u32)) orelse return null;
    const dest_x1 = roundedU32(x1 - run_x0, std.math.maxInt(u32)) orelse return null;
    const dest_y0 = roundedU32(y0 - run_y0, std.math.maxInt(u32)) orelse return null;
    const dest_y1 = roundedU32(y1 - run_y0, std.math.maxInt(u32)) orelse return null;
    if (source_x1 <= source_x0 or source_y1 <= source_y0 or
        dest_x1 <= dest_x0 or dest_y1 <= dest_y0)
        return null;

    return .{
        .col_advance = dest_x0 / cell_width,
        .cell_offset_x = dest_x0 % cell_width,
        .cell_offset_y = dest_y0,
        .source_x = source_x0,
        .source_y = source_y0,
        .source_width = source_x1 - source_x0,
        .source_height = source_y1 - source_y0,
        .dest_width = dest_x1 - dest_x0,
        .dest_height = dest_y1 - dest_y0,
    };
}

fn roundedU32(value: f64, maximum: u32) ?u32 {
    if (!std.math.isFinite(value) or value < 0) return null;
    const rounded = @round(value);
    if (rounded > @as(f64, @floatFromInt(maximum))) return maximum;
    return @intFromFloat(rounded);
}

fn flooredU32(value: f64, maximum: u32) ?u32 {
    return directedU32(value, maximum, .down);
}

fn ceiledU32(value: f64, maximum: u32) ?u32 {
    return directedU32(value, maximum, .up);
}

fn directedU32(value: f64, maximum: u32, direction: enum { down, up }) ?u32 {
    if (!std.math.isFinite(value) or value < 0) return null;
    const nearest = @round(value);
    const stable = if (@abs(value - nearest) <= 1e-9) nearest else value;
    const directed = switch (direction) {
        .down => @floor(stable),
        .up => @ceil(stable),
    };
    if (directed > @as(f64, @floatFromInt(maximum))) return maximum;
    return @intFromFloat(directed);
}

fn ceilDiv(value: u32, divisor: u32) u32 {
    if (value == 0 or divisor == 0) return 0;
    return 1 + (value - 1) / divisor;
}

pub fn diacriticIndex(cp: u21) ?u32 {
    const index = std.sort.binarySearch(u21, &diacritics, cp, (struct {
        fn compare(needle: u21, item: u21) std.math.Order {
            return std.math.order(needle, item);
        }
    }).compare) orelse return null;
    return @intCast(index);
}

/// Pinned verbatim as codepoints from the protocol's
/// rowcolumn-diacritics.txt (Unicode 6.0-derived, retrieved 2026-08-17).
const diacritics = [_]u21{
    0x0305,  0x030D,  0x030E,  0x0310,  0x0312,  0x033D,  0x033E,  0x033F,
    0x0346,  0x034A,  0x034B,  0x034C,  0x0350,  0x0351,  0x0352,  0x0357,
    0x035B,  0x0363,  0x0364,  0x0365,  0x0366,  0x0367,  0x0368,  0x0369,
    0x036A,  0x036B,  0x036C,  0x036D,  0x036E,  0x036F,  0x0483,  0x0484,
    0x0485,  0x0486,  0x0487,  0x0592,  0x0593,  0x0594,  0x0595,  0x0597,
    0x0598,  0x0599,  0x059C,  0x059D,  0x059E,  0x059F,  0x05A0,  0x05A1,
    0x05A8,  0x05A9,  0x05AB,  0x05AC,  0x05AF,  0x05C4,  0x0610,  0x0611,
    0x0612,  0x0613,  0x0614,  0x0615,  0x0616,  0x0617,  0x0657,  0x0658,
    0x0659,  0x065A,  0x065B,  0x065D,  0x065E,  0x06D6,  0x06D7,  0x06D8,
    0x06D9,  0x06DA,  0x06DB,  0x06DC,  0x06DF,  0x06E0,  0x06E1,  0x06E2,
    0x06E4,  0x06E7,  0x06E8,  0x06EB,  0x06EC,  0x0730,  0x0732,  0x0733,
    0x0735,  0x0736,  0x073A,  0x073D,  0x073F,  0x0740,  0x0741,  0x0743,
    0x0745,  0x0747,  0x0749,  0x074A,  0x07EB,  0x07EC,  0x07ED,  0x07EE,
    0x07EF,  0x07F0,  0x07F1,  0x07F3,  0x0816,  0x0817,  0x0818,  0x0819,
    0x081B,  0x081C,  0x081D,  0x081E,  0x081F,  0x0820,  0x0821,  0x0822,
    0x0823,  0x0825,  0x0826,  0x0827,  0x0829,  0x082A,  0x082B,  0x082C,
    0x082D,  0x0951,  0x0953,  0x0954,  0x0F82,  0x0F83,  0x0F86,  0x0F87,
    0x135D,  0x135E,  0x135F,  0x17DD,  0x193A,  0x1A17,  0x1A75,  0x1A76,
    0x1A77,  0x1A78,  0x1A79,  0x1A7A,  0x1A7B,  0x1A7C,  0x1B6B,  0x1B6D,
    0x1B6E,  0x1B6F,  0x1B70,  0x1B71,  0x1B72,  0x1B73,  0x1CD0,  0x1CD1,
    0x1CD2,  0x1CDA,  0x1CDB,  0x1CE0,  0x1DC0,  0x1DC1,  0x1DC3,  0x1DC4,
    0x1DC5,  0x1DC6,  0x1DC7,  0x1DC8,  0x1DC9,  0x1DCB,  0x1DCC,  0x1DD1,
    0x1DD2,  0x1DD3,  0x1DD4,  0x1DD5,  0x1DD6,  0x1DD7,  0x1DD8,  0x1DD9,
    0x1DDA,  0x1DDB,  0x1DDC,  0x1DDD,  0x1DDE,  0x1DDF,  0x1DE0,  0x1DE1,
    0x1DE2,  0x1DE3,  0x1DE4,  0x1DE5,  0x1DE6,  0x1DFE,  0x20D0,  0x20D1,
    0x20D4,  0x20D5,  0x20D6,  0x20D7,  0x20DB,  0x20DC,  0x20E1,  0x20E7,
    0x20E9,  0x20F0,  0x2CEF,  0x2CF0,  0x2CF1,  0x2DE0,  0x2DE1,  0x2DE2,
    0x2DE3,  0x2DE4,  0x2DE5,  0x2DE6,  0x2DE7,  0x2DE8,  0x2DE9,  0x2DEA,
    0x2DEB,  0x2DEC,  0x2DED,  0x2DEE,  0x2DEF,  0x2DF0,  0x2DF1,  0x2DF2,
    0x2DF3,  0x2DF4,  0x2DF5,  0x2DF6,  0x2DF7,  0x2DF8,  0x2DF9,  0x2DFA,
    0x2DFB,  0x2DFC,  0x2DFD,  0x2DFE,  0x2DFF,  0xA66F,  0xA67C,  0xA67D,
    0xA6F0,  0xA6F1,  0xA8E0,  0xA8E1,  0xA8E2,  0xA8E3,  0xA8E4,  0xA8E5,
    0xA8E6,  0xA8E7,  0xA8E8,  0xA8E9,  0xA8EA,  0xA8EB,  0xA8EC,  0xA8ED,
    0xA8EE,  0xA8EF,  0xA8F0,  0xA8F1,  0xAAB0,  0xAAB2,  0xAAB3,  0xAAB7,
    0xAAB8,  0xAABE,  0xAABF,  0xAAC1,  0xFE20,  0xFE21,  0xFE22,  0xFE23,
    0xFE24,  0xFE25,  0xFE26,  0x10A0F, 0x10A38, 0x1D185, 0x1D186, 0x1D187,
    0x1D188, 0x1D189, 0x1D1AA, 0x1D1AB, 0x1D1AC, 0x1D1AD, 0x1D242, 0x1D243,
    0x1D244,
};

test "placeholder decodes ids and inherits contiguous fields" {
    const first = decode(.{
        .cp = placeholder,
        .fg = .{ .indexed = 42 },
        .underline_color = .{ .rgb = .{ .r = 0, .g = 0, .b = 7 } },
    }, &.{ 0x0305, 0x0305, 0x030E });
    var builder = Builder.init(first, 3, 4);
    try std.testing.expect(builder.append(decode(.{
        .cp = placeholder,
        .fg = .{ .indexed = 42 },
        .underline_color = .{ .rgb = .{ .r = 0, .g = 0, .b = 7 } },
    }, &.{})));
    const run = builder.complete();
    try std.testing.expectEqual(@as(u32, 42 | (2 << 24)), run.image_id);
    try std.testing.expectEqual(@as(u32, 7), run.placement_id);
    try std.testing.expectEqual(@as(u32, 2), run.width);
}

test "placeholder inheritance requires semantic color equality" {
    var builder = Builder.init(decode(.{
        .cp = placeholder,
        .fg = .{ .indexed = 42 },
    }, &.{ 0x0305, 0x0305 }), 0, 0);
    try std.testing.expect(!builder.append(decode(.{
        .cp = placeholder,
        .fg = .{ .rgb = .{ .r = 0, .g = 0, .b = 42 } },
    }, &.{})));
}

test "virtual geometry aspect-fits and clips a placeholder run" {
    const geometry = renderGeometry(.{
        .screen_row = 0,
        .screen_col = 0,
        .image_id = 1,
        .placement_id = 0,
        .image_row = 0,
        .image_col = 0,
        .width = 2,
    }, 100, 50, 2, 2, 10, 10) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u32, 0), geometry.cell_offset_x);
    try std.testing.expectEqual(@as(u32, 5), geometry.cell_offset_y);
    try std.testing.expectEqual(@as(u32, 20), geometry.dest_width);
    try std.testing.expectEqual(@as(u32, 5), geometry.dest_height);
    try std.testing.expectEqual(@as(u32, 100), geometry.source_width);
    try std.testing.expectEqual(@as(u32, 25), geometry.source_height);
}

test "virtual geometry keeps both rows of a one-pixel source" {
    const top = renderGeometry(.{
        .screen_row = 0,
        .screen_col = 0,
        .image_id = 1,
        .placement_id = 0,
        .image_row = 0,
        .image_col = 0,
        .width = 2,
    }, 1, 1, 2, 2, 10, 20) orelse return error.TestExpectedEqual;
    const bottom = renderGeometry(.{
        .screen_row = 1,
        .screen_col = 0,
        .image_id = 1,
        .placement_id = 0,
        .image_row = 1,
        .image_col = 0,
        .width = 2,
    }, 1, 1, 2, 2, 10, 20) orelse return error.TestExpectedEqual;

    try std.testing.expectEqual(@as(u32, 1), top.source_height);
    try std.testing.expectEqual(@as(u32, 1), bottom.source_height);
    try std.testing.expectEqual(@as(u32, 10), top.dest_height);
    try std.testing.expectEqual(@as(u32, 10), bottom.dest_height);
    try std.testing.expectEqual(@as(u32, 10), top.cell_offset_y);
    try std.testing.expectEqual(@as(u32, 0), bottom.cell_offset_y);
}

test "diacritic table is pinned sorted and complete" {
    try std.testing.expectEqual(@as(usize, 297), diacritics.len);
    try std.testing.expect(std.sort.isSorted(u21, &diacritics, {}, struct {
        fn lessThan(_: void, lhs: u21, rhs: u21) bool {
            return lhs < rhs;
        }
    }.lessThan));
}
