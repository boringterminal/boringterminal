//! Cell-sized built-in rasters for Unicode box drawing and block elements.
//! Font glyph bounds are deliberately not used: every connector reaches the
//! cell edge, so adjacent cells remain continuous at any font size.
//!
//! Character semantics and the light/heavy connection table were checked
//! against Unicode names and Alacritty's Apache-2.0 built-in font. This is an
//! independent grayscale rasterizer for Boring Terminal (RFC 0004).

const std = @import("std");

pub const Bitmap = struct {
    bytes: []u8,
    width: u32,
    height: u32,

    pub fn deinit(self: *Bitmap, alloc: std.mem.Allocator) void {
        alloc.free(self.bytes);
        self.* = undefined;
    }
};

const Stroke = enum {
    none,
    light,
    heavy,
    double,
};

const Sides = struct {
    left: Stroke = .none,
    right: Stroke = .none,
    top: Stroke = .none,
    bottom: Stroke = .none,
};

const Dash = struct {
    vertical: bool,
    stroke: Stroke,
    segments: u8,
};

pub fn supports(cp: u21) bool {
    return cp >= 0x2500 and cp <= 0x259f;
}

pub fn rasterize(
    alloc: std.mem.Allocator,
    cp: u21,
    width: u32,
    height: u32,
) !Bitmap {
    if (!supports(cp)) return error.UnsupportedBoxDrawing;

    const w = @max(width, 1);
    const h = @max(height, 1);
    const bytes = try alloc.alloc(u8, @as(usize, w) * @as(usize, h));
    errdefer alloc.free(bytes);
    @memset(bytes, 0);

    if (dashSpec(cp)) |dash| {
        rasterizeDashes(bytes, w, h, dash);
    } else if ((cp >= 0x2500 and cp <= 0x254b) or (cp >= 0x2574 and cp <= 0x257f)) {
        rasterizeSides(bytes, w, h, lightHeavySides(cp));
    } else if (cp >= 0x2550 and cp <= 0x256c) {
        rasterizeSides(bytes, w, h, doubleSides(cp));
    } else if (cp >= 0x256d and cp <= 0x2570) {
        rasterizeRounded(bytes, w, h, cp);
    } else if (cp >= 0x2571 and cp <= 0x2573) {
        rasterizeDiagonal(bytes, w, h, cp);
    } else {
        rasterizeBlock(bytes, w, h, cp);
    }

    return .{ .bytes = bytes, .width = w, .height = h };
}

fn dashSpec(cp: u21) ?Dash {
    return switch (cp) {
        0x2504 => .{ .vertical = false, .stroke = .light, .segments = 3 },
        0x2505 => .{ .vertical = false, .stroke = .heavy, .segments = 3 },
        0x2506 => .{ .vertical = true, .stroke = .light, .segments = 3 },
        0x2507 => .{ .vertical = true, .stroke = .heavy, .segments = 3 },
        0x2508 => .{ .vertical = false, .stroke = .light, .segments = 4 },
        0x2509 => .{ .vertical = false, .stroke = .heavy, .segments = 4 },
        0x250a => .{ .vertical = true, .stroke = .light, .segments = 4 },
        0x250b => .{ .vertical = true, .stroke = .heavy, .segments = 4 },
        0x254c => .{ .vertical = false, .stroke = .light, .segments = 2 },
        0x254d => .{ .vertical = false, .stroke = .heavy, .segments = 2 },
        0x254e => .{ .vertical = true, .stroke = .light, .segments = 2 },
        0x254f => .{ .vertical = true, .stroke = .heavy, .segments = 2 },
        else => null,
    };
}

fn lightHeavySides(cp: u21) Sides {
    return .{
        .left = sideStroke(cp, .left),
        .right = sideStroke(cp, .right),
        .top = sideStroke(cp, .top),
        .bottom = sideStroke(cp, .bottom),
    };
}

const Side = enum { left, right, top, bottom };

