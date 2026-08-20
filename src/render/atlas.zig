//! Persistent glyph atlases for the terminal renderer.
//! Text coverage masks and premultiplied color glyphs have independent Metal
//! textures and shelf packers. Cache keys remain font/content based, so callers
//! do not need to predict CoreText fallback presentation before rasterizing.

const std = @import("std");
const objc = @import("objc.zig");
const metal = @import("metal.zig");
const font_mod = @import("font.zig");

const glyph_gap: u32 = 1;
const max_atlas_size: u32 = 8192;

pub const AtlasEntry = struct {
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    /// Quad size in points.
    width: f32,
    height: f32,
    /// Pen-to-topleft offset in points (bearing_y negative above baseline).
    bearing_x: f32,
    bearing_y: f32,
    format: font_mod.RasterFormat,
};

const Slot = struct { x: u32, y: u32 };

const Page = struct {
    texture: objc.Id,
    size: u32,
    cur_x: u32 = 0,
    cur_y: u32 = 0,
    row_height: u32 = 0,

    fn init(device: objc.Id, size: u32, format: font_mod.RasterFormat) !Page {
        return .{
            .texture = try metal.newTexture2D(device, pixelFormat(format), size, size),
            .size = size,
        };
    }

    fn reset(self: *Page) void {
        self.cur_x = 0;
        self.cur_y = 0;
        self.row_height = 0;
    }

    fn tryAlloc(self: *Page, w: u32, h: u32) ?Slot {
        if (w > self.size or h > self.size) return null;
        if (self.cur_x + w > self.size) {
            self.cur_x = 0;
            self.cur_y += self.row_height + glyph_gap;
            self.row_height = 0;
        }
        if (self.cur_y + h > self.size) return null;

        const slot: Slot = .{ .x = self.cur_x, .y = self.cur_y };
        self.cur_x += w + glyph_gap;
        if (h > self.row_height) self.row_height = h;
        return slot;
    }
};

