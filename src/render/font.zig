//! Terminal font handling: one monospace face plus a per-codepoint
//! fallback cascade (CTFontCreateForString), and CoreText rasterization into
//! grayscale masks or premultiplied RGBA color glyphs. Scalar cells take the
//! direct glyph path; shaping is confined to one grapheme cluster (RFC 0004).

const std = @import("std");
const objc = @import("objc.zig");
const ct = @import("coretext.zig");
const box_drawing = @import("box_drawing.zig");

const builtin_font_index = std.math.maxInt(u16);
const style_count = std.meta.fields(Style).len;

pub const Options = struct {
    family: ?[]const u8 = null,
    size: f32 = 13,
};

pub const Style = enum(u2) {
    regular,
    bold,
    italic,
    bold_italic,

    pub fn fromFlags(bold: bool, italic: bool) Style {
        if (bold) return if (italic) .bold_italic else .bold;
        return if (italic) .italic else .regular;
    }

    fn traits(self: Style) u32 {
        return switch (self) {
            .regular => 0,
            .bold => ct.FontTrait.bold,
            .italic => ct.FontTrait.italic,
            .bold_italic => ct.FontTrait.bold | ct.FontTrait.italic,
        };
    }
};

pub const GlyphRef = struct {
    /// Index into FontSet.fonts.
    font: u16,
    glyph: u16,
    /// Requested terminal style remains part of the atlas identity even when
    /// lookup falls back to the regular face. RFC 0004's later synthetic
    /// style pass needs this distinction.
    style: Style,
    /// VT-declared cell span. Color glyph constraints depend on this and the
    /// atlas must not reuse a one-cell raster for a two-cell presentation.
    cell_cols: u2,
};

pub const RasterFormat = enum {
    mask,
    color,

    pub fn depth(self: RasterFormat) usize {
        return switch (self) {
            .mask => 1,
            .color => 4,
        };
    }
};

const RasterContext = struct {
    context: objc.Id,
    color_space: objc.Id,

    fn init(bytes: []u8, width: u32, height: u32, format: RasterFormat) !RasterContext {
        const color_space = if (format == .color)
            ct.CGColorSpaceCreateDeviceRGB()
        else
            ct.CGColorSpaceCreateDeviceGray();
        errdefer ct.CGColorSpaceRelease(color_space);
        const bitmap_info = if (format == .color)
            ct.BitmapInfo.byte_order_32_big | ct.BitmapInfo.premultiplied_last
        else
            ct.AlphaInfo.none;
        const context = ct.CGBitmapContextCreate(
            bytes.ptr,
            width,
            height,
            8,
            @as(usize, width) * format.depth(),
            color_space,
            bitmap_info,
        );
        if (context == null) return error.BitmapContext;

        ct.CGContextSetAllowsFontSmoothing(context, true);
        ct.CGContextSetShouldAntialias(context, true);
        // Subpixel smoothing would either leak color fringes into a mask or
        // interfere with an embedded color bitmap.
        ct.CGContextSetShouldSmoothFonts(context, false);
        if (format == .color)
            ct.CGContextSetRGBFillColor(context, 1.0, 1.0, 1.0, 1.0)
        else
            ct.CGContextSetGrayFillColor(context, 1.0, 1.0);
        return .{ .context = context, .color_space = color_space };
    }

    fn deinit(self: *RasterContext) void {
        ct.CGContextRelease(self.context);
        ct.CGColorSpaceRelease(self.color_space);
    }

    fn enableSyntheticBold(self: *RasterContext, line_width: f64) void {
        ct.CGContextSetGrayStrokeColor(self.context, 1.0, 1.0);
        ct.CGContextSetLineWidth(self.context, line_width);
        ct.CGContextSetTextDrawingMode(self.context, .fill_stroke);
    }
};