fn sideStroke(cp: u21, side: Side) Stroke {
    return switch (side) {
        .left => switch (cp) {
            0x2500,
            0x2510,
            0x2512,
            0x2518,
            0x251a,
            0x2524,
            0x2526,
            0x2527,
            0x2528,
            0x252c,
            0x252e,
            0x2530,
            0x2532,
            0x2534,
            0x2536,
            0x2538,
            0x253a,
            0x253c,
            0x253e,
            0x2540,
            0x2541,
            0x2542,
            0x2544,
            0x2546,
            0x254a,
            0x2574,
            0x257c,
            => .light,
            0x2501,
            0x2511,
            0x2513,
            0x2519,
            0x251b,
            0x2525,
            0x2529,
            0x252a,
            0x252b,
            0x252d,
            0x252f,
            0x2531,
            0x2533,
            0x2535,
            0x2537,
            0x2539,
            0x253b,
            0x253d,
            0x253f,
            0x2543,
            0x2545,
            0x2547,
            0x2548,
            0x2549,
            0x254b,
            0x2578,
            0x257e,
            => .heavy,
            else => .none,
        },
        .right => switch (cp) {
            0x2500,
            0x250c,
            0x250e,
            0x2514,
            0x2516,
            0x251c,
            0x251e,
            0x251f,
            0x2520,
            0x252c,
            0x252d,
            0x2530,
            0x2531,
            0x2534,
            0x2535,
            0x2538,
            0x2539,
            0x253c,
            0x253d,
            0x2540,
            0x2541,
            0x2542,
            0x2543,
            0x2545,
            0x2549,
            0x2576,
            0x257e,
            => .light,
            0x2501,
            0x250d,
            0x250f,
            0x2515,
            0x2517,
            0x251d,
            0x2521,
            0x2522,
            0x2523,
            0x252e,
            0x252f,
            0x2532,
            0x2533,
            0x2536,
            0x2537,
            0x253a,
            0x253b,
            0x253e,
            0x253f,
            0x2544,
            0x2546,
            0x2547,
            0x2548,
            0x254a,
            0x254b,
            0x257a,
            0x257c,
            => .heavy,
            else => .none,
        },
        .top => switch (cp) {
            0x2502,
            0x2514,
            0x2515,
            0x2518,
            0x2519,
            0x251c,
            0x251d,
            0x251f,
            0x2522,
            0x2524,
            0x2525,
            0x2527,
            0x252a,
            0x2534,
            0x2535,
            0x2536,
            0x2537,
            0x253c,
            0x253d,
            0x253e,
            0x253f,
            0x2541,
            0x2545,
            0x2546,
            0x2548,
            0x2575,
            0x257d,
            => .light,
            0x2503,
            0x2516,
            0x2517,
            0x251a,
            0x251b,
            0x251e,
            0x2520,
            0x2521,
            0x2523,
            0x2526,
            0x2528,
            0x2529,
            0x252b,
            0x2538,
            0x2539,
            0x253a,
            0x253b,
            0x2540,
            0x2542,
            0x2543,
            0x2544,
            0x2547,
            0x2549,
            0x254a,
            0x254b,
            0x2579,
            0x257f,
            => .heavy,
            else => .none,
        },
        .bottom => switch (cp) {
            0x2502,
            0x250c,
            0x250d,
            0x2510,
            0x2511,
            0x251c,
            0x251d,
            0x251e,
            0x2521,
            0x2524,
            0x2525,
            0x2526,
            0x2529,
            0x252c,
            0x252d,
            0x252e,
            0x252f,
            0x253c,
            0x253d,
            0x253e,
            0x253f,
            0x2540,
            0x2543,
            0x2544,
            0x2547,
            0x2577,
            0x257f,
            => .light,
            0x2503,
            0x250e,
            0x250f,
            0x2512,
            0x2513,
            0x251f,
            0x2520,
            0x2522,
            0x2523,
            0x2527,
            0x2528,
            0x252a,
            0x252b,
            0x2530,
            0x2531,
            0x2532,
            0x2533,
            0x2541,
            0x2542,
            0x2545,
            0x2546,
            0x2548,
            0x2549,
            0x254a,
            0x254b,
            0x257b,
            0x257d,
            => .heavy,
            else => .none,
        },
    };
}