pub const GlyphAtlas = struct {
    alloc: std.mem.Allocator,
    device: objc.Id,
    pixel_scale: f32,
    mask: Page,
    color: Page,

    mask_entries: std.AutoHashMapUnmanaged(font_mod.GlyphRef, AtlasEntry) = .empty,
    color_entries: std.AutoHashMapUnmanaged(font_mod.GlyphRef, AtlasEntry) = .empty,
    mask_cluster_entries: std.StringHashMapUnmanaged(AtlasEntry) = .empty,
    color_cluster_entries: std.StringHashMapUnmanaged(AtlasEntry) = .empty,

    pub fn init(alloc: std.mem.Allocator, device: objc.Id, size: u32, pixel_scale: f32) !GlyphAtlas {
        const mask = try Page.init(device, size, .mask);
        errdefer objc.release(mask.texture);
        const color = try Page.init(device, @min(size, 512), .color);
        errdefer objc.release(color.texture);
        return .{
            .alloc = alloc,
            .device = device,
            .pixel_scale = pixel_scale,
            .mask = mask,
            .color = color,
        };
    }

    pub fn deinit(self: *GlyphAtlas) void {
        self.mask_entries.deinit(self.alloc);
        self.color_entries.deinit(self.alloc);
        clearClusterMap(self.alloc, &self.mask_cluster_entries);
        clearClusterMap(self.alloc, &self.color_cluster_entries);
        self.mask_cluster_entries.deinit(self.alloc);
        self.color_cluster_entries.deinit(self.alloc);
        objc.release(self.mask.texture);
        objc.release(self.color.texture);
        self.mask.texture = null;
        self.color.texture = null;
    }

    pub fn texture(self: *const GlyphAtlas, format: font_mod.RasterFormat) objc.Id {
        return switch (format) {
            .mask => self.mask.texture,
            .color => self.color.texture,
        };
    }

    pub fn getOrRasterize(self: *GlyphAtlas, fonts: *const font_mod.FontSet, ref: font_mod.GlyphRef) !AtlasEntry {
        if (self.mask_entries.get(ref)) |entry| return entry;
        if (self.color_entries.get(ref)) |entry| return entry;

        var raster = try fonts.rasterize(ref, self.pixel_scale, self.alloc);
        defer raster.deinit(self.alloc);
        const slot = try self.allocSlot(raster.format, raster.width, raster.height);
        self.upload(raster.format, slot, raster.width, raster.height, raster.bytes);

        var entry = self.makeEntry(raster.format, slot, &raster);
        if (font_mod.isBuiltin(ref)) {
            entry.width = fonts.metrics.cell_width;
            entry.height = fonts.metrics.cell_height;
        }
        switch (raster.format) {
            .mask => try self.mask_entries.putNoClobber(self.alloc, ref, entry),
            .color => try self.color_entries.putNoClobber(self.alloc, ref, entry),
        }
        return entry;
    }

    pub fn getOrRasterizeCluster(
        self: *GlyphAtlas,
        fonts: *const font_mod.FontSet,
        utf8: []const u8,
        cell_cols: u2,
        style: font_mod.Style,
    ) !AtlasEntry {
        // Width and style are part of the key: legacy mode can retain the
        // same suffix bytes without applying mode-2027 widening, and styled
        // clusters must never reuse a regular raster.
        var lookup_key: [258]u8 = undefined;
        const key = try clusterCacheKey(&lookup_key, utf8, cell_cols, style);
        if (self.mask_cluster_entries.get(key)) |entry| return entry;
        if (self.color_cluster_entries.get(key)) |entry| return entry;

        var raster = try fonts.rasterizeCluster(utf8, cell_cols, style, self.pixel_scale, self.alloc);
        defer raster.deinit(self.alloc);
        const slot = try self.allocSlot(raster.format, raster.width, raster.height);
        self.upload(raster.format, slot, raster.width, raster.height, raster.bytes);

        const entry = self.makeEntry(raster.format, slot, &raster);
        const owned_key = try self.alloc.dupe(u8, key);
        errdefer self.alloc.free(owned_key);
        switch (raster.format) {
            .mask => try self.mask_cluster_entries.putNoClobber(self.alloc, owned_key, entry),
            .color => try self.color_cluster_entries.putNoClobber(self.alloc, owned_key, entry),
        }
        return entry;
    }

    fn makeEntry(
        self: *const GlyphAtlas,
        format: font_mod.RasterFormat,
        slot: Slot,
        raster: *const font_mod.GlyphRaster,
    ) AtlasEntry {
        const atlas_page = self.pageConst(format);
        const inv_size: f32 = 1.0 / @as(f32, @floatFromInt(atlas_page.size));
        const inv_scale: f32 = 1.0 / self.pixel_scale;
        return .{
            // Sampling texel centers avoids blending against the one-pixel
            // packing gap, which otherwise creates seams at cell edges.
            .u0 = (@as(f32, @floatFromInt(slot.x)) + 0.5) * inv_size,
            .v0 = (@as(f32, @floatFromInt(slot.y)) + 0.5) * inv_size,
            .u1 = (@as(f32, @floatFromInt(slot.x + raster.width)) - 0.5) * inv_size,
            .v1 = (@as(f32, @floatFromInt(slot.y + raster.height)) - 0.5) * inv_size,
            .width = @as(f32, @floatFromInt(raster.width)) * inv_scale,
            .height = @as(f32, @floatFromInt(raster.height)) * inv_scale,
            .bearing_x = raster.bearing_x,
            .bearing_y = raster.bearing_y,
            .format = format,
        };
    }

    fn allocSlot(self: *GlyphAtlas, format: font_mod.RasterFormat, w: u32, h: u32) !Slot {
        if (w > max_atlas_size or h > max_atlas_size) return error.GlyphTooLarge;
        while (true) {
            if (self.page(format).tryAlloc(w, h)) |slot| return slot;
            try self.grow(format);
        }
    }

    fn grow(self: *GlyphAtlas, format: font_mod.RasterFormat) !void {
        const atlas_page = self.page(format);
        const new_size = atlas_page.size * 2;
        if (new_size > max_atlas_size) {
            self.clearEntries(format);
            atlas_page.reset();
            return;
        }

        const depth = format.depth();
        const byte_count = @as(usize, atlas_page.size) * atlas_page.size * depth;
        const pixels = try self.alloc.alloc(u8, byte_count);
        defer self.alloc.free(pixels);
        const region: metal.Region = .{
            .size = .{ .width = atlas_page.size, .height = atlas_page.size, .depth = 1 },
        };
        metal.getBytes(atlas_page.texture, pixels.ptr, @as(usize, atlas_page.size) * depth, region);

        const new_texture = try metal.newTexture2D(self.device, pixelFormat(format), new_size, new_size);
        errdefer objc.release(new_texture);
        metal.replaceRegion(new_texture, region, pixels.ptr, @as(usize, atlas_page.size) * depth);

        const uv_scale: f32 = @as(f32, @floatFromInt(atlas_page.size)) / @as(f32, @floatFromInt(new_size));
        self.scaleEntryUvs(format, uv_scale);
        objc.release(atlas_page.texture);
        atlas_page.texture = new_texture;
        atlas_page.size = new_size;
    }

    fn upload(
        self: *GlyphAtlas,
        format: font_mod.RasterFormat,
        slot: Slot,
        w: u32,
        h: u32,
        bytes: []const u8,
    ) void {
        std.debug.assert(bytes.len == @as(usize, w) * h * format.depth());
        const region: metal.Region = .{
            .origin = .{ .x = slot.x, .y = slot.y },
            .size = .{ .width = w, .height = h, .depth = 1 },
        };
        metal.replaceRegion(self.page(format).texture, region, bytes.ptr, @as(usize, w) * format.depth());
    }

    fn page(self: *GlyphAtlas, format: font_mod.RasterFormat) *Page {
        return switch (format) {
            .mask => &self.mask,
            .color => &self.color,
        };
    }

    fn pageConst(self: *const GlyphAtlas, format: font_mod.RasterFormat) *const Page {
        return switch (format) {
            .mask => &self.mask,
            .color => &self.color,
        };
    }

    fn clearEntries(self: *GlyphAtlas, format: font_mod.RasterFormat) void {
        switch (format) {
            .mask => {
                self.mask_entries.clearRetainingCapacity();
                clearClusterMap(self.alloc, &self.mask_cluster_entries);
            },
            .color => {
                self.color_entries.clearRetainingCapacity();
                clearClusterMap(self.alloc, &self.color_cluster_entries);
            },
        }
    }

    fn scaleEntryUvs(self: *GlyphAtlas, format: font_mod.RasterFormat, scale: f32) void {
        switch (format) {
            .mask => {
                scaleMapUvs(&self.mask_entries, scale);
                scaleMapUvs(&self.mask_cluster_entries, scale);
            },
            .color => {
                scaleMapUvs(&self.color_entries, scale);
                scaleMapUvs(&self.color_cluster_entries, scale);
            },
        }
    }
};