pub const GlyphRaster = struct {
    /// A one-byte coverage mask or premultiplied RGBA8 bitmap. Row 0 is at
    /// the top; `format.depth()` gives the byte stride per pixel.
    bytes: []u8,
    format: RasterFormat,
    width: u32,
    height: u32,
    /// Offset in points from the pen position to the bitmap's top-left;
    /// bearing_y is negative for ink above the baseline.
    bearing_x: f32,
    bearing_y: f32,

    pub fn deinit(self: *GlyphRaster, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

pub const Metrics = struct {
    cell_width: f32,
    cell_height: f32,
    /// Baseline offset from the cell top.
    ascent: f32,
};

pub const FontSet = struct {
    alloc: std.mem.Allocator,
    /// The first four entries are regular/bold/italic/bold-italic in Style
    /// order. Missing real variants retain the regular face. Later entries
    /// are regular fallback faces discovered at runtime and deduped via
    /// CFEqual.
    fonts: std.ArrayList(objc.Id) = .empty,
    real_styles: [style_count]bool = .{ true, false, false, false },
    fallback_cache: std.AutoHashMapUnmanaged(u21, u16) = .empty,
    metrics: Metrics,

    pub fn init(alloc: std.mem.Allocator, options: Options) !FontSet {
        const ns_font = if (options.family) |family|
            try configuredFont(alloc, family, options.size)
        else
            systemMonospacedFont(options.size);
        if (ns_font == null) return error.FontLoad;
        const base = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
            ns_font,
            objc.sel("retain"),
        );

        const ascent: f32 = @floatCast(ct.CTFontGetAscent(base));
        const descent: f32 = @floatCast(ct.CTFontGetDescent(base));
        const leading: f32 = @floatCast(ct.CTFontGetLeading(base));

        // Monospace advance from 'M'.
        var m: u16 = 'M';
        var glyph: ct.CGGlyph = 0;
        _ = ct.CTFontGetGlyphsForCharacters(base, @ptrCast(&m), @ptrCast(&glyph), 1);
        const advance = ct.CTFontGetAdvancesForGlyphs(base, .horizontal, @ptrCast(&glyph), null, 1);

        var self: FontSet = .{
            .alloc = alloc,
            .metrics = .{
                .cell_width = @floatCast(advance),
                .cell_height = @ceil(ascent + descent + leading),
                .ascent = ascent,
            },
        };
        errdefer self.deinit();
        self.fonts.append(alloc, base) catch |err| {
            ct.CFRelease(base);
            return err;
        };
        const bold = styledFace(base, .bold, @floatCast(advance)) orelse retainFont(base);
        self.fonts.append(alloc, bold) catch |err| {
            ct.CFRelease(bold);
            return err;
        };
        self.real_styles[@intFromEnum(Style.bold)] = ct.CFEqual(bold, base) == 0;

        const italic = styledFace(base, .italic, @floatCast(advance)) orelse retainFont(base);
        self.fonts.append(alloc, italic) catch |err| {
            ct.CFRelease(italic);
            return err;
        };
        self.real_styles[@intFromEnum(Style.italic)] = ct.CFEqual(italic, base) == 0;

        // If the exact combined face is unavailable, preserve a real partial
        // axis and synthesize only the missing one during rasterization.
        const bold_italic = styledFace(base, .bold_italic, @floatCast(advance)) orelse retainFont(
            if (self.real_styles[@intFromEnum(Style.bold)])
                bold
            else if (self.real_styles[@intFromEnum(Style.italic)])
                italic
            else
                base,
        );
        self.fonts.append(alloc, bold_italic) catch |err| {
            ct.CFRelease(bold_italic);
            return err;
        };
        self.real_styles[@intFromEnum(Style.bold_italic)] =
            ct.CTFontGetSymbolicTraits(bold_italic) &
            (ct.FontTrait.bold | ct.FontTrait.italic) == Style.bold_italic.traits();
        return self;
    }

    pub fn deinit(self: *FontSet) void {
        for (self.fonts.items) |f| ct.CFRelease(f);
        self.fonts.deinit(self.alloc);
        self.fallback_cache.deinit(self.alloc);
    }

    /// Resolve a codepoint to (font, glyph). Returns null when nothing in
    /// the cascade can draw it — the caller leaves the cell blank.
    pub fn hasRealStyle(self: *const FontSet, style: Style) bool {
        return self.real_styles[@intFromEnum(style)];
    }

    /// Convert a font-relative top bearing into the terminal cell's Y
    /// coordinate. The regular face owns this one baseline for every style
    /// and fallback face.
    pub fn cellTopForBearing(self: *const FontSet, bearing_y: f32) f32 {
        return self.metrics.ascent + bearing_y;
    }

    pub fn glyphFor(self: *FontSet, cp: u21, style: Style, cell_cols: u2) ?GlyphRef {
        std.debug.assert(cell_cols == 1 or cell_cols == 2);
        if (box_drawing.supports(cp)) {
            return .{ .font = builtin_font_index, .glyph = @intCast(cp), .style = style, .cell_cols = cell_cols };
        }

        var units: [2]u16 = undefined;
        const n = utf16Encode(cp, &units);
        const style_idx: u16 = @intFromEnum(style);

        if (lookup(self.fonts.items[style_idx], units[0..n])) |g| {
            return .{ .font = style_idx, .glyph = g, .style = style, .cell_cols = cell_cols };
        }

        // Prefer the configured family's regular glyph to a styled glyph
        // from an unrelated fallback family (Ghostty CodepointResolver step
        // 5). This keeps the terminal's cell metrics stable.
        if (style != .regular) {
            if (lookup(self.fonts.items[0], units[0..n])) |g| {
                return .{ .font = 0, .glyph = g, .style = style, .cell_cols = cell_cols };
            }
        }

        if (self.fallback_cache.get(cp)) |idx| {
            if (lookup(self.fonts.items[idx], units[0..n])) |g| {
                return .{ .font = idx, .glyph = g, .style = style, .cell_cols = cell_cols };
            }
            return null;
        }

        const idx = self.discoverFallback(cp, units[0..n]) orelse return null;
        self.fallback_cache.put(self.alloc, cp, idx) catch {};
        if (lookup(self.fonts.items[idx], units[0..n])) |g| {
            return .{ .font = idx, .glyph = g, .style = style, .cell_cols = cell_cols };
        }
        return null;
    }

    fn discoverFallback(self: *FontSet, cp: u21, units: []const u16) ?u16 {
        _ = cp;
        const ns_str = objc.msg(
            *const fn (objc.Class, objc.Sel, [*]const u16, objc.NSUInteger) callconv(.c) objc.Id,
        )(
            objc.cls("NSString"),
            objc.sel("stringWithCharacters:length:"),
            units.ptr,
            units.len,
        );
        if (ns_str == null) return null;

        const found = ct.CTFontCreateForString(
            self.fonts.items[0],
            ns_str,
            .{ .location = 0, .length = @intCast(units.len) },
        );
        if (found == null) return null;

        // Dedupe: the cascade returns the same few faces over and over.
        for (self.fonts.items, 0..) |f, i| {
            if (ct.CFEqual(found, f) != 0) {
                ct.CFRelease(found);
                return @intCast(i);
            }
        }
        self.fonts.append(self.alloc, found) catch {
            ct.CFRelease(found);
            return null;
        };
        return @intCast(self.fonts.items.len - 1);
    }

    /// Rasterize a scalar at `pixel_scale` px/pt. Text produces a coverage
    /// mask; a color-glyph face produces premultiplied RGBA8.
    pub fn rasterize(
        self: *const FontSet,
        ref: GlyphRef,
        pixel_scale: f32,
        allocator: std.mem.Allocator,
    ) !GlyphRaster {
        if (isBuiltin(ref)) {
            const width: u32 = @intFromFloat(@ceil(self.metrics.cell_width * pixel_scale));
            const height: u32 = @intFromFloat(@ceil(self.metrics.cell_height * pixel_scale));
            const bitmap = try box_drawing.rasterize(allocator, @intCast(ref.glyph), width, height);
            return .{
                .bytes = bitmap.bytes,
                .format = .mask,
                .width = bitmap.width,
                .height = bitmap.height,
                .bearing_x = 0,
                .bearing_y = -self.metrics.ascent,
            };
        }

        const font = self.fonts.items[ref.font];
        const glyph: ct.CGGlyph = ref.glyph;
        const format: RasterFormat = if (fontHasColorGlyphs(font)) .color else .mask;
        const synthetic = if (format == .mask) missingStyleAxes(font, ref.style) else SyntheticAxes{};
        const synthetic_bold_width = if (synthetic.bold) syntheticBoldWidth(font) else 0;
        var synthetic_italic_font: ?objc.Id = null;
        defer if (synthetic_italic_font) |owned| ct.CFRelease(owned);
        const render_font = if (synthetic.italic) blk: {
            const transformed = syntheticItalicFont(font) orelse return error.FontLoad;
            synthetic_italic_font = transformed;
            break :blk transformed;
        } else font;

        var bbox: ct.CGRect = .{};
        _ = ct.CTFontGetBoundingRectsForGlyphs(render_font, .horizontal, @ptrCast(&glyph), @ptrCast(&bbox), 1);
        if (synthetic.bold) {
            const half_stroke = synthetic_bold_width / 2;
            bbox.origin.x -= half_stroke;
            bbox.origin.y -= half_stroke;
            bbox.size.width += synthetic_bold_width;
            bbox.size.height += synthetic_bold_width;
        }

        const scale_d: f64 = @floatCast(pixel_scale);

        // Pixel-align with one pixel of padding: smoothing rasterizes ink
        // slightly past the path bounds (see webmotion's font.zig).
        const min_px_x: f64 = @floor(bbox.origin.x * scale_d) - 1;
        const max_px_x: f64 = @ceil((bbox.origin.x + bbox.size.width) * scale_d) + 1;
        const min_px_y: f64 = @floor(bbox.origin.y * scale_d) - 1;
        const max_px_y: f64 = @ceil((bbox.origin.y + bbox.size.height) * scale_d) + 1;

        const raw_w = max_px_x - min_px_x;
        const raw_h = max_px_y - min_px_y;
        const w: u32 = if (raw_w < 1) 1 else @intFromFloat(raw_w);
        const h: u32 = if (raw_h < 1) 1 else @intFromFloat(raw_h);

        const bytes = try allocator.alloc(u8, @as(usize, w) * @as(usize, h) * format.depth());
        errdefer allocator.free(bytes);
        @memset(bytes, 0);

        if (bbox.size.width <= 0 or bbox.size.height <= 0) {
            return .{ .bytes = bytes, .format = format, .width = w, .height = h, .bearing_x = 0, .bearing_y = 0 };
        }

        var raster_context = try RasterContext.init(bytes, w, h, format);
        defer raster_context.deinit();
        ct.CGContextScaleCTM(raster_context.context, scale_d, scale_d);
        if (synthetic.bold) raster_context.enableSyntheticBold(synthetic_bold_width);

        const pos: ct.CGPoint = .{ .x = -min_px_x / scale_d, .y = -min_px_y / scale_d };
        ct.CTFontDrawGlyphs(render_font, @ptrCast(&glyph), @ptrCast(&pos), 1, raster_context.context);

        const raster: GlyphRaster = .{
            .bytes = bytes,
            .format = format,
            .width = w,
            .height = h,
            .bearing_x = @floatCast(min_px_x / scale_d),
            .bearing_y = -@as(f32, @floatCast(max_px_y / scale_d)),
        };
        if (format == .color) {
            return constrainColorRaster(raster, self.metrics, ref.cell_cols, pixel_scale, allocator);
        }
        return raster;
    }

    /// Shape and rasterize exactly one grapheme cluster. This never enables
    /// cross-cell ligatures: the result is clipped to the cluster's declared
    /// one- or two-cell terminal box (RFC 0004).
    pub fn rasterizeCluster(
        self: *const FontSet,
        utf8: []const u8,
        cell_cols: u2,
        style: Style,
        pixel_scale: f32,
        allocator: std.mem.Allocator,
    ) !GlyphRaster {
        std.debug.assert(cell_cols == 1 or cell_cols == 2);
        const text_z = try allocator.dupeZ(u8, utf8);
        defer allocator.free(text_z);
        const string = objc.nsString(text_z.ptr);
        if (string == null) return error.FontLoad;
        const font = self.fonts.items[@intFromEnum(style)];
        const base_line = try clusterLine(string, font);
        defer ct.CFRelease(base_line);
        var render_line = base_line;
        const format: RasterFormat = if (lineHasColorGlyphs(base_line)) .color else .mask;
        const synthetic = if (format == .mask) missingStyleAxes(font, style) else SyntheticAxes{};
        const synthetic_bold_width = if (synthetic.bold) syntheticBoldWidth(font) else 0;
        var synthetic_italic_font: ?objc.Id = null;
        defer if (synthetic_italic_font) |owned| ct.CFRelease(owned);
        var synthetic_italic_line: ?objc.Id = null;
        defer if (synthetic_italic_line) |owned| ct.CFRelease(owned);
        if (synthetic.italic) {
            const transformed = syntheticItalicFont(font) orelse return error.FontLoad;
            const transformed_line = clusterLine(string, transformed) catch |err| {
                ct.CFRelease(transformed);
                return err;
            };
            synthetic_italic_font = transformed;
            synthetic_italic_line = transformed_line;
            render_line = transformed_line;
        }

        const scale: f64 = @floatCast(pixel_scale);
        const cell_width = self.metrics.cell_width * @as(f32, @floatFromInt(cell_cols));
        const width: u32 = @max(1, @as(u32, @intFromFloat(@ceil(cell_width * pixel_scale))));
        const height: u32 = @max(1, @as(u32, @intFromFloat(@ceil(self.metrics.cell_height * pixel_scale))));
        const bytes = try allocator.alloc(u8, @as(usize, width) * height * format.depth());
        errdefer allocator.free(bytes);
        @memset(bytes, 0);

        var raster_context = try RasterContext.init(bytes, width, height, format);
        defer raster_context.deinit();
        ct.CGContextScaleCTM(raster_context.context, scale, scale);
        if (synthetic.bold) raster_context.enableSyntheticBold(synthetic_bold_width);
        ct.CGContextSetTextPosition(
            raster_context.context,
            0,
            @as(f64, self.metrics.cell_height - self.metrics.ascent),
        );
        ct.CTLineDraw(render_line, raster_context.context);

        const raster: GlyphRaster = .{
            .bytes = bytes,
            .format = format,
            .width = width,
            .height = height,
            .bearing_x = 0,
            .bearing_y = -self.metrics.ascent,
        };
        if (format == .color) {
            return constrainColorRaster(raster, self.metrics, cell_cols, pixel_scale, allocator);
        }
        return raster;
    }
};

const SyntheticAxes = packed struct {
    bold: bool = false,
    italic: bool = false,
};

fn missingStyleAxes(font: objc.Id, style: Style) SyntheticAxes {
    const traits = ct.CTFontGetSymbolicTraits(font);
    const requested = style.traits();
    return .{
        .bold = requested & ct.FontTrait.bold != 0 and traits & ct.FontTrait.bold == 0,
        .italic = requested & ct.FontTrait.italic != 0 and traits & ct.FontTrait.italic == 0,
    };
}

fn syntheticBoldWidth(font: objc.Id) f64 {
    return @max(ct.CTFontGetSize(font) / 14.0, 1.0);
}

fn syntheticItalicFont(font: objc.Id) ?objc.Id {
    // tan(15°), matching Ghostty's MIT-licensed CoreText backend.
    const matrix: ct.CGAffineTransform = .{ .c = 0.267949 };
    const transformed = ct.CTFontCreateCopyWithSymbolicTraits(font, 0, &matrix, 0, 0);
    return if (transformed == null) null else transformed;
}

fn clusterLine(string: objc.Id, font: objc.Id) !objc.Id {
    const attr_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSMutableAttributedString"),
        objc.sel("alloc"),
    );
    const attr = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        attr_alloc,
        objc.sel("initWithString:"),
        string,
    );
    if (attr == null) return error.FontLoad;
    defer objc.release(attr);

    const utf16_len = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSUInteger)(
        string,
        objc.sel("length"),
    );
    const range: objc.NSRange = .{ .location = 0, .length = utf16_len };
    const add_attribute = objc.msg(
        *const fn (objc.Id, objc.Sel, objc.Id, objc.Id, objc.NSRange) callconv(.c) void,
    );
    add_attribute(
        attr,
        objc.sel("addAttribute:value:range:"),
        ct.kCTFontAttributeName,
        font,
        range,
    );
    add_attribute(
        attr,
        objc.sel("addAttribute:value:range:"),
        ct.kCTForegroundColorFromContextAttributeName,
        ct.kCFBooleanTrue,
        range,
    );

    const line = ct.CTLineCreateWithAttributedString(attr);
    if (line == null) return error.FontLoad;
    return line;
}