fn doubleSides(cp: u21) Sides {
    return switch (cp) {
        0x2550 => .{ .left = .double, .right = .double },
        0x2551 => .{ .top = .double, .bottom = .double },
        0x2552 => .{ .right = .double, .bottom = .light },
        0x2553 => .{ .right = .light, .bottom = .double },
        0x2554 => .{ .right = .double, .bottom = .double },
        0x2555 => .{ .left = .double, .bottom = .light },
        0x2556 => .{ .left = .light, .bottom = .double },
        0x2557 => .{ .left = .double, .bottom = .double },
        0x2558 => .{ .right = .double, .top = .light },
        0x2559 => .{ .right = .light, .top = .double },
        0x255a => .{ .right = .double, .top = .double },
        0x255b => .{ .left = .double, .top = .light },
        0x255c => .{ .left = .light, .top = .double },
        0x255d => .{ .left = .double, .top = .double },
        0x255e => .{ .right = .double, .top = .light, .bottom = .light },
        0x255f => .{ .right = .light, .top = .double, .bottom = .double },
        0x2560 => .{ .right = .double, .top = .double, .bottom = .double },
        0x2561 => .{ .left = .double, .top = .light, .bottom = .light },
        0x2562 => .{ .left = .light, .top = .double, .bottom = .double },
        0x2563 => .{ .left = .double, .top = .double, .bottom = .double },
        0x2564 => .{ .left = .double, .right = .double, .bottom = .light },
        0x2565 => .{ .left = .light, .right = .light, .bottom = .double },
        0x2566 => .{ .left = .double, .right = .double, .bottom = .double },
        0x2567 => .{ .left = .double, .right = .double, .top = .light },
        0x2568 => .{ .left = .light, .right = .light, .top = .double },
        0x2569 => .{ .left = .double, .right = .double, .top = .double },
        0x256a => .{ .left = .double, .right = .double, .top = .light, .bottom = .light },
        0x256b => .{ .left = .light, .right = .light, .top = .double, .bottom = .double },
        0x256c => .{ .left = .double, .right = .double, .top = .double, .bottom = .double },
        else => unreachable,
    };
}

fn strokeSize(width: u32) u32 {
    const rounded: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(width)) / 8.0));
    return @max(rounded, 1);
}

fn strokeWidth(stroke: Stroke, light: u32) u32 {
    return switch (stroke) {
        .none => 0,
        .light, .double => light,
        .heavy => light * 2,
    };
}

fn rasterizeSides(bytes: []u8, width: u32, height: u32, sides: Sides) void {
    const light = strokeSize(width);
    const cx = width / 2;
    const cy = height / 2;
    const vertical_joint = unionStrokeBounds(sides.top, sides.bottom, cx, light, width);
    const horizontal_joint = unionStrokeBounds(sides.left, sides.right, cy, light, height);

    drawHorizontalBranch(bytes, width, height, 0, vertical_joint.end, cy, sides.left, light);
    drawHorizontalBranch(bytes, width, height, vertical_joint.start, width, cy, sides.right, light);
    drawVerticalBranch(bytes, width, height, 0, horizontal_joint.end, cx, sides.top, light);
    drawVerticalBranch(bytes, width, height, horizontal_joint.start, height, cx, sides.bottom, light);
}

fn drawHorizontalBranch(
    bytes: []u8,
    width: u32,
    height: u32,
    x0: u32,
    x1: u32,
    center_y: u32,
    stroke: Stroke,
    light: u32,
) void {
    if (stroke == .none or x1 <= x0) return;
    if (stroke == .double) {
        const bands = doubleBands(center_y, light, height);
        fillRect(bytes, width, height, x0, bands.first.start, x1 - x0, bands.first.size);
        fillRect(bytes, width, height, x0, bands.second.start, x1 - x0, bands.second.size);
    } else {
        const band = centeredBand(center_y, strokeWidth(stroke, light), height);
        fillRect(bytes, width, height, x0, band.start, x1 - x0, band.size);
    }
}

fn drawVerticalBranch(
    bytes: []u8,
    width: u32,
    height: u32,
    y0: u32,
    y1: u32,
    center_x: u32,
    stroke: Stroke,
    light: u32,
) void {
    if (stroke == .none or y1 <= y0) return;
    if (stroke == .double) {
        const bands = doubleBands(center_x, light, width);
        fillRect(bytes, width, height, bands.first.start, y0, bands.first.size, y1 - y0);
        fillRect(bytes, width, height, bands.second.start, y0, bands.second.size, y1 - y0);
    } else {
        const band = centeredBand(center_x, strokeWidth(stroke, light), width);
        fillRect(bytes, width, height, band.start, y0, band.size, y1 - y0);
    }
}

const Band = struct { start: u32, size: u32 };
const BandPair = struct { first: Band, second: Band };
const Bounds = struct { start: u32, end: u32 };