fn clusterCacheKey(
    buffer: *[258]u8,
    utf8: []const u8,
    cell_cols: u2,
    style: font_mod.Style,
) ![]const u8 {
    if (utf8.len + 2 > buffer.len) return error.GraphemeTooLong;
    buffer[0] = cell_cols;
    buffer[1] = @intFromEnum(style);
    @memcpy(buffer[2..][0..utf8.len], utf8);
    return buffer[0 .. utf8.len + 2];
}

test "cluster atlas keys distinguish width and font style" {
    var regular_buf: [258]u8 = undefined;
    var bold_buf: [258]u8 = undefined;
    var wide_buf: [258]u8 = undefined;
    const regular = try clusterCacheKey(&regular_buf, "e\u{301}", 1, .regular);
    const bold = try clusterCacheKey(&bold_buf, "e\u{301}", 1, .bold);
    const wide = try clusterCacheKey(&wide_buf, "e\u{301}", 2, .regular);
    try std.testing.expect(!std.mem.eql(u8, regular, bold));
    try std.testing.expect(!std.mem.eql(u8, regular, wide));
}

fn pixelFormat(format: font_mod.RasterFormat) objc.NSUInteger {
    return switch (format) {
        .mask => metal.PixelFormat.r8_unorm,
        .color => metal.PixelFormat.rgba8_unorm,
    };
}

fn clearClusterMap(alloc: std.mem.Allocator, map: *std.StringHashMapUnmanaged(AtlasEntry)) void {
    var it = map.keyIterator();
    while (it.next()) |key| alloc.free(key.*);
    map.clearRetainingCapacity();
}

fn scaleMapUvs(map: anytype, scale: f32) void {
    var it = map.valueIterator();
    while (it.next()) |entry| {
        entry.u0 *= scale;
        entry.v0 *= scale;
        entry.u1 *= scale;
        entry.v1 *= scale;
    }
}