const PixelBounds = struct {
    min_x: u32,
    min_y: u32,
    max_x: u32,
    max_y: u32,
};

/// Constrain premultiplied color artwork to the VT-declared cell span. This
/// mirrors Ghostty's emoji policy (MIT): cover the available box while
/// preserving aspect ratio, center on both axes, and keep a 2.5% horizontal
/// inset. `source` remains owned by the caller on error and is consumed on
/// success.
fn constrainColorRaster(
    source: GlyphRaster,
    metrics: Metrics,
    cell_cols: u2,
    pixel_scale: f32,
    allocator: std.mem.Allocator,
) !GlyphRaster {
    std.debug.assert(source.format == .color);
    const bounds = colorPixelBounds(source) orelse return source;
    const source_width = bounds.max_x - bounds.min_x;
    const source_height = bounds.max_y - bounds.min_y;
    const box_width: u32 = @max(1, @as(u32, @intFromFloat(@ceil(
        metrics.cell_width * @as(f32, @floatFromInt(cell_cols)) * pixel_scale,
    ))));
    const box_height: u32 = @max(1, @as(u32, @intFromFloat(@ceil(metrics.cell_height * pixel_scale))));
    const horizontal_inset: u32 = @min(
        box_width / 2,
        @as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(box_width)) * 0.025))),
    );
    const available_width = @max(1, box_width -| 2 * horizontal_inset);

    const width_factor = @as(f64, @floatFromInt(available_width)) /
        @as(f64, @floatFromInt(source_width));
    const height_factor = @as(f64, @floatFromInt(box_height)) /
        @as(f64, @floatFromInt(source_height));
    const factor = @min(width_factor, height_factor);
    const target_width: u32 = @max(1, @min(
        available_width,
        @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(source_width)) * factor))),
    ));
    const target_height: u32 = @max(1, @min(
        box_height,
        @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(source_height)) * factor))),
    ));

    const bytes = try allocator.alloc(u8, @as(usize, target_width) * target_height * 4);
    resamplePremultiplied(
        bytes,
        target_width,
        target_height,
        source.bytes,
        source.width,
        bounds,
    );
    allocator.free(source.bytes);

    const offset_x = @as(f32, @floatFromInt(box_width - target_width)) * 0.5 / pixel_scale;
    const offset_y = @as(f32, @floatFromInt(box_height - target_height)) * 0.5 / pixel_scale;
    return .{
        .bytes = bytes,
        .format = .color,
        .width = target_width,
        .height = target_height,
        .bearing_x = offset_x,
        .bearing_y = offset_y - metrics.ascent,
    };
}