fn centeredBand(center: u32, size: u32, limit: u32) Band {
    const actual = @min(@max(size, 1), limit);
    const start = @min(center -| actual / 2, limit - actual);
    return .{ .start = start, .size = actual };
}

fn doubleBands(center: u32, light: u32, limit: u32) BandPair {
    const rule = @min(@max(light, 1), limit);
    const gap = @max(light, 1);
    const total = @min(rule * 2 + gap, limit);
    const start = @min(center -| total / 2, limit - total);
    const second_start = @min(start + rule + gap, limit - rule);
    return .{
        .first = .{ .start = start, .size = rule },
        .second = .{ .start = second_start, .size = rule },
    };
}

fn strokeBounds(stroke: Stroke, center: u32, light: u32, limit: u32) ?Bounds {
    if (stroke == .none) return null;
    if (stroke == .double) {
        const bands = doubleBands(center, light, limit);
        return .{
            .start = @min(bands.first.start, bands.second.start),
            .end = @max(bands.first.start + bands.first.size, bands.second.start + bands.second.size),
        };
    }
    const band = centeredBand(center, strokeWidth(stroke, light), limit);
    return .{ .start = band.start, .end = band.start + band.size };
}

fn unionStrokeBounds(a: Stroke, b: Stroke, center: u32, light: u32, limit: u32) Bounds {
    const first = strokeBounds(a, center, light, limit);
    const second = strokeBounds(b, center, light, limit);
    if (first) |one| {
        if (second) |two| return .{
            .start = @min(one.start, two.start),
            .end = @max(one.end, two.end),
        };
        return one;
    }
    if (second) |two| return two;
    return .{ .start = center, .end = @min(center + 1, limit) };
}

fn rasterizeDashes(bytes: []u8, width: u32, height: u32, dash: Dash) void {
    const light = strokeSize(width);
    const thickness = strokeWidth(dash.stroke, light);
    const extent = if (dash.vertical) height else width;
    const gap_count: u32 = dash.segments - 1;
    const gap = @max(extent / 8, 1);
    const ink = extent -| gap * gap_count;
    const segment_base = @max(ink / dash.segments, 1);
    const extra_pixels = ink -| segment_base * dash.segments;
    var i: u32 = 0;
    var cursor: u32 = 0;
    while (i < dash.segments) : (i += 1) {
        const segment = if (i + 1 == dash.segments)
            extent - cursor
        else
            segment_base + @intFromBool(i < extra_pixels);
        if (dash.vertical) {
            const band = centeredBand(width / 2, thickness, width);
            fillRect(bytes, width, height, band.start, cursor, band.size, segment);
        } else {
            const band = centeredBand(height / 2, thickness, height);
            fillRect(bytes, width, height, cursor, band.start, segment, band.size);
        }
        cursor = @min(cursor + segment, extent);
        if (i + 1 < dash.segments) cursor = @min(cursor + gap, extent);
    }
}

fn fillRect(
    bytes: []u8,
    canvas_width: u32,
    canvas_height: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
) void {
    const x_end = @min(x +| width, canvas_width);
    const y_end = @min(y +| height, canvas_height);
    var row = y;
    while (row < y_end) : (row += 1) {
        const start = @as(usize, row) * canvas_width + x;
        const end = @as(usize, row) * canvas_width + x_end;
        @memset(bytes[start..end], 255);
    }
}

fn rasterizeRounded(bytes: []u8, width: u32, height: u32, cp: u21) void {
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            bytes[@as(usize, y) * width + x] = roundedCoverage(cp, x, y, width, height);
        }
    }
}

fn roundedCoverage(cp: u21, pixel_x: u32, pixel_y: u32, width: u32, height: u32) u8 {
    const samples: u32 = 4;
    var covered: u32 = 0;
    var sy: u32 = 0;
    while (sy < samples) : (sy += 1) {
        var sx: u32 = 0;
        while (sx < samples) : (sx += 1) {
            const x = @as(f32, @floatFromInt(pixel_x)) +
                (@as(f32, @floatFromInt(sx)) + 0.5) / @as(f32, @floatFromInt(samples));
            const y = @as(f32, @floatFromInt(pixel_y)) +
                (@as(f32, @floatFromInt(sy)) + 0.5) / @as(f32, @floatFromInt(samples));
            if (roundedSampleCovered(cp, x, y, width, height)) covered += 1;
        }
    }
    return @intCast((covered * 255) / (samples * samples));
}

fn roundedSampleCovered(cp: u21, sample_x: f32, sample_y: f32, width: u32, height: u32) bool {
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    var x = sample_x;
    var y = sample_y;

    // Canonical orientation is ╭ (right connector curving into bottom).
    if (cp == 0x256e or cp == 0x256f) x = w - x;
    if (cp == 0x256f or cp == 0x2570) y = h - y;

    const cx = w / 2.0;
    const cy = h / 2.0;
    const radius = @min(w, h) / 2.0;
    const arc_x = cx + radius;
    const arc_y = cy + radius;
    const half_stroke = @as(f32, @floatFromInt(strokeSize(width))) / 2.0;

    if (pointSegmentDistanceSquared(x, y, arc_x, cy, w, cy) <= half_stroke * half_stroke)
        return true;
    if (pointSegmentDistanceSquared(x, y, cx, arc_y, cx, h) <= half_stroke * half_stroke)
        return true;

    const dx = x - arc_x;
    const dy = y - arc_y;
    if (dx > half_stroke or dy > half_stroke) return false;
    const distance = @sqrt(dx * dx + dy * dy);
    return @abs(distance - radius) <= half_stroke;
}

fn rasterizeDiagonal(bytes: []u8, width: u32, height: u32, cp: u21) void {
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            bytes[@as(usize, y) * width + x] = diagonalCoverage(cp, x, y, width, height);
        }
    }
}

fn diagonalCoverage(cp: u21, pixel_x: u32, pixel_y: u32, width: u32, height: u32) u8 {
    const samples: u32 = 4;
    const half_stroke = @as(f32, @floatFromInt(strokeSize(width))) / 2.0;
    const threshold = half_stroke * half_stroke;
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    var covered: u32 = 0;
    var sy: u32 = 0;
    while (sy < samples) : (sy += 1) {
        var sx: u32 = 0;
        while (sx < samples) : (sx += 1) {
            const x = @as(f32, @floatFromInt(pixel_x)) +
                (@as(f32, @floatFromInt(sx)) + 0.5) / @as(f32, @floatFromInt(samples));
            const y = @as(f32, @floatFromInt(pixel_y)) +
                (@as(f32, @floatFromInt(sy)) + 0.5) / @as(f32, @floatFromInt(samples));
            const rising = pointSegmentDistanceSquared(x, y, 0, h, w, 0) <= threshold;
            const falling = pointSegmentDistanceSquared(x, y, 0, 0, w, h) <= threshold;
            if ((cp == 0x2571 and rising) or
                (cp == 0x2572 and falling) or
                (cp == 0x2573 and (rising or falling))) covered += 1;
        }
    }
    return @intCast((covered * 255) / (samples * samples));
}

fn rasterizeBlock(bytes: []u8, width: u32, height: u32, cp: u21) void {
    switch (cp) {
        0x2580 => fillRect(bytes, width, height, 0, 0, width, fraction(height, 4)),
        0x2581...0x2587 => {
            const amount: u32 = @intCast(cp - 0x2580);
            const block_height = fraction(height, amount);
            fillRect(bytes, width, height, 0, height - block_height, width, block_height);
        },
        0x2588 => @memset(bytes, 255),
        0x2589...0x258f => {
            const amount: u32 = @intCast(8 - (cp - 0x2588));
            fillRect(bytes, width, height, 0, 0, fraction(width, amount), height);
        },
        0x2590 => {
            const block_width = fraction(width, 4);
            fillRect(bytes, width, height, width - block_width, 0, block_width, height);
        },
        0x2591 => @memset(bytes, 64),
        0x2592 => @memset(bytes, 128),
        0x2593 => @memset(bytes, 192),
        0x2594 => fillRect(bytes, width, height, 0, 0, width, fraction(height, 1)),
        0x2595 => {
            const block_width = fraction(width, 1);
            fillRect(bytes, width, height, width - block_width, 0, block_width, height);
        },
        0x2596...0x259f => rasterizeQuadrants(bytes, width, height, quadrantMask(cp)),
        else => unreachable,
    }
}

fn fraction(extent: u32, eighths: u32) u32 {
    return @min(@max((extent * eighths + 4) / 8, 1), extent);
}