fn colorPixelBounds(raster: GlyphRaster) ?PixelBounds {
    var min_x = raster.width;
    var min_y = raster.height;
    var max_x: u32 = 0;
    var max_y: u32 = 0;
    var saw_ink = false;
    var y: u32 = 0;
    while (y < raster.height) : (y += 1) {
        var x: u32 = 0;
        while (x < raster.width) : (x += 1) {
            const i = (@as(usize, y) * raster.width + x) * 4;
            if (raster.bytes[i + 3] == 0) continue;
            saw_ink = true;
            min_x = @min(min_x, x);
            min_y = @min(min_y, y);
            max_x = @max(max_x, x + 1);
            max_y = @max(max_y, y + 1);
        }
    }
    return if (saw_ink) .{ .min_x = min_x, .min_y = min_y, .max_x = max_x, .max_y = max_y } else null;
}

fn resamplePremultiplied(
    target: []u8,
    target_width: u32,
    target_height: u32,
    source: []const u8,
    source_stride_pixels: u32,
    bounds: PixelBounds,
) void {
    const source_width = bounds.max_x - bounds.min_x;
    const source_height = bounds.max_y - bounds.min_y;
    var y: u32 = 0;
    while (y < target_height) : (y += 1) {
        const source_y = (@as(f64, @floatFromInt(y)) + 0.5) *
            @as(f64, @floatFromInt(source_height)) / @as(f64, @floatFromInt(target_height)) - 0.5;
        const y0_local: u32 = if (source_y <= 0) 0 else @min(
            source_height - 1,
            @as(u32, @intFromFloat(@floor(source_y))),
        );
        const y1_local = @min(y0_local + 1, source_height - 1);
        const ty: f64 = if (source_y <= 0 or y0_local == source_height - 1)
            0
        else
            source_y - @floor(source_y);

        var x: u32 = 0;
        while (x < target_width) : (x += 1) {
            const source_x = (@as(f64, @floatFromInt(x)) + 0.5) *
                @as(f64, @floatFromInt(source_width)) / @as(f64, @floatFromInt(target_width)) - 0.5;
            const x0_local: u32 = if (source_x <= 0) 0 else @min(
                source_width - 1,
                @as(u32, @intFromFloat(@floor(source_x))),
            );
            const x1_local = @min(x0_local + 1, source_width - 1);
            const tx: f64 = if (source_x <= 0 or x0_local == source_width - 1)
                0
            else
                source_x - @floor(source_x);

            const idx00 = (@as(usize, bounds.min_y + y0_local) * source_stride_pixels + bounds.min_x + x0_local) * 4;
            const idx10 = (@as(usize, bounds.min_y + y0_local) * source_stride_pixels + bounds.min_x + x1_local) * 4;
            const idx01 = (@as(usize, bounds.min_y + y1_local) * source_stride_pixels + bounds.min_x + x0_local) * 4;
            const idx11 = (@as(usize, bounds.min_y + y1_local) * source_stride_pixels + bounds.min_x + x1_local) * 4;
            const out_i = (@as(usize, y) * target_width + x) * 4;
            var channel: usize = 0;
            while (channel < 4) : (channel += 1) {
                const top = @as(f64, @floatFromInt(source[idx00 + channel])) * (1 - tx) +
                    @as(f64, @floatFromInt(source[idx10 + channel])) * tx;
                const bottom = @as(f64, @floatFromInt(source[idx01 + channel])) * (1 - tx) +
                    @as(f64, @floatFromInt(source[idx11 + channel])) * tx;
                target[out_i + channel] = @intFromFloat(@round(top * (1 - ty) + bottom * ty));
            }
            // Independent rounding can put a color channel one unit above
            // alpha; clamp to retain the premultiplied invariant.
            const alpha = target[out_i + 3];
            target[out_i] = @min(target[out_i], alpha);
            target[out_i + 1] = @min(target[out_i + 1], alpha);
            target[out_i + 2] = @min(target[out_i + 2], alpha);
        }
    }
}

fn fontHasColorGlyphs(font: objc.Id) bool {
    return ct.CTFontGetSymbolicTraits(font) & ct.FontTrait.color_glyphs != 0;
}

/// CoreText resolves fallback while shaping, so cluster classification must
/// inspect the fonts on the resulting runs rather than infer presentation
/// from codepoints. This keeps VS15/text presentation on the mask path.
fn lineHasColorGlyphs(line: objc.Id) bool {
    const runs = ct.CTLineGetGlyphRuns(line);
    const count = ct.CFArrayGetCount(runs);
    var i: ct.CFIndex = 0;
    while (i < count) : (i += 1) {
        const run = ct.CFArrayGetValueAtIndex(runs, i);
        const attributes = ct.CTRunGetAttributes(run);
        const run_font = ct.CFDictionaryGetValue(attributes, ct.kCTFontAttributeName);
        if (run_font != null and fontHasColorGlyphs(run_font)) return true;
    }
    return false;
}

/// Ask CoreText for a real member of the configured family. A candidate is
/// accepted only when it has the exact requested bold/italic traits, remains
/// fixed pitch, and preserves the base face's terminal advance. The returned
/// reference is owned by the caller.
fn styledFace(base: objc.Id, style: Style, base_advance: f32) ?objc.Id {
    std.debug.assert(style != .regular);
    const style_mask = ct.FontTrait.bold | ct.FontTrait.italic;
    const desired = style.traits();
    const candidate = ct.CTFontCreateCopyWithSymbolicTraits(
        base,
        0,
        null,
        desired,
        style_mask,
    );
    if (candidate == null) return null;
    errdefer ct.CFRelease(candidate);

    if (ct.CTFontGetSymbolicTraits(candidate) & style_mask != desired) return null;
    const fixed_pitch = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.BOOL)(
        candidate,
        objc.sel("isFixedPitch"),
    );
    if (fixed_pitch == 0) return null;

    const base_family = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        base,
        objc.sel("familyName"),
    );
    const candidate_family = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        candidate,
        objc.sel("familyName"),
    );
    if (base_family == null or candidate_family == null or ct.CFEqual(base_family, candidate_family) == 0)
        return null;

    if (@abs(glyphAdvance(candidate, 'M') - base_advance) > 0.01) return null;
    return candidate;
}