fn quadrantMask(cp: u21) u4 {
    // Bits are upper-left, upper-right, lower-left, lower-right.
    return switch (cp) {
        0x2596 => 0b0100,
        0x2597 => 0b1000,
        0x2598 => 0b0001,
        0x2599 => 0b1101,
        0x259a => 0b1001,
        0x259b => 0b0111,
        0x259c => 0b1011,
        0x259d => 0b0010,
        0x259e => 0b0110,
        0x259f => 0b1110,
        else => unreachable,
    };
}

fn rasterizeQuadrants(bytes: []u8, width: u32, height: u32, mask: u4) void {
    const left_width = (width + 1) / 2;
    const top_height = (height + 1) / 2;
    if (mask & 0b0001 != 0) fillRect(bytes, width, height, 0, 0, left_width, top_height);
    if (mask & 0b0010 != 0) fillRect(bytes, width, height, left_width, 0, width - left_width, top_height);
    if (mask & 0b0100 != 0) fillRect(bytes, width, height, 0, top_height, left_width, height - top_height);
    if (mask & 0b1000 != 0) fillRect(bytes, width, height, left_width, top_height, width - left_width, height - top_height);
}

fn pointSegmentDistanceSquared(
    px: f32,
    py: f32,
    ax: f32,
    ay: f32,
    bx: f32,
    by: f32,
) f32 {
    const vx = bx - ax;
    const vy = by - ay;
    const length_squared = vx * vx + vy * vy;
    if (length_squared == 0) {
        const dx = px - ax;
        const dy = py - ay;
        return dx * dx + dy * dy;
    }
    const projection = @min(@max(((px - ax) * vx + (py - ay) * vy) / length_squared, 0), 1);
    const dx = px - (ax + projection * vx);
    const dy = py - (ay + projection * vy);
    return dx * dx + dy * dy;
}

fn pixel(bitmap: Bitmap, x: u32, y: u32) u8 {
    return bitmap.bytes[@as(usize, y) * bitmap.width + x];
}

fn inkCount(bitmap: Bitmap) usize {
    var count: usize = 0;
    for (bitmap.bytes) |value| {
        if (value != 0) count += 1;
    }
    return count;
}

fn horizontalRuns(bitmap: Bitmap, y: u32) usize {
    var runs: usize = 0;
    var inside = false;
    var x: u32 = 0;
    while (x < bitmap.width) : (x += 1) {
        const inked = pixel(bitmap, x, y) != 0;
        if (inked and !inside) runs += 1;
        inside = inked;
    }
    return runs;
}

fn verticalRuns(bitmap: Bitmap, x: u32) usize {
    var runs: usize = 0;
    var inside = false;
    var y: u32 = 0;
    while (y < bitmap.height) : (y += 1) {
        const inked = pixel(bitmap, x, y) != 0;
        if (inked and !inside) runs += 1;
        inside = inked;
    }
    return runs;
}

fn expectAsciiGolden(bitmap: Bitmap, expected: []const u8) !void {
    var pixel_index: usize = 0;
    for (expected) |expected_pixel| {
        if (expected_pixel == '\n') continue;
        try std.testing.expect(pixel_index < bitmap.bytes.len);
        const actual: u8 = if (bitmap.bytes[pixel_index] == 0) '.' else '#';
        try std.testing.expectEqual(expected_pixel, actual);
        pixel_index += 1;
    }
    try std.testing.expectEqual(bitmap.bytes.len, pixel_index);
}

test "built-in box and block range is exhaustive" {
    const alloc = std.testing.allocator;
    var cp: u21 = 0x2500;
    while (cp <= 0x259f) : (cp += 1) {
        try std.testing.expect(supports(cp));
        var bitmap = try rasterize(alloc, cp, 16, 30);
        defer bitmap.deinit(alloc);
        try std.testing.expect(inkCount(bitmap) > 0);
    }
    try std.testing.expect(!supports(0x24ff));
    try std.testing.expect(!supports(0x25a0));
    try std.testing.expectError(
        error.UnsupportedBoxDrawing,
        rasterize(alloc, 0x25a0, 16, 30),
    );
}