fn retainFont(font: objc.Id) objc.Id {
    return objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(font, objc.sel("retain"));
}

fn glyphAdvance(font: objc.Id, cp: u16) f32 {
    var character = cp;
    var glyph: ct.CGGlyph = 0;
    _ = ct.CTFontGetGlyphsForCharacters(font, @ptrCast(&character), @ptrCast(&glyph), 1);
    return @floatCast(ct.CTFontGetAdvancesForGlyphs(font, .horizontal, @ptrCast(&glyph), null, 1));
}

fn systemMonospacedFont(size: f32) objc.Id {
    return objc.msg(
        *const fn (objc.Class, objc.Sel, objc.CGFloat, objc.CGFloat) callconv(.c) objc.Id,
    )(
        objc.cls("NSFont"),
        objc.sel("monospacedSystemFontOfSize:weight:"),
        @floatCast(size),
        0.0, // NSFontWeightRegular
    );
}

fn configuredFont(alloc: std.mem.Allocator, family: []const u8, size: f32) !objc.Id {
    const family_z = try alloc.dupeZ(u8, family);
    defer alloc.free(family_z);
    const family_string = objc.nsString(family_z.ptr);
    if (family_string == null) return error.FontLoad;

    const manager = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSFontManager"),
        objc.sel("sharedFontManager"),
    );
    const font = objc.msg(
        *const fn (
            objc.Id,
            objc.Sel,
            objc.Id,
            objc.NSUInteger,
            objc.NSInteger,
            objc.CGFloat,
        ) callconv(.c) objc.Id,
    )(
        manager,
        objc.sel("fontWithFamily:traits:weight:size:"),
        family_string,
        0,
        5, // regular NSFontManager weight
        @floatCast(size),
    );
    if (font == null) return error.FontLoad;
    const fixed_pitch = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.BOOL)(
        font,
        objc.sel("isFixedPitch"),
    );
    if (fixed_pitch == 0) return error.FontNotMonospaced;
    return font;
}

pub fn isBuiltin(ref: GlyphRef) bool {
    return ref.font == builtin_font_index;
}

fn lookup(font: objc.Id, units: []const u16) ?u16 {
    var glyphs: [2]ct.CGGlyph = .{ 0, 0 };
    _ = ct.CTFontGetGlyphsForCharacters(font, units.ptr, &glyphs, @intCast(units.len));
    return if (glyphs[0] != 0) glyphs[0] else null;
}

fn utf16Encode(cp: u21, out: *[2]u16) usize {
    if (cp < 0x10000) {
        out[0] = @intCast(cp);
        return 1;
    }
    const v = cp - 0x10000;
    out[0] = @intCast(0xD800 + (v >> 10));
    out[1] = @intCast(0xDC00 + (v & 0x3FF));
    return 2;
}

const RasterGolden = struct {
    width: u32,
    height: u32,
    bearing_x: f32,
    bearing_y: f32,
    hash: u64,
};

fn expectRasterGolden(raster: *const GlyphRaster, golden: RasterGolden) !void {
    try std.testing.expectEqual(golden.width, raster.width);
    try std.testing.expectEqual(golden.height, raster.height);
    try std.testing.expectApproxEqAbs(golden.bearing_x, raster.bearing_x, 0.01);
    try std.testing.expectApproxEqAbs(golden.bearing_y, raster.bearing_y, 0.01);
    try std.testing.expect(raster.bytes.len > 0);
    try std.testing.expect(std.mem.indexOfNone(u8, raster.bytes, &.{0}) != null);
    if (!@import("test_options").portable_system_goldens) {
        try std.testing.expectEqual(golden.hash, std.hash.Wyhash.hash(0, raster.bytes));
    }
}

fn expectColorFitsCells(
    fonts: *const FontSet,
    raster: *const GlyphRaster,
    cell_cols: u2,
    pixel_scale: f32,
) !void {
    const box_width: u32 = @max(1, @as(u32, @intFromFloat(@ceil(
        fonts.metrics.cell_width * @as(f32, @floatFromInt(cell_cols)) * pixel_scale,
    ))));
    const box_height: u32 = @max(1, @as(u32, @intFromFloat(@ceil(
        fonts.metrics.cell_height * pixel_scale,
    ))));
    const horizontal_inset: u32 = @min(
        box_width / 2,
        @as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(box_width)) * 0.025))),
    );
    const left = raster.bearing_x * pixel_scale;
    const top = fonts.cellTopForBearing(raster.bearing_y) * pixel_scale;
    const right = @as(f32, @floatFromInt(box_width - raster.width)) - left;
    const bottom = @as(f32, @floatFromInt(box_height - raster.height)) - top;

    try std.testing.expect(left + 0.01 >= @as(f32, @floatFromInt(horizontal_inset)));
    try std.testing.expect(right + 0.01 >= @as(f32, @floatFromInt(horizontal_inset)));
    try std.testing.expect(top >= -0.01);
    try std.testing.expect(bottom >= -0.01);
    try std.testing.expect(@abs(left - right) <= 0.01);
    try std.testing.expect(@abs(top - bottom) <= 0.01);
}