test "light heavy and double rules remain distinct" {
    const alloc = std.testing.allocator;
    var light = try rasterize(alloc, 0x2500, 16, 30);
    defer light.deinit(alloc);
    var heavy = try rasterize(alloc, 0x2501, 16, 30);
    defer heavy.deinit(alloc);
    var double = try rasterize(alloc, 0x2550, 16, 30);
    defer double.deinit(alloc);

    try std.testing.expect(inkCount(heavy) > inkCount(light));
    try std.testing.expect(inkCount(double) > inkCount(light));
    try std.testing.expect(pixel(light, 0, 15) > 0);
    try std.testing.expect(pixel(heavy, 15, 15) > 0);
    try std.testing.expect(pixel(double, 0, 12) > 0);
    try std.testing.expect(pixel(double, 15, 17) > 0);
}

test "dash variants preserve their segment count" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { cp: u21, vertical: bool, segments: usize }{
        .{ .cp = 0x254c, .vertical = false, .segments = 2 },
        .{ .cp = 0x2504, .vertical = false, .segments = 3 },
        .{ .cp = 0x2508, .vertical = false, .segments = 4 },
        .{ .cp = 0x254e, .vertical = true, .segments = 2 },
        .{ .cp = 0x2506, .vertical = true, .segments = 3 },
        .{ .cp = 0x250a, .vertical = true, .segments = 4 },
    };
    for (cases) |case| {
        var bitmap = try rasterize(alloc, case.cp, 32, 32);
        defer bitmap.deinit(alloc);
        const runs = if (case.vertical)
            verticalRuns(bitmap, bitmap.width / 2)
        else
            horizontalRuns(bitmap, bitmap.height / 2);
        try std.testing.expectEqual(case.segments, runs);
    }
}

test "representative cell rasters match exact geometry goldens" {
    const alloc = std.testing.allocator;
    var corner = try rasterize(alloc, 0x250c, 8, 8);
    defer corner.deinit(alloc);
    try expectAsciiGolden(corner,
        \\........
        \\........
        \\........
        \\........
        \\....####
        \\....#...
        \\....#...
        \\....#...
    );

    var double_rule = try rasterize(alloc, 0x2550, 8, 8);
    defer double_rule.deinit(alloc);
    try expectAsciiGolden(double_rule,
        \\........
        \\........
        \\........
        \\########
        \\........
        \\########
        \\........
        \\........
    );

    var quadrant = try rasterize(alloc, 0x2598, 8, 8);
    defer quadrant.deinit(alloc);
    try expectAsciiGolden(quadrant,
        \\####....
        \\####....
        \\####....
        \\####....
        \\........
        \\........
        \\........
        \\........
    );
}

test "Codex rounded corners connect to the correct two edges" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { cp: u21, left: bool, right: bool, top: bool, bottom: bool }{
        .{ .cp = 0x256d, .left = false, .right = true, .top = false, .bottom = true },
        .{ .cp = 0x256e, .left = true, .right = false, .top = false, .bottom = true },
        .{ .cp = 0x256f, .left = true, .right = false, .top = true, .bottom = false },
        .{ .cp = 0x2570, .left = false, .right = true, .top = true, .bottom = false },
    };
    for (cases) |case| {
        var bitmap = try rasterize(alloc, case.cp, 16, 30);
        defer bitmap.deinit(alloc);
        try std.testing.expectEqual(case.left, pixel(bitmap, 0, 15) > 0);
        try std.testing.expectEqual(case.right, pixel(bitmap, 15, 15) > 0);
        try std.testing.expectEqual(case.top, pixel(bitmap, 8, 0) > 0);
        try std.testing.expectEqual(case.bottom, pixel(bitmap, 8, 29) > 0);
    }
}

test "fractional blocks shades and quadrants have exact cell coverage" {
    const alloc = std.testing.allocator;
    var lower_eighth = try rasterize(alloc, 0x2581, 16, 32);
    defer lower_eighth.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 16 * 4), inkCount(lower_eighth));

    var medium_shade = try rasterize(alloc, 0x2592, 16, 32);
    defer medium_shade.deinit(alloc);
    for (medium_shade.bytes) |value| try std.testing.expectEqual(@as(u8, 128), value);

    var upper_left = try rasterize(alloc, 0x2598, 16, 32);
    defer upper_left.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 8 * 16), inkCount(upper_left));
    try std.testing.expect(pixel(upper_left, 0, 0) > 0);
    try std.testing.expectEqual(@as(u8, 0), pixel(upper_left, 15, 31));
}