test "system and configured monospace fonts produce rasterizable cells" {
    const alloc = std.testing.allocator;
    var system = try FontSet.init(alloc, .{});
    defer system.deinit();
    try std.testing.expect(system.metrics.cell_width > 0);
    try std.testing.expect(system.metrics.cell_height > system.metrics.ascent);
    try std.testing.expect(system.hasRealStyle(.bold));
    try std.testing.expect(system.hasRealStyle(.italic));
    try std.testing.expect(system.hasRealStyle(.bold_italic));

    var configured = try FontSet.init(alloc, .{ .family = "Menlo", .size = 14 });
    defer configured.deinit();
    const glyph = configured.glyphFor('M', .regular, 1).?;
    var raster = try configured.rasterize(glyph, 2, alloc);
    defer raster.deinit(alloc);
    try std.testing.expectEqual(RasterFormat.mask, raster.format);
    try std.testing.expect(raster.width > 0);
    try std.testing.expect(raster.height > 0);
    try std.testing.expect(std.mem.indexOfNone(u8, raster.bytes, &.{0}) != null);

    var cluster = try configured.rasterizeCluster("e\u{0301}", 1, .regular, 2, alloc);
    defer cluster.deinit(alloc);
    try std.testing.expectEqual(RasterFormat.mask, cluster.format);
    try std.testing.expectEqual(
        @as(u32, @intFromFloat(@ceil(configured.metrics.cell_width * 2))),
        cluster.width,
    );
    try std.testing.expectEqual(
        @as(u32, @intFromFloat(@ceil(configured.metrics.cell_height * 2))),
        cluster.height,
    );
    try std.testing.expect(std.mem.indexOfNone(u8, cluster.bytes, &.{0}) != null);
    try expectRasterGolden(&cluster, .{
        .width = 17,
        .height = 34,
        .bearing_x = 0,
        .bearing_y = -12.995,
        .hash = 0xdf0686679473701d,
    });

    var devanagari = try configured.rasterizeCluster("कि", 1, .regular, 2, alloc);
    defer devanagari.deinit(alloc);
    try expectRasterGolden(&devanagari, .{
        .width = 17,
        .height = 34,
        .bearing_x = 0,
        .bearing_y = -12.995,
        .hash = 0x0e42e886ee482559,
    });
}

test "Menlo resolves real bold italic faces without changing cell advance" {
    const alloc = std.testing.allocator;
    var fonts = try FontSet.init(alloc, .{ .family = "Menlo", .size = 14 });
    defer fonts.deinit();

    const style_mask = ct.FontTrait.bold | ct.FontTrait.italic;
    const goldens = [_]RasterGolden{
        .{ .width = 17, .height = 23, .bearing_x = -0.5, .bearing_y = -11, .hash = 0x2093c8d0de899ab9 },
        .{ .width = 17, .height = 23, .bearing_x = 0, .bearing_y = -11, .hash = 0x6e01c00056f5469b },
        .{ .width = 21, .height = 23, .bearing_x = -1, .bearing_y = -11, .hash = 0xdc8ce8cc1495352a },
        .{ .width = 21, .height = 23, .bearing_x = -1, .bearing_y = -11, .hash = 0x2d3a19affd3631f5 },
    };
    inline for (.{ Style.regular, Style.bold, Style.italic, Style.bold_italic }) |style| {
        try std.testing.expect(fonts.hasRealStyle(style));
        const ref = fonts.glyphFor('M', style, 1) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u16, @intFromEnum(style)), ref.font);
        try std.testing.expectEqual(
            style.traits(),
            ct.CTFontGetSymbolicTraits(fonts.fonts.items[ref.font]) & style_mask,
        );
        try std.testing.expectApproxEqAbs(
            fonts.metrics.cell_width,
            glyphAdvance(fonts.fonts.items[ref.font], 'M'),
            0.01,
        );

        var raster = try fonts.rasterize(ref, 2, alloc);
        defer raster.deinit(alloc);
        try std.testing.expectEqual(RasterFormat.mask, raster.format);
        try expectRasterGolden(&raster, goldens[@intFromEnum(style)]);
    }
}

test "Monaco completes missing styles synthetically" {
    const alloc = std.testing.allocator;
    var fonts = try FontSet.init(alloc, .{ .family = "Monaco", .size = 14 });
    defer fonts.deinit();
    try std.testing.expect(!fonts.hasRealStyle(.bold));
    try std.testing.expect(!fonts.hasRealStyle(.italic));
    try std.testing.expect(!fonts.hasRealStyle(.bold_italic));

    const goldens = [_]RasterGolden{
        .{ .width = 19, .height = 24, .bearing_x = -0.5, .bearing_y = -11.5, .hash = 0x46e76a7f2b0e7ec2 },
        .{ .width = 21, .height = 26, .bearing_x = -1, .bearing_y = -12, .hash = 0xc9b140fe77534ff6 },
        .{ .width = 24, .height = 24, .bearing_x = -0.5, .bearing_y = -11.5, .hash = 0xd8330356b9e7169 },
        .{ .width = 26, .height = 26, .bearing_x = -1, .bearing_y = -12, .hash = 0x4784c91818522c73 },
    };
    inline for (.{ Style.regular, Style.bold, Style.italic, Style.bold_italic }) |style| {
        const ref = fonts.glyphFor('M', style, 1) orelse return error.TestUnexpectedResult;
        var raster = try fonts.rasterize(ref, 2, alloc);
        defer raster.deinit(alloc);
        try std.testing.expectEqual(RasterFormat.mask, raster.format);
        try expectRasterGolden(&raster, goldens[@intFromEnum(style)]);
    }

    var cluster = try fonts.rasterizeCluster("e\u{0301}", 1, .bold_italic, 2, alloc);
    defer cluster.deinit(alloc);
    try std.testing.expectEqual(RasterFormat.mask, cluster.format);
    try expectRasterGolden(&cluster, .{
        .width = 17,
        .height = 38,
        .bearing_x = 0,
        .bearing_y = -14,
        .hash = 0xe0278ab6219ed666,
    });

    const regular_emoji_ref = fonts.glyphFor(0x1F600, .regular, 2) orelse return error.TestUnexpectedResult;
    const styled_emoji_ref = fonts.glyphFor(0x1F600, .bold_italic, 2) orelse return error.TestUnexpectedResult;
    var regular_emoji = try fonts.rasterize(regular_emoji_ref, 2, alloc);
    defer regular_emoji.deinit(alloc);
    var styled_emoji = try fonts.rasterize(styled_emoji_ref, 2, alloc);
    defer styled_emoji.deinit(alloc);
    try std.testing.expectEqual(RasterFormat.color, regular_emoji.format);
    try std.testing.expectEqual(RasterFormat.color, styled_emoji.format);
    try std.testing.expectEqual(regular_emoji.width, styled_emoji.width);
    try std.testing.expectEqual(regular_emoji.height, styled_emoji.height);
    try std.testing.expectEqual(regular_emoji.bearing_x, styled_emoji.bearing_x);
    try std.testing.expectEqual(regular_emoji.bearing_y, styled_emoji.bearing_y);
    try std.testing.expectEqualSlices(u8, regular_emoji.bytes, styled_emoji.bytes);
}

test "styled fallback glyphs retain the regular cell baseline" {
    const alloc = std.testing.allocator;
    var fonts = try FontSet.init(alloc, .{ .family = "Menlo", .size = 14 });
    defer fonts.deinit();

    const regular_ref = fonts.glyphFor('界', .regular, 2) orelse return error.TestUnexpectedResult;
    const styled_ref = fonts.glyphFor('界', .bold_italic, 2) orelse return error.TestUnexpectedResult;
    try std.testing.expect(regular_ref.font >= style_count);
    // A styled glyph absent from the configured family uses the already
    // discovered regular fallback instead of a metric-changing styled face.
    try std.testing.expectEqual(regular_ref.font, styled_ref.font);
    try std.testing.expectEqual(regular_ref.glyph, styled_ref.glyph);
    try std.testing.expectEqual(Style.bold_italic, styled_ref.style);

    var raster = try fonts.rasterize(styled_ref, 2, alloc);
    defer raster.deinit(alloc);
    try expectRasterGolden(&raster, .{
        .width = 37,
        .height = 29,
        .bearing_x = -1,
        .bearing_y = -12,
        .hash = 0x64f0e9c0e6cb6055,
    });
    const top = fonts.cellTopForBearing(raster.bearing_y);
    const bottom = top + @as(f32, @floatFromInt(raster.height)) / 2;
    try std.testing.expect(std.math.isFinite(top) and std.math.isFinite(bottom));
    try std.testing.expect(top >= -1);
    try std.testing.expect(bottom <= fonts.metrics.cell_height + 1);
    // Renderer placement reconstructs one shared baseline, regardless of the
    // selected fallback face's own ascent/descent.
    try std.testing.expectApproxEqAbs(fonts.metrics.ascent, top - raster.bearing_y, 0.001);
}

test "Apple color emoji rasterize as premultiplied RGBA" {
    const alloc = std.testing.allocator;
    var fonts = try FontSet.init(alloc, .{});
    defer fonts.deinit();

    const ref = fonts.glyphFor(0x1F600, .regular, 2) orelse return error.TestUnexpectedResult;
    var scalar = try fonts.rasterize(ref, 2, alloc);
    defer scalar.deinit(alloc);
    try std.testing.expectEqual(RasterFormat.color, scalar.format);
    try expectPremultipliedColor(scalar.bytes);
    try expectColorFitsCells(&fonts, &scalar, 2, 2);
    try expectRasterGolden(&scalar, .{
        .width = 31,
        .height = 31,
        .bearing_x = 0.5,
        .bearing_y = -12.318,
        .hash = 0x55de7b6e6ebafaa4,
    });

    var cluster = try fonts.rasterizeCluster("👨🏽‍💻", 2, .regular, 2, alloc);
    defer cluster.deinit(alloc);
    try std.testing.expectEqual(RasterFormat.color, cluster.format);
    try expectPremultipliedColor(cluster.bytes);
    try expectColorFitsCells(&fonts, &cluster, 2, 2);
    try expectRasterGolden(&cluster, .{
        .width = 29,
        .height = 32,
        .bearing_x = 1,
        .bearing_y = -12.568,
        .hash = 0xc49f81294835cfd5,
    });
}

test "configured proportional fonts are rejected" {
    try std.testing.expectError(
        error.FontNotMonospaced,
        FontSet.init(std.testing.allocator, .{ .family = "Helvetica" }),
    );
}

fn expectPremultipliedColor(bytes: []const u8) !void {
    try std.testing.expect(bytes.len % 4 == 0);
    var saw_ink = false;
    var saw_chroma = false;
    var i: usize = 0;
    while (i < bytes.len) : (i += 4) {
        const r = bytes[i];
        const g = bytes[i + 1];
        const b = bytes[i + 2];
        const a = bytes[i + 3];
        try std.testing.expect(r <= a and g <= a and b <= a);
        saw_ink = saw_ink or a != 0;
        saw_chroma = saw_chroma or (a != 0 and (r != g or g != b));
    }
    try std.testing.expect(saw_ink);
    try std.testing.expect(saw_chroma);
}
