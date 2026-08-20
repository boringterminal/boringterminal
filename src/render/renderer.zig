//! Frame = pure function of grid state (RFC 0004). Instanced draws cover cell
//! backgrounds, R8 text masks, premultiplied RGBA color glyphs, and then
//! decorations. Live presentation uses a bounded three-slot frame ring.

const std = @import("std");
const objc = @import("objc.zig");
const metal = @import("metal.zig");
const shaders = @import("shaders.zig");
const font_mod = @import("font.zig");
const atlas_mod = @import("atlas.zig");
const staged_upload_mod = @import("staged_upload.zig");
const vt = @import("../vt.zig");
const DisplayWidth = @import("DisplayWidth");
const Graphemes = @import("Graphemes");
const libc = std.c;

pub const Theme = vt.ColorScheme;
pub const FontOptions = font_mod.Options;
pub const StagedUpload = staged_upload_mod.Upload;

pub const OffscreenImage = struct {
    alloc: std.mem.Allocator,
    width: u32,
    height: u32,
    /// Tightly packed top-to-bottom BGRA8Unorm pixels.
    pixels: []u8,

    pub fn deinit(self: *OffscreenImage) void {
        self.alloc.free(self.pixels);
        self.* = undefined;
    }
};

/// Matches struct QuadInstance in shaders.zig. 32 bytes.
const QuadInstance = extern struct {
    origin: [2]f32,
    size: [2]f32,
    color: [4]f32,
};

/// Matches struct GlyphInstance in shaders.zig. 48 bytes.
const GlyphInstance = extern struct {
    origin: [2]f32,
    size: [2]f32,
    uv: [4]f32,
    color: [4]f32,
};

const ImageInstance = extern struct {
    origin: [2]f32,
    size: [2]f32,
    uv: [4]f32,
};

const ImageTexture = struct {
    session_id: u64,
    id: u32,
    generation: u64,
    texture: objc.Id,
    upload: ?*StagedUpload = null,
};

const ImageDraw = struct {
    texture: objc.Id,
    instance: ImageInstance,
    z: i32,
    image_id: u32,
};

const image_below_cell_backgrounds: i32 = std.math.minInt(i32) / 2;

pub const PaneRect = struct {
    origin: [2]f32,
    size: [2]f32,
};

/// Viewer-local NSTextInputClient pre-edit. Byte offsets are UTF-8 boundaries;
/// this overlay is never retained by terminal state or snapshots.
pub const Preedit = struct {
    utf8: []const u8,
    caret_utf8: usize,
};

pub const PreeditCell = struct { row: u16, col: u16 };

pub fn preeditCaretCell(
    utf8: []const u8,
    caret_utf8: usize,
    start_row: u16,
    start_col: u16,
    cols: u16,
) PreeditCell {
    var row = start_row;
    var col = start_col;
    var cluster_start: usize = 0;
    const limit = @min(caret_utf8, utf8.len);
    while (cluster_start < limit) {
        const first_len = std.unicode.utf8ByteSequenceLength(utf8[cluster_start]) catch break;
        const first_end = cluster_start + first_len;
        if (first_end > utf8.len) break;
        var previous = std.unicode.utf8Decode(utf8[cluster_start..first_end]) catch break;
        var cluster_end = first_end;
        var state: Graphemes.IterState = .{};
        while (cluster_end < utf8.len) {
            const next_len = std.unicode.utf8ByteSequenceLength(utf8[cluster_end]) catch break;
            const next_end = cluster_end + next_len;
            if (next_end > utf8.len) break;
            const next = std.unicode.utf8Decode(utf8[cluster_end..next_end]) catch break;
            if (Graphemes.graphemeBreak(previous, next, &state)) break;
            previous = next;
            cluster_end = next_end;
        }
        if (cluster_end > limit) break;
        const raw_width = DisplayWidth.graphemeWidth(utf8[cluster_start..cluster_end]);
        const width: u16 = if (raw_width <= 1) 1 else 2;
        if (@as(u32, col) + width > cols) {
            row +|= 1;
            col = 0;
        }
        col += width;
        if (col >= cols) {
            row +|= 1;
            col = 0;
        }
        cluster_start = cluster_end;
    }
    return .{ .row = row, .col = col };
}

const InstanceRange = struct {
    start: usize,
    len: usize,
};

const PaneBatch = struct {
    rect: PaneRect,
    backgrounds: InstanceRange,
    decorations: InstanceRange,
    glyphs: InstanceRange,
    color_glyphs: InstanceRange,
    images: InstanceRange,
};

const ActiveImageRef = struct {
    session_id: u64,
    id: u32,
    generation: u64,
};

const frame_slot_count = 3;

const FrameResources = struct {
    instance_buffer: objc.Id = null,
    instance_capacity: usize = 0,
};

const FrameSlotState = enum(u8) {
    available,
    submitted,
    completed,
};

const FrameSlot = struct {
    resources: FrameResources = .{},
    retained_textures: std.ArrayList(objc.Id) = .empty,
    retained_uploads: std.ArrayList(*StagedUpload) = .empty,
    command_buffer: objc.Id = null,
    completion_succeeded: std.atomic.Value(bool) = .init(true),
    completion_context: ?*anyopaque = null,
    completion_fn: ?FrameCompletionFn = null,
    state: std.atomic.Value(u8) = .init(@intFromEnum(FrameSlotState.available)),
};

pub const FrameCompletionFn = *const fn (?*anyopaque) callconv(.c) void;

pub const PresentResult = enum {
    submitted,
    no_drawable,
    no_frame_slot,
    encoding_failed,
};

pub const Renderer = struct {
    alloc: std.mem.Allocator,
    device: objc.Id,
    queue: objc.Id,
    quad_pipeline: metal.Pipeline,
    glyph_pipeline: metal.Pipeline,
    color_glyph_pipeline: metal.Pipeline,
    image_pipeline: metal.Pipeline,
    fonts: font_mod.FontSet,
    atlas: atlas_mod.GlyphAtlas,
    theme: Theme = vt.default_color_scheme,
    pixel_scale: f32,
    completion_context: ?*anyopaque = null,
    completion_fn: ?FrameCompletionFn = null,

    frame_slots: [frame_slot_count]FrameSlot = [_]FrameSlot{.{}} ** frame_slot_count,
    offscreen_resources: FrameResources = .{},

    bg_list: std.ArrayList(QuadInstance) = .empty,
    decor_list: std.ArrayList(QuadInstance) = .empty,
    glyph_list: std.ArrayList(GlyphInstance) = .empty,
    color_glyph_list: std.ArrayList(GlyphInstance) = .empty,
    image_textures: std.ArrayList(ImageTexture) = .empty,
    image_draws: std.ArrayList(ImageDraw) = .empty,
    active_image_refs: std.ArrayList(ActiveImageRef) = .empty,
    pane_batches: std.ArrayList(PaneBatch) = .empty,

    pub fn init(alloc: std.mem.Allocator, font_options: FontOptions, pixel_scale: f32) !Renderer {
        var fonts = try font_mod.FontSet.init(alloc, font_options);
        errdefer fonts.deinit();

        const device = metal.createDevice();
        if (device == null) return error.NoMetalDevice;
        errdefer objc.release(device);
        const queue = metal.newCommandQueue(device);
        if (queue == null) return error.NoCommandQueue;
        errdefer objc.release(queue);

        const quad_pipeline = try metal.buildPipeline(device, shaders.quad, "quad_vertex", "quad_fragment");
        errdefer {
            objc.release(quad_pipeline.state);
            objc.release(quad_pipeline.library);
        }
        const glyph_pipeline = try metal.buildPipeline(device, shaders.glyph, "glyph_vertex", "glyph_fragment");
        errdefer {
            objc.release(glyph_pipeline.state);
            objc.release(glyph_pipeline.library);
        }
        const color_glyph_pipeline = try metal.buildPremultipliedPipeline(
            device,
            shaders.color_glyph,
            "color_glyph_vertex",
            "color_glyph_fragment",
        );
        errdefer {
            objc.release(color_glyph_pipeline.state);
            objc.release(color_glyph_pipeline.library);
        }
        const image_pipeline = try metal.buildPipeline(device, shaders.image, "image_vertex", "image_fragment");
        errdefer {
            objc.release(image_pipeline.state);
            objc.release(image_pipeline.library);
        }
        var atlas = try atlas_mod.GlyphAtlas.init(alloc, device, 1024, pixel_scale);
        errdefer atlas.deinit();

        return .{
            .alloc = alloc,
            .device = device,
            .queue = queue,
            .quad_pipeline = quad_pipeline,
            .glyph_pipeline = glyph_pipeline,
            .color_glyph_pipeline = color_glyph_pipeline,
            .image_pipeline = image_pipeline,
            .fonts = fonts,
            .atlas = atlas,
            .pixel_scale = pixel_scale,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.finishLiveFrames();
        self.bg_list.deinit(self.alloc);
        self.decor_list.deinit(self.alloc);
        self.glyph_list.deinit(self.alloc);
        self.color_glyph_list.deinit(self.alloc);
        for (self.image_textures.items) |cached| {
            if (cached.upload) |upload| upload.release();
            objc.release(cached.texture);
        }
        self.image_textures.deinit(self.alloc);
        self.image_draws.deinit(self.alloc);
        self.active_image_refs.deinit(self.alloc);
        self.pane_batches.deinit(self.alloc);
        self.atlas.deinit();
        self.fonts.deinit();
        for (&self.frame_slots) |*slot| {
            slot.retained_textures.deinit(self.alloc);
            slot.retained_uploads.deinit(self.alloc);
            if (slot.resources.instance_buffer != null) objc.release(slot.resources.instance_buffer);
        }
        if (self.offscreen_resources.instance_buffer != null)
            objc.release(self.offscreen_resources.instance_buffer);
        objc.release(self.glyph_pipeline.state);
        objc.release(self.glyph_pipeline.library);
        objc.release(self.color_glyph_pipeline.state);
        objc.release(self.color_glyph_pipeline.library);
        objc.release(self.image_pipeline.state);
        objc.release(self.image_pipeline.library);
        objc.release(self.quad_pipeline.state);
        objc.release(self.quad_pipeline.library);
        objc.release(self.queue);
        objc.release(self.device);
    }

    pub fn cellMetrics(self: *const Renderer) font_mod.Metrics {
        return self.fonts.metrics;
    }

    pub fn setFrameCompletionHandler(
        self: *Renderer,
        context: ?*anyopaque,
        callback: FrameCompletionFn,
    ) void {
        self.completion_context = context;
        self.completion_fn = callback;
    }

    /// Builds the complete font-dependent renderer state before publishing
    /// either half. The existing FontSet/atlases remain usable on every error.
    pub fn reconfigureFont(self: *Renderer, options: FontOptions, pixel_scale: f32) !void {
        var replacement_fonts = try font_mod.FontSet.init(self.alloc, options);
        errdefer replacement_fonts.deinit();
        var replacement_atlas = try atlas_mod.GlyphAtlas.init(
            self.alloc,
            self.device,
            1024,
            pixel_scale,
        );
        errdefer replacement_atlas.deinit();

        var previous_fonts = self.fonts;
        var previous_atlas = self.atlas;
        self.fonts = replacement_fonts;
        self.atlas = replacement_atlas;
        self.pixel_scale = pixel_scale;
        previous_atlas.deinit();
        previous_fonts.deinit();

        // No instance may retain dimensions or UVs from the old font state.
        self.bg_list.clearRetainingCapacity();
        self.decor_list.clearRetainingCapacity();
        self.glyph_list.clearRetainingCapacity();
        self.color_glyph_list.clearRetainingCapacity();
        self.image_draws.clearRetainingCapacity();
        self.active_image_refs.clearRetainingCapacity();
        self.pane_batches.clearRetainingCapacity();
    }

    /// Build instance lists from a renderer-compatible grid source. Called
    /// with its terminal/snapshot lock held; does no GPU work.
    pub fn buildFrame(self: *Renderer, term: anytype, cursor_visible: bool) !void {
        return self.buildFrameWithGraphics(term, cursor_visible, null);
    }

    pub fn buildFrameWithGraphics(
        self: *Renderer,
        term: anytype,
        cursor_visible: bool,
        graphics: anytype,
    ) !void {
        self.beginFrame();
        const m = self.fonts.metrics;
        try self.appendPaneWithGraphics(term, cursor_visible, 0, graphics, null, .{
            .origin = .{ 0, 0 },
            .size = .{
                @as(f32, @floatFromInt(term.cols)) * m.cell_width,
                @as(f32, @floatFromInt(term.rows)) * m.cell_height,
            },
        });
        self.finishFrame();
    }

    pub fn beginFrame(self: *Renderer) void {
        self.bg_list.clearRetainingCapacity();
        self.decor_list.clearRetainingCapacity();
        self.glyph_list.clearRetainingCapacity();
        self.color_glyph_list.clearRetainingCapacity();
        self.image_draws.clearRetainingCapacity();
        self.active_image_refs.clearRetainingCapacity();
        self.pane_batches.clearRetainingCapacity();
    }

    /// Prepare an immutable viewer image resource away from AppKit. Metal
    /// resource creation is thread-safe; the texture is unpublished and has
    /// never been submitted when this initial copy occurs.
    pub fn prepareImageTexture(
        self: *const Renderer,
        width: u32,
        height: u32,
        rgba_bytes: []const u8,
    ) !objc.Id {
        const expected = try std.math.mul(usize, try std.math.mul(usize, width, height), 4);
        if (rgba_bytes.len != expected) return error.InvalidImageBytes;
        const texture = try metal.newTexture2D(
            self.device,
            metal.PixelFormat.rgba8_unorm,
            width,
            height,
        );
        errdefer objc.release(texture);
        metal.replaceRegion(texture, .{
            .size = .{ .width = width, .height = height, .depth = 1 },
        }, rgba_bytes.ptr, @as(usize, width) * 4);
        return texture;
    }

    pub fn sharedImageRowAlignment(self: *const Renderer) usize {
        return metal.minimumLinearTextureAlignment(self.device, metal.PixelFormat.rgba8_unorm);
    }

    fn prepareSharedImageTexture(
        self: *const Renderer,
        width: u32,
        height: u32,
        mapping: *anyopaque,
        mapping_length: usize,
        bytes_per_row: usize,
    ) !objc.Id {
        const active_row = try std.math.mul(usize, width, 4);
        if (bytes_per_row < active_row or
            try std.math.mul(usize, bytes_per_row, height) > mapping_length)
            return error.InvalidImageBytes;
        const buffer = metal.newBufferWithBytesNoCopy(self.device, mapping, mapping_length);
        if (buffer == null) return error.MetalBufferCreate;
        defer objc.release(buffer);
        const texture = try metal.newTexture2D(
            self.device,
            metal.PixelFormat.rgba8_unorm,
            width,
            height,
        );
        errdefer objc.release(texture);
        try metal.copyBufferToTexture(
            self.queue,
            buffer,
            bytes_per_row,
            width,
            height,
            texture,
        );
        return texture;
    }

    /// Prepare RFC 0023's owned upload away from AppKit without submitting
    /// GPU work. The no-copy source buffer and daemon lease move together into
    /// the live frame that first displays this generation.
    pub fn prepareSharedImageUpload(
        self: *Renderer,
        session_id: u64,
        id: u32,
        generation: u64,
        width: u32,
        height: u32,
        mapping: *anyopaque,
        mapping_length: usize,
        bytes_per_row: usize,
        staging_key: staged_upload_mod.StagingKey,
        release_context: ?*anyopaque,
        release_fn: staged_upload_mod.ReleaseFn,
    ) !*StagedUpload {
        const active_row = try std.math.mul(usize, width, 4);
        if (width == 0 or height == 0 or bytes_per_row < active_row or
            try std.math.mul(usize, bytes_per_row, height) > mapping_length)
            return error.InvalidImageBytes;
        const buffer = metal.newBufferWithBytesNoCopy(self.device, mapping, mapping_length);
        if (buffer == null) return error.MetalBufferCreate;
        errdefer objc.release(buffer);
        const texture = try metal.newTexture2DWithStorageMode(
            self.device,
            metal.PixelFormat.rgba8_unorm,
            width,
            height,
            metal.StorageMode.private,
        );
        errdefer objc.release(texture);
        return staged_upload_mod.Upload.create(
            self.alloc,
            .{ .session_id = session_id, .image_id = id, .generation = generation },
            staging_key,
            width,
            height,
            bytes_per_row,
            buffer,
            texture,
            release_context,
            release_fn,
        );
    }

    /// Append one independently clipped terminal pane to the current frame.
    /// Call beginFrame once, append at most RFC 0014's two panes, then
    /// finishFrame before presentation.
    pub fn appendPaneWithGraphics(
        self: *Renderer,
        term: anytype,
        cursor_visible: bool,
        hovered_hyperlink_id: u32,
        graphics: anytype,
        preedit: ?Preedit,
        rect: PaneRect,
    ) !void {
        if (self.pane_batches.items.len >= 2) return error.TooManyPanes;
        if (!validPaneRect(rect)) return error.InvalidPaneRect;
        const bg_start = self.bg_list.items.len;
        const decor_start = self.decor_list.items.len;
        const glyph_start = self.glyph_list.items.len;
        const color_glyph_start = self.color_glyph_list.items.len;
        const image_start = self.image_draws.items.len;

        const m = self.fonts.metrics;
        const theme = &self.theme;
        // Scrolled views never show the cursor (it lives at the bottom).
        const at_bottom = term.viewportOffset() == 0;

        var r: u16 = 0;
        while (r < term.rows) : (r += 1) {
            var col: u16 = 0;
            while (col < term.cols) : (col += 1) {
                const cell = term.viewCellAt(r, col);
                if (cell.flags.wide_spacer) continue;

                const cursor_here = cursor_visible and at_bottom and
                    term.modes.cursor_visible and
                    r == term.row and col == term.col;

                var fg = resolveFg(theme, cell.fg, cell.flags);
                var bg: ?vt.RGB = resolveBg(theme, cell.bg);
                if (cell.flags.reverse) {
                    const rbg = bg orelse theme.bg;
                    bg = fg;
                    fg = rbg;
                }
                if (term.viewCellSelected(r, col)) bg = theme.selection;
                if (term.viewCellSearchMatch(r, col)) bg = theme.search_match;
                if (term.viewCellSearchSelected(r, col)) bg = theme.search_selected;
                if (cursor_here) {
                    bg = theme.cursor;
                    fg = theme.bg;
                }
                if (cell.flags.hidden) fg = bg orelse theme.bg;

                const cell_cols: f32 = if (cell.flags.wide) 2 else 1;
                const x = rect.origin[0] + @as(f32, @floatFromInt(col)) * m.cell_width;
                const y = rect.origin[1] + @as(f32, @floatFromInt(r)) * m.cell_height;

                if (bg) |b| {
                    try self.bg_list.append(self.alloc, .{
                        .origin = .{ x, y },
                        .size = .{ m.cell_width * cell_cols, m.cell_height },
                        .color = rgba(b, 1),
                    });
                }

                if (!cell.flags.hidden and cell.cp != vt.graphics.unicode_placeholder and
                    (cell.cp != ' ' or cell.hasGrapheme()))
                {
                    const font_style = font_mod.Style.fromFlags(cell.flags.bold, cell.flags.italic);
                    const entry: ?atlas_mod.AtlasEntry = if (cell.hasGrapheme()) cluster: {
                        var utf8: [vt.max_grapheme_codepoints * 4]u8 = undefined;
                        var len: usize = 0;
                        len += std.unicode.utf8Encode(cell.cp, utf8[len..][0..4]) catch break :cluster null;
                        for (term.viewCellGrapheme(cell)) |suffix| {
                            len += std.unicode.utf8Encode(suffix, utf8[len..][0..4]) catch continue;
                        }
                        break :cluster try self.atlas.getOrRasterizeCluster(
                            &self.fonts,
                            utf8[0..len],
                            if (cell.flags.wide) 2 else 1,
                            font_style,
                        );
                    } else scalar: {
                        const ref = self.fonts.glyphFor(
                            cell.cp,
                            font_style,
                            if (cell.flags.wide) 2 else 1,
                        ) orelse break :scalar null;
                        break :scalar try self.atlas.getOrRasterize(&self.fonts, ref);
                    };
                    if (entry) |glyph| {
                        if (glyph.width > 0 and glyph.height > 0) {
                            const opacity: f32 = if (cell.flags.dim) 0.6 else 1;
                            const instance: GlyphInstance = .{
                                .origin = .{ x + glyph.bearing_x, y + self.fonts.cellTopForBearing(glyph.bearing_y) },
                                .size = .{ glyph.width, glyph.height },
                                .uv = .{ glyph.u0, glyph.v0, glyph.u1, glyph.v1 },
                                .color = rgba(fg, opacity),
                            };
                            switch (glyph.format) {
                                .mask => try self.glyph_list.append(self.alloc, instance),
                                .color => try self.color_glyph_list.append(self.alloc, instance),
                            }
                        }
                    }
                }

                const hyperlink_hovered = hovered_hyperlink_id != 0 and
                    cell.hyperlink_id == hovered_hyperlink_id;
                if (cell.flags.underline or hyperlink_hovered) {
                    const underline = if (cell.flags.underline) switch (cell.underline_color) {
                        .default => fg,
                        else => resolveFg(theme, cell.underline_color, vt.Flags{}),
                    } else fg;
                    try self.decor_list.append(self.alloc, .{
                        .origin = .{ x, y + m.ascent + 1 },
                        .size = .{ m.cell_width * cell_cols, 1 },
                        .color = rgba(underline, 1),
                    });
                }
                if (cell.flags.strike) {
                    try self.decor_list.append(self.alloc, .{
                        .origin = .{ x, y + m.ascent * 0.55 },
                        .size = .{ m.cell_width * cell_cols, 1 },
                        .color = rgba(fg, 1),
                    });
                }
            }
        }
        if (comptime @TypeOf(graphics) != @TypeOf(null)) {
            try self.appendImageDraws(graphics, rect.origin, image_start);
        }
        if (preedit) |value| try self.appendPreedit(term, value, rect);
        try self.pane_batches.append(self.alloc, .{
            .rect = rect,
            .backgrounds = rangeFrom(bg_start, self.bg_list.items.len),
            .decorations = rangeFrom(decor_start, self.decor_list.items.len),
            .glyphs = rangeFrom(glyph_start, self.glyph_list.items.len),
            .color_glyphs = rangeFrom(color_glyph_start, self.color_glyph_list.items.len),
            .images = rangeFrom(image_start, self.image_draws.items.len),
        });
    }

    pub fn finishFrame(self: *Renderer) void {
        var cached_index: usize = self.image_textures.items.len;
        while (cached_index > 0) {
            cached_index -= 1;
            const cached = self.image_textures.items[cached_index];
            var retained = false;
            for (self.active_image_refs.items) |image_ref| {
                if (cached.session_id == image_ref.session_id and
                    cached.id == image_ref.id and cached.generation == image_ref.generation)
                {
                    retained = true;
                    break;
                }
            }
            if (!retained) {
                if (cached.upload) |upload| upload.release();
                objc.release(cached.texture);
                _ = self.image_textures.orderedRemove(cached_index);
            }
        }
    }

    fn appendPreedit(self: *Renderer, term: anytype, preedit: Preedit, rect: PaneRect) !void {
        if (preedit.utf8.len == 0 or term.viewportOffset() != 0) return;
        const m = self.fonts.metrics;
        const theme = &self.theme;
        var row: u16 = term.row;
        var col: u16 = term.col;
        var cluster_start: usize = 0;
        var caret_drawn = false;

        while (cluster_start < preedit.utf8.len and row < term.rows) {
            const first_len = std.unicode.utf8ByteSequenceLength(preedit.utf8[cluster_start]) catch break;
            const first_end = cluster_start + first_len;
            if (first_end > preedit.utf8.len) break;
            var previous = std.unicode.utf8Decode(preedit.utf8[cluster_start..first_end]) catch break;
            var cluster_end = first_end;
            var state: Graphemes.IterState = .{};
            while (cluster_end < preedit.utf8.len) {
                const next_len = std.unicode.utf8ByteSequenceLength(preedit.utf8[cluster_end]) catch break;
                const next_end = cluster_end + next_len;
                if (next_end > preedit.utf8.len) break;
                const next = std.unicode.utf8Decode(preedit.utf8[cluster_end..next_end]) catch break;
                if (Graphemes.graphemeBreak(previous, next, &state)) break;
                previous = next;
                cluster_end = next_end;
            }

            var width = DisplayWidth.graphemeWidth(preedit.utf8[cluster_start..cluster_end]);
            if (width <= 0) width = 1;
            const cell_cols: u16 = if (width == 1) 1 else 2;
            if (@as(u32, col) + cell_cols > term.cols) {
                row += 1;
                col = 0;
                if (row >= term.rows) break;
            }
            const x = rect.origin[0] + @as(f32, @floatFromInt(col)) * m.cell_width;
            const y = rect.origin[1] + @as(f32, @floatFromInt(row)) * m.cell_height;

            if (!caret_drawn and preedit.caret_utf8 <= cluster_start) {
                try self.decor_list.append(self.alloc, .{
                    .origin = .{ x, y + 1 },
                    .size = .{ 2, @max(1, m.cell_height - 2) },
                    .color = rgba(theme.cursor, 1),
                });
                caret_drawn = true;
            }
            try self.bg_list.append(self.alloc, .{
                .origin = .{ x, y },
                .size = .{ m.cell_width * @as(f32, @floatFromInt(cell_cols)), m.cell_height },
                .color = rgba(theme.bg, 1),
            });
            const glyph = try self.atlas.getOrRasterizeCluster(
                &self.fonts,
                preedit.utf8[cluster_start..cluster_end],
                @intCast(cell_cols),
                .regular,
            );
            if (glyph.width > 0 and glyph.height > 0) {
                const instance: GlyphInstance = .{
                    .origin = .{ x + glyph.bearing_x, y + self.fonts.cellTopForBearing(glyph.bearing_y) },
                    .size = .{ glyph.width, glyph.height },
                    .uv = .{ glyph.u0, glyph.v0, glyph.u1, glyph.v1 },
                    .color = rgba(theme.fg, 1),
                };
                switch (glyph.format) {
                    .mask => try self.glyph_list.append(self.alloc, instance),
                    .color => try self.color_glyph_list.append(self.alloc, instance),
                }
            }
            try self.decor_list.append(self.alloc, .{
                .origin = .{ x, y + m.ascent + 1 },
                .size = .{ m.cell_width * @as(f32, @floatFromInt(cell_cols)), 1 },
                .color = rgba(theme.fg, 1),
            });

            col += cell_cols;
            if (col >= term.cols) {
                row += 1;
                col = 0;
            }
            cluster_start = cluster_end;
        }

        if (!caret_drawn and preedit.caret_utf8 >= preedit.utf8.len and row < term.rows) {
            const x = rect.origin[0] + @as(f32, @floatFromInt(col)) * m.cell_width;
            const y = rect.origin[1] + @as(f32, @floatFromInt(row)) * m.cell_height;
            try self.decor_list.append(self.alloc, .{
                .origin = .{ x, y + 1 },
                .size = .{ 2, @max(1, m.cell_height - 2) },
                .color = rgba(theme.cursor, 1),
            });
        }
    }

    fn appendImageDraws(
        self: *Renderer,
        graphics: anytype,
        pane_origin: [2]f32,
        image_start: usize,
    ) !void {
        for (graphics.images) |image| {
            try self.active_image_refs.append(self.alloc, .{
                .session_id = graphics.session_id,
                .id = image.id,
                .generation = image.generation,
            });
            if (self.findImageTexture(graphics.session_id, image.id, image.generation) != null) continue;
            const prepared_texture: objc.Id = if (comptime @hasField(@TypeOf(image), "texture"))
                image.texture
            else
                null;
            const pending_upload: ?*StagedUpload = if (comptime @hasField(@TypeOf(image), "upload"))
                image.upload
            else
                null;
            const texture = if (pending_upload) |upload|
                objc.retain(upload.texture)
            else if (prepared_texture != null)
                objc.retain(prepared_texture)
            else
                try self.prepareImageTexture(image.width, image.height, image.rgba);
            errdefer objc.release(texture);
            if (pending_upload) |upload| upload.retain();
            errdefer if (pending_upload) |upload| upload.release();
            try self.image_textures.append(self.alloc, .{
                .session_id = graphics.session_id,
                .id = image.id,
                .generation = image.generation,
                .texture = texture,
                .upload = pending_upload,
            });
        }

        const metrics = self.fonts.metrics;
        for (graphics.placements) |placement| {
            var source_width: u32 = 0;
            var source_height: u32 = 0;
            for (graphics.images) |image| {
                if (image.id == placement.image_id and image.generation == placement.generation) {
                    source_width = image.width;
                    source_height = image.height;
                    break;
                }
            }
            if (source_width == 0 or source_height == 0) continue;
            const texture = self.findImageTexture(
                graphics.session_id,
                placement.image_id,
                placement.generation,
            ) orelse continue;
            try self.image_draws.append(self.alloc, .{
                .texture = texture,
                .instance = .{
                    .origin = .{
                        pane_origin[0] + @as(f32, @floatFromInt(placement.col)) * metrics.cell_width +
                            @as(f32, @floatFromInt(placement.cell_offset_x)) / self.pixel_scale,
                        pane_origin[1] + @as(f32, @floatFromInt(placement.row)) * metrics.cell_height +
                            @as(f32, @floatFromInt(placement.cell_offset_y)) / self.pixel_scale,
                    },
                    .size = .{
                        @as(f32, @floatFromInt(placement.dest_width)) / self.pixel_scale,
                        @as(f32, @floatFromInt(placement.dest_height)) / self.pixel_scale,
                    },
                    .uv = .{
                        (@as(f32, @floatFromInt(placement.source_x)) + 0.5) /
                            @as(f32, @floatFromInt(source_width)),
                        (@as(f32, @floatFromInt(placement.source_y)) + 0.5) /
                            @as(f32, @floatFromInt(source_height)),
                        (@as(f32, @floatFromInt(placement.source_x + placement.source_width)) - 0.5) /
                            @as(f32, @floatFromInt(source_width)),
                        (@as(f32, @floatFromInt(placement.source_y + placement.source_height)) - 0.5) /
                            @as(f32, @floatFromInt(source_height)),
                    },
                },
                .z = placement.z,
                .image_id = placement.image_id,
            });
        }
        std.mem.sort(ImageDraw, self.image_draws.items[image_start..], {}, struct {
            fn lessThan(_: void, lhs: ImageDraw, rhs: ImageDraw) bool {
                if (lhs.z != rhs.z) return lhs.z < rhs.z;
                return lhs.image_id < rhs.image_id;
            }
        }.lessThan);
    }

    fn findImageTexture(self: *const Renderer, session_id: u64, id: u32, generation: u64) ?objc.Id {
        for (self.image_textures.items) |cached| {
            if (cached.session_id == session_id and cached.id == id and cached.generation == generation)
                return cached.texture;
        }
        return null;
    }

    /// Encode and present the lists built by buildFrame. Called without
    /// the terminal lock. viewport is the drawable size in points.
    /// `in_transaction` = live-resize synchronous presentation (see
    /// metal.endFrame).
    pub fn present(
        self: *Renderer,
        layer: objc.Id,
        viewport: [2]f32,
        in_transaction: bool,
    ) PresentResult {
        const slot = self.acquireFrameSlot() orelse return .no_frame_slot;
        const drawable = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
            layer,
            objc.sel("nextDrawable"),
        );
        if (drawable == null) return .no_drawable;
        const texture = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
            drawable,
            objc.sel("texture"),
        );

        self.retainFrameTextures(slot) catch return .encoding_failed;
        self.collectFrameUploads(slot) catch {
            self.releaseFrameTextures(slot);
            return .encoding_failed;
        };
        const command_buffer = metal.newCommandBuffer(self.queue);
        if (command_buffer == null) {
            self.releaseFrameUploads(slot);
            self.releaseFrameTextures(slot);
            return .encoding_failed;
        }
        self.encodeFrameUploads(slot, command_buffer) catch {
            self.releaseFrameUploads(slot);
            self.releaseFrameTextures(slot);
            return .encoding_failed;
        };
        const frame = self.encodeFrameOnCommandBuffer(
            command_buffer,
            texture,
            viewport,
            &slot.resources,
        ) orelse {
            self.releaseFrameUploads(slot);
            self.releaseFrameTextures(slot);
            return .encoding_failed;
        };
        slot.command_buffer = objc.retain(frame.command_buffer);
        slot.completion_succeeded.store(true, .release);
        slot.completion_context = self.completion_context;
        slot.completion_fn = self.completion_fn;
        slot.state.store(@intFromEnum(FrameSlotState.submitted), .release);
        metal.addCompletedHandler(frame.command_buffer, slot, frameCompleted);
        self.markFrameUploadsSubmitted(slot) catch {
            @panic("invalid staged-upload submission transition");
        };
        metal.endFrame(frame, drawable, in_transaction);
        return .submitted;
    }

    /// Render the current instance lists through the production Metal
    /// pipelines and read back an exact BGRA8 image. The caller supplies the
    /// point viewport and its backing-pixel dimensions explicitly so tests pin
    /// scale independently from font/grid geometry.
    pub fn renderOffscreen(
        self: *Renderer,
        alloc: std.mem.Allocator,
        viewport: [2]f32,
        pixel_width: u32,
        pixel_height: u32,
    ) !OffscreenImage {
        if (pixel_width == 0 or pixel_height == 0) return error.InvalidOffscreenSize;
        const texture = try metal.newTexture2D(
            self.device,
            metal.PixelFormat.bgra8_unorm,
            pixel_width,
            pixel_height,
        );
        defer objc.release(texture);

        // Exercise the same upload-before-draw command-buffer ordering as the
        // live path. This makes exact-pixel tests an oracle for staged-image
        // publication instead of silently testing only already-ready images.
        var upload_slot: FrameSlot = .{};
        defer upload_slot.retained_uploads.deinit(self.alloc);
        try self.collectFrameUploads(&upload_slot);
        errdefer self.releaseFrameUploads(&upload_slot);

        const command_buffer = metal.newCommandBuffer(self.queue);
        if (command_buffer == null) return error.OffscreenCommandEncoding;
        try self.encodeFrameUploads(&upload_slot, command_buffer);
        const frame = self.encodeFrameOnCommandBuffer(
            command_buffer,
            texture,
            viewport,
            &self.offscreen_resources,
        ) orelse return error.OffscreenCommandEncoding;
        self.markFrameUploadsSubmitted(&upload_slot) catch
            @panic("invalid staged-upload submission transition");
        metal.endOffscreen(frame) catch |err| {
            self.completeOffscreenUploads(&upload_slot, false);
            return err;
        };
        self.completeOffscreenUploads(&upload_slot, true);

        const row_bytes = try std.math.mul(usize, pixel_width, 4);
        const byte_len = try std.math.mul(usize, row_bytes, pixel_height);
        const pixels = try alloc.alloc(u8, byte_len);
        errdefer alloc.free(pixels);
        metal.getBytes(texture, pixels.ptr, row_bytes, .{
            .size = .{ .width = pixel_width, .height = pixel_height, .depth = 1 },
        });
        return .{
            .alloc = alloc,
            .width = pixel_width,
            .height = pixel_height,
            .pixels = pixels,
        };
    }

    fn encodeFrameOnCommandBuffer(
        self: *Renderer,
        command_buffer: objc.Id,
        texture: objc.Id,
        viewport: [2]f32,
        resources: *FrameResources,
    ) ?metal.Frame {
        const bg_bytes = self.bg_list.items.len * @sizeOf(QuadInstance);
        const decor_bytes = self.decor_list.items.len * @sizeOf(QuadInstance);
        const glyph_bytes = self.glyph_list.items.len * @sizeOf(GlyphInstance);
        const color_glyph_bytes = self.color_glyph_list.items.len * @sizeOf(GlyphInstance);
        const total = bg_bytes + decor_bytes + glyph_bytes + color_glyph_bytes;

        if (total > 0) {
            if (!self.ensureInstanceBuffer(resources, total)) return null;
            const contents = metal.bufferContents(resources.instance_buffer);
            @memcpy(contents[0..bg_bytes], std.mem.sliceAsBytes(self.bg_list.items));
            @memcpy(contents[bg_bytes..][0..decor_bytes], std.mem.sliceAsBytes(self.decor_list.items));
            @memcpy(contents[bg_bytes + decor_bytes ..][0..glyph_bytes], std.mem.sliceAsBytes(self.glyph_list.items));
            @memcpy(
                contents[bg_bytes + decor_bytes + glyph_bytes ..][0..color_glyph_bytes],
                std.mem.sliceAsBytes(self.color_glyph_list.items),
            );
        }

        const t = self.theme.bg;
        const clear: metal.ClearColor = .{
            .red = @as(f64, @floatFromInt(t.r)) / 255.0,
            .green = @as(f64, @floatFromInt(t.g)) / 255.0,
            .blue = @as(f64, @floatFromInt(t.b)) / 255.0,
            .alpha = 1,
        };
        const frame = metal.beginFrameOnCommandBuffer(command_buffer, texture, clear) orelse return null;
        metal.setVertexBytes(frame.encoder, &viewport, @sizeOf([2]f32), 1);

        const texture_size = metal.textureSize(texture);
        for (self.pane_batches.items) |pane| {
            const scissor = paneScissor(pane.rect, viewport, texture_size) orelse continue;
            metal.setScissorRect(frame.encoder, scissor);
            self.drawImages(frame, pane.images, .below_backgrounds);

            if (pane.backgrounds.len > 0) {
                metal.setPipeline(frame.encoder, self.quad_pipeline.state);
                metal.setVertexBuffer(
                    frame.encoder,
                    resources.instance_buffer,
                    pane.backgrounds.start * @sizeOf(QuadInstance),
                    0,
                );
                metal.drawQuads(frame.encoder, pane.backgrounds.len);
            }
            self.drawImages(frame, pane.images, .below_text);
            if (pane.glyphs.len > 0) {
                metal.setPipeline(frame.encoder, self.glyph_pipeline.state);
                metal.setVertexBuffer(
                    frame.encoder,
                    resources.instance_buffer,
                    bg_bytes + decor_bytes + pane.glyphs.start * @sizeOf(GlyphInstance),
                    0,
                );
                metal.setFragmentTexture(frame.encoder, self.atlas.texture(.mask), 0);
                metal.drawQuads(frame.encoder, pane.glyphs.len);
            }
            if (pane.color_glyphs.len > 0) {
                metal.setPipeline(frame.encoder, self.color_glyph_pipeline.state);
                metal.setVertexBuffer(
                    frame.encoder,
                    resources.instance_buffer,
                    bg_bytes + decor_bytes + glyph_bytes +
                        pane.color_glyphs.start * @sizeOf(GlyphInstance),
                    0,
                );
                metal.setFragmentTexture(frame.encoder, self.atlas.texture(.color), 0);
                metal.drawQuads(frame.encoder, pane.color_glyphs.len);
            }
            if (pane.decorations.len > 0) {
                metal.setPipeline(frame.encoder, self.quad_pipeline.state);
                metal.setVertexBuffer(
                    frame.encoder,
                    resources.instance_buffer,
                    bg_bytes + pane.decorations.start * @sizeOf(QuadInstance),
                    0,
                );
                metal.drawQuads(frame.encoder, pane.decorations.len);
            }
            self.drawImages(frame, pane.images, .above_text);
        }

        return frame;
    }

    fn ensureInstanceBuffer(
        self: *Renderer,
        resources: *FrameResources,
        required: usize,
    ) bool {
        if (required <= resources.instance_capacity) return true;
        const capacity = required * 2;
        const replacement = metal.newBufferWithLength(self.device, capacity);
        if (replacement == null) return false;
        if (resources.instance_buffer != null) objc.release(resources.instance_buffer);
        resources.instance_buffer = replacement;
        resources.instance_capacity = capacity;
        return true;
    }

    fn acquireFrameSlot(self: *Renderer) ?*FrameSlot {
        for (&self.frame_slots) |*slot| {
            const state: FrameSlotState = @enumFromInt(slot.state.load(.acquire));
            if (state == .completed) self.reclaimFrameSlot(slot);
            if (slot.state.load(.acquire) == @intFromEnum(FrameSlotState.available))
                return slot;
        }
        return null;
    }

    fn retainFrameTextures(self: *Renderer, slot: *FrameSlot) !void {
        std.debug.assert(slot.retained_textures.items.len == 0);
        try slot.retained_textures.ensureTotalCapacity(
            self.alloc,
            self.image_draws.items.len + 2,
        );
        if (self.glyph_list.items.len > 0)
            slot.retained_textures.appendAssumeCapacity(objc.retain(self.atlas.texture(.mask)));
        if (self.color_glyph_list.items.len > 0)
            slot.retained_textures.appendAssumeCapacity(objc.retain(self.atlas.texture(.color)));
        for (self.image_draws.items) |draw| {
            var already_retained = false;
            for (slot.retained_textures.items) |texture| {
                if (texture == draw.texture) {
                    already_retained = true;
                    break;
                }
            }
            if (!already_retained)
                slot.retained_textures.appendAssumeCapacity(objc.retain(draw.texture));
        }
    }

    fn collectFrameUploads(self: *Renderer, slot: *FrameSlot) !void {
        std.debug.assert(slot.retained_uploads.items.len == 0);
        try slot.retained_uploads.ensureTotalCapacity(self.alloc, frame_slot_count);
        for (self.image_draws.items) |draw| {
            const upload = self.pendingUploadForTexture(draw.texture) orelse continue;
            if (upload.currentState() != .queued) continue;
            var already_retained = false;
            for (slot.retained_uploads.items) |retained| {
                if (retained == upload) {
                    already_retained = true;
                    break;
                }
            }
            if (already_retained) continue;
            if (slot.retained_uploads.items.len == frame_slot_count)
                return error.TooManyStagedUploads;
            upload.retain();
            slot.retained_uploads.appendAssumeCapacity(upload);
        }
    }

    fn encodeFrameUploads(_: *Renderer, slot: *FrameSlot, command_buffer: objc.Id) !void {
        if (slot.retained_uploads.items.len == 0) return;
        // Validate before opening the encoder so every error path leaves the
        // command buffer structurally complete.
        for (slot.retained_uploads.items) |upload| {
            if (upload.source_buffer == null) return error.MissingStagedSource;
        }
        const encoder = try metal.beginBlit(command_buffer);
        for (slot.retained_uploads.items) |upload| {
            metal.encodeBufferToTextureOnEncoder(
                encoder,
                upload.source_buffer,
                upload.bytes_per_row,
                upload.width,
                upload.height,
                upload.texture,
            );
        }
        metal.endEncoding(encoder);
    }

    fn completeOffscreenUploads(self: *Renderer, slot: *FrameSlot, succeeded: bool) void {
        for (slot.retained_uploads.items) |upload| {
            upload.finish(succeeded) catch
                std.log.err("invalid staged-upload offscreen completion transition", .{});
            if (!succeeded) self.removeImageTexture(upload.resource);
            upload.release();
        }
        slot.retained_uploads.clearRetainingCapacity();
    }

    fn markFrameUploadsSubmitted(self: *Renderer, slot: *FrameSlot) !void {
        for (slot.retained_uploads.items) |upload| {
            try upload.markSubmitted();
            for (self.image_textures.items) |*cached| {
                if (cached.upload != upload) continue;
                cached.upload = null;
                upload.release();
                break;
            }
        }
    }

    fn pendingUploadForTexture(self: *Renderer, texture: objc.Id) ?*StagedUpload {
        for (self.image_textures.items) |cached| {
            if (cached.texture == texture) return cached.upload;
        }
        return null;
    }

    fn releaseFrameUploads(_: *Renderer, slot: *FrameSlot) void {
        for (slot.retained_uploads.items) |upload| upload.release();
        slot.retained_uploads.clearRetainingCapacity();
    }

    fn releaseFrameTextures(_: *Renderer, slot: *FrameSlot) void {
        for (slot.retained_textures.items) |texture| objc.release(texture);
        slot.retained_textures.clearRetainingCapacity();
    }

    fn reclaimFrameSlot(self: *Renderer, slot: *FrameSlot) void {
        std.debug.assert(slot.state.load(.acquire) == @intFromEnum(FrameSlotState.completed));
        const succeeded = slot.completion_succeeded.load(.acquire);
        for (slot.retained_uploads.items) |upload| {
            upload.finish(succeeded) catch
                std.log.err("invalid staged-upload completion transition", .{});
            if (!succeeded) self.removeImageTexture(upload.resource);
            upload.release();
        }
        slot.retained_uploads.clearRetainingCapacity();
        self.releaseFrameTextures(slot);
        if (slot.command_buffer != null) {
            objc.release(slot.command_buffer);
            slot.command_buffer = null;
        }
        slot.state.store(@intFromEnum(FrameSlotState.available), .release);
    }

    fn removeImageTexture(self: *Renderer, key: staged_upload_mod.ResourceKey) void {
        var index = self.image_textures.items.len;
        while (index > 0) {
            index -= 1;
            const cached = self.image_textures.items[index];
            if (cached.session_id != key.session_id or cached.id != key.image_id or
                cached.generation != key.generation) continue;
            if (cached.upload) |upload| upload.release();
            objc.release(cached.texture);
            _ = self.image_textures.orderedRemove(index);
            return;
        }
    }

    /// Main-thread completion drain. It is invoked independently of display
    /// cadence so an idle final frame still releases its daemon staging slot.
    pub fn reclaimCompletedFrames(self: *Renderer) bool {
        var failed = false;
        for (&self.frame_slots) |*slot| {
            if (slot.state.load(.acquire) != @intFromEnum(FrameSlotState.completed)) continue;
            if (!slot.completion_succeeded.load(.acquire)) failed = true;
            self.reclaimFrameSlot(slot);
        }
        return failed;
    }

    pub fn prepareForClientShutdown(self: *Renderer) void {
        self.finishLiveFrames();
        for (self.image_textures.items) |cached| {
            if (cached.upload) |upload| upload.release();
            objc.release(cached.texture);
        }
        self.image_textures.clearRetainingCapacity();
    }

    fn finishLiveFrames(self: *Renderer) void {
        for (&self.frame_slots) |*slot| {
            const state: FrameSlotState = @enumFromInt(slot.state.load(.acquire));
            if (state == .submitted) {
                metal.waitUntilCompleted(slot.command_buffer);
                while (slot.state.load(.acquire) != @intFromEnum(FrameSlotState.completed))
                    std.Thread.yield() catch {};
            }
            if (slot.state.load(.acquire) == @intFromEnum(FrameSlotState.completed))
                self.reclaimFrameSlot(slot);
        }
    }

    const ImageLayer = enum { below_backgrounds, below_text, above_text };

    fn drawImages(
        self: *Renderer,
        frame: metal.Frame,
        image_range: InstanceRange,
        layer: ImageLayer,
    ) void {
        for (self.image_draws.items[image_range.start..][0..image_range.len]) |draw| {
            const matches = switch (layer) {
                .below_backgrounds => draw.z < image_below_cell_backgrounds,
                .below_text => draw.z >= image_below_cell_backgrounds and draw.z < 0,
                .above_text => draw.z >= 0,
            };
            if (!matches) continue;
            metal.setPipeline(frame.encoder, self.image_pipeline.state);
            metal.setVertexBytes(frame.encoder, &draw.instance, @sizeOf(ImageInstance), 0);
            metal.setFragmentTexture(frame.encoder, draw.texture, 0);
            metal.drawQuads(frame.encoder, 1);
        }
    }

    fn resolveFg(theme: *const Theme, color: vt.Color, flags: anytype) vt.RGB {
        return switch (color) {
            .default => theme.fg,
            .indexed => |idx| blk: {
                // Classic bold-brightens for the base 8.
                const i = if (flags.bold and idx < 8) idx + 8 else idx;
                break :blk if (i < 16) theme.ansi[i] else vt.color.cube256(i);
            },
            .rgb => |c| c,
        };
    }

    /// null = default background (the clear color already painted it).
    fn resolveBg(theme: *const Theme, color: vt.Color) ?vt.RGB {
        return switch (color) {
            .default => null,
            .indexed => |idx| if (idx < 16) theme.ansi[idx] else vt.color.cube256(idx),
            .rgb => |c| c,
        };
    }

    fn rgba(c: vt.RGB, alpha: f32) [4]f32 {
        return .{
            @as(f32, @floatFromInt(c.r)) / 255.0,
            @as(f32, @floatFromInt(c.g)) / 255.0,
            @as(f32, @floatFromInt(c.b)) / 255.0,
            alpha,
        };
    }
};

fn frameCompleted(context: ?*anyopaque, command_buffer: objc.Id) callconv(.c) void {
    const slot: *FrameSlot = @ptrCast(@alignCast(context.?));
    const succeeded = metal.commandBufferStatus(command_buffer) == metal.CommandBufferStatus.completed;
    slot.completion_succeeded.store(succeeded, .release);
    if (!succeeded)
        std.log.err("live Metal command buffer failed", .{});
    slot.state.store(@intFromEnum(FrameSlotState.completed), .release);
    if (slot.completion_fn) |callback| callback(slot.completion_context);
}

fn rangeFrom(start: usize, end: usize) InstanceRange {
    return .{ .start = start, .len = end - start };
}

test "preedit caret follows grapheme width and pane wrapping" {
    try std.testing.expectEqual(PreeditCell{ .row = 3, .col = 1 }, preeditCaretCell(
        "ab",
        2,
        2,
        3,
        4,
    ));
    const family = "👨🏽‍💻";
    try std.testing.expectEqual(PreeditCell{ .row = 1, .col = 2 }, preeditCaretCell(
        family,
        family.len,
        1,
        0,
        8,
    ));
}

fn validPaneRect(rect: PaneRect) bool {
    return std.math.isFinite(rect.origin[0]) and std.math.isFinite(rect.origin[1]) and
        std.math.isFinite(rect.size[0]) and std.math.isFinite(rect.size[1]) and
        rect.origin[0] >= 0 and rect.origin[1] >= 0 and rect.size[0] > 0 and rect.size[1] > 0;
}

fn paneScissor(
    rect: PaneRect,
    viewport: [2]f32,
    texture: metal.TextureSize,
) ?metal.ScissorRect {
    if (viewport[0] <= 0 or viewport[1] <= 0 or rect.size[0] <= 0 or rect.size[1] <= 0)
        return null;
    const scale_x = @as(f32, @floatFromInt(texture.width)) / viewport[0];
    const scale_y = @as(f32, @floatFromInt(texture.height)) / viewport[1];
    const x0 = @max(@as(f32, 0), @floor(rect.origin[0] * scale_x));
    const y0 = @max(@as(f32, 0), @floor(rect.origin[1] * scale_y));
    const x1 = @min(
        @as(f32, @floatFromInt(texture.width)),
        @ceil((rect.origin[0] + rect.size[0]) * scale_x),
    );
    const y1 = @min(
        @as(f32, @floatFromInt(texture.height)),
        @ceil((rect.origin[1] + rect.size[1]) * scale_y),
    );
    if (x1 <= x0 or y1 <= y0) return null;
    return .{
        .x = @intFromFloat(x0),
        .y = @intFromFloat(y0),
        .width = @intFromFloat(x1 - x0),
        .height = @intFromFloat(y1 - y0),
    };
}

fn renderGolden(renderer: *Renderer, term: anytype, cursor_visible: bool) !OffscreenImage {
    try renderer.buildFrame(term, cursor_visible);
    const metrics = renderer.cellMetrics();
    const viewport: [2]f32 = .{
        metrics.cell_width * @as(f32, @floatFromInt(term.cols)),
        metrics.cell_height * @as(f32, @floatFromInt(term.rows)),
    };
    return renderer.renderOffscreen(
        std.testing.allocator,
        viewport,
        @intFromFloat(@ceil(viewport[0])),
        @intFromFloat(@ceil(viewport[1])),
    );
}

fn expectGolden(image: *const OffscreenImage, width: u32, height: u32, hash: u64) !void {
    try std.testing.expectEqual(width, image.width);
    try std.testing.expectEqual(height, image.height);
    try std.testing.expectEqual(hash, std.hash.Wyhash.hash(0, image.pixels));
}

fn expectSystemGolden(image: *const OffscreenImage, width: u32, height: u32, hash: u64) !void {
    try std.testing.expectEqual(width, image.width);
    try std.testing.expectEqual(height, image.height);
    if (!@import("test_options").portable_system_goldens) {
        try std.testing.expectEqual(hash, std.hash.Wyhash.hash(0, image.pixels));
        return;
    }

    try std.testing.expect(image.pixels.len >= 8 and image.pixels.len % 4 == 0);
    const first = image.pixels[0..4];
    var saw_different_pixel = false;
    var offset: usize = 4;
    while (offset < image.pixels.len) : (offset += 4) {
        if (!std.mem.eql(u8, first, image.pixels[offset..][0..4])) {
            saw_different_pixel = true;
            break;
        }
    }
    try std.testing.expect(saw_different_pixel);
}

const UploadReleaseCapture = struct {
    count: usize = 0,
    record: staged_upload_mod.ReleaseRecord = undefined,

    fn release(context: ?*anyopaque, record: staged_upload_mod.ReleaseRecord) void {
        const self: *UploadReleaseCapture = @ptrCast(@alignCast(context.?));
        self.count += 1;
        self.record = record;
    }
};

test "shared read-only staging memory blits into an immutable texture" {
    const alloc = std.testing.allocator;
    var renderer = Renderer.init(alloc, .{ .family = "Menlo", .size = 13 }, 1) catch |err| switch (err) {
        error.NoMetalDevice => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    const page_size_signed = libc.sysconf(@intFromEnum(libc._SC.PAGESIZE));
    if (page_size_signed <= 0) return error.SkipZigTest;
    const page_size: usize = @intCast(page_size_signed);
    const mapping = libc.mmap(
        null,
        page_size,
        libc.PROT{ .READ = true, .WRITE = true },
        libc.MAP{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    if (mapping == libc.MAP_FAILED) return error.SkipZigTest;
    defer _ = libc.munmap(@ptrCast(@alignCast(mapping)), page_size);
    const bytes: [*]u8 = @ptrCast(mapping);
    const source = [_]u8{ 255, 0, 0, 255, 0, 0, 255, 255 };
    @memcpy(bytes[0..8], &source);
    if (libc.mprotect(@ptrCast(@alignCast(mapping)), page_size, libc.PROT{ .READ = true }) < 0)
        return error.SkipZigTest;
    const row_alignment = renderer.sharedImageRowAlignment();
    try std.testing.expect(row_alignment >= 8 and std.math.isPowerOfTwo(row_alignment));
    const texture = try renderer.prepareSharedImageTexture(
        2,
        1,
        mapping,
        page_size,
        row_alignment,
    );
    defer objc.release(texture);
    var copied: [8]u8 = undefined;
    metal.getBytes(texture, &copied, 8, .{ .size = .{ .width = 2, .height = 1, .depth = 1 } });
    try std.testing.expectEqualSlices(u8, &source, &copied);
}

test "offscreen production frame fuses staged upload before image draw" {
    const alloc = std.testing.allocator;
    var renderer = Renderer.init(alloc, .{ .family = "Menlo", .size = 13 }, 1) catch |err| switch (err) {
        error.NoMetalDevice => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var terminal = try vt.Vt.init(alloc, 4, 2);
    defer terminal.deinit();

    const page_size_signed = libc.sysconf(@intFromEnum(libc._SC.PAGESIZE));
    if (page_size_signed <= 0) return error.SkipZigTest;
    const page_size: usize = @intCast(page_size_signed);
    const bytes_per_row = renderer.sharedImageRowAlignment();
    const width: u32 = 4;
    const height: u32 = 4;
    try std.testing.expect(bytes_per_row >= width * 4);
    try std.testing.expect(bytes_per_row * height <= page_size);
    const mapping = libc.mmap(
        null,
        page_size,
        libc.PROT{ .READ = true, .WRITE = true },
        libc.MAP{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    if (mapping == libc.MAP_FAILED) return error.SkipZigTest;
    defer _ = libc.munmap(@ptrCast(@alignCast(mapping)), page_size);
    const bytes: [*]u8 = @ptrCast(mapping);
    @memset(bytes[0..page_size], 0xa5);
    for (0..height) |row| {
        for (0..width) |col| {
            const offset = row * bytes_per_row + col * 4;
            bytes[offset..][0..4].* = .{ 255, 0, 0, 255 };
        }
    }
    if (libc.mprotect(@ptrCast(@alignCast(mapping)), page_size, libc.PROT{ .READ = true }) < 0)
        return error.SkipZigTest;

    var capture: UploadReleaseCapture = .{};
    const upload = try renderer.prepareSharedImageUpload(
        91,
        7,
        11,
        width,
        height,
        mapping,
        page_size,
        bytes_per_row,
        .{ .connection_epoch = 3, .slot_index = 2, .lease_token = 41 },
        &capture,
        UploadReleaseCapture.release,
    );
    defer upload.release();
    const images = [_]struct {
        id: u32,
        generation: u64,
        width: u32,
        height: u32,
        rgba: []const u8,
        texture: objc.Id,
        upload: ?*StagedUpload,
    }{.{
        .id = 7,
        .generation = 11,
        .width = width,
        .height = height,
        .rgba = &.{},
        .texture = null,
        .upload = upload,
    }};
    const placements = [_]struct {
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
    }{.{
        .image_id = 7,
        .generation = 11,
        .placement_id = 1,
        .row = 0,
        .col = 0,
        .cell_offset_x = 0,
        .cell_offset_y = 0,
        .source_x = 0,
        .source_y = 0,
        .source_width = width,
        .source_height = height,
        .dest_width = width,
        .dest_height = height,
        .z = 0,
    }};
    const graphics = .{ .session_id = @as(u64, 91), .images = &images, .placements = &placements };
    try renderer.buildFrameWithGraphics(terminal.term, false, graphics);
    try std.testing.expectEqual(staged_upload_mod.State.queued, upload.currentState());
    try std.testing.expectEqual(@as(usize, 0), capture.count);

    const metrics = renderer.cellMetrics();
    const viewport: [2]f32 = .{ metrics.cell_width * 4, metrics.cell_height * 2 };
    const pixel_width: u32 = @intFromFloat(@ceil(viewport[0]));
    const pixel_height: u32 = @intFromFloat(@ceil(viewport[1]));
    var output = try renderer.renderOffscreen(alloc, viewport, pixel_width, pixel_height);
    defer output.deinit();

    const sample = (@as(usize, 2) * pixel_width + 2) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, output.pixels[sample..][0..4]);
    try std.testing.expectEqual(staged_upload_mod.State.completed, upload.currentState());
    try std.testing.expect(upload.source_buffer == null);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(@as(u64, 3), capture.record.key.connection_epoch);
    try std.testing.expectEqual(@as(u8, 2), capture.record.key.slot_index);
    try std.testing.expectEqual(@as(u64, 41), capture.record.key.lease_token);
    try std.testing.expect(!capture.record.disable_after_release);
}

test "offscreen Metal golden: backgrounds selection and cursor" {
    const alloc = std.testing.allocator;
    var renderer = Renderer.init(alloc, .{ .family = "Menlo", .size = 13 }, 1) catch |err| switch (err) {
        error.NoMetalDevice => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var terminal = try vt.Vt.init(alloc, 6, 3);
    defer terminal.deinit();

    terminal.feed("\x1b[48;2;32;64;96m  \x1b[0m\x1b[48;5;1m  \x1b[0m");
    terminal.feed("\x1b[2;1H\x1b[48;2;96;48;24m   \x1b[0m");
    terminal.term.selectionStart(0, 1, .char);
    terminal.term.selectionDrag(1, 2);
    terminal.feed("\x1b[3;5H");

    var image = try renderGolden(&renderer, terminal.term, true);
    defer image.deinit();
    try expectGolden(&image, 47, 48, 17013566303040974354);
}

test "one Metal frame clips two terminal panes independently" {
    const alloc = std.testing.allocator;
    var renderer = Renderer.init(alloc, .{ .family = "Menlo", .size = 13 }, 1) catch |err| switch (err) {
        error.NoMetalDevice => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var left = try vt.Vt.init(alloc, 3, 1);
    defer left.deinit();
    var right = try vt.Vt.init(alloc, 2, 1);
    defer right.deinit();
    left.feed("\x1b[48;2;255;0;0m   ");
    right.feed("\x1b[48;2;0;0;255m  ");

    const metrics = renderer.cellMetrics();
    const pane_width = metrics.cell_width * 2;
    const viewport: [2]f32 = .{ pane_width * 2, metrics.cell_height };
    renderer.beginFrame();
    try renderer.appendPaneWithGraphics(left.term, false, 0, null, null, .{
        .origin = .{ 0, 0 },
        .size = .{ pane_width, metrics.cell_height },
    });
    try renderer.appendPaneWithGraphics(right.term, false, 0, null, null, .{
        .origin = .{ pane_width, 0 },
        .size = .{ pane_width, metrics.cell_height },
    });
    try std.testing.expectError(error.TooManyPanes, renderer.appendPaneWithGraphics(
        right.term,
        false,
        0,
        null,
        null,
        .{ .origin = .{ 0, 0 }, .size = .{ pane_width, metrics.cell_height } },
    ));
    renderer.finishFrame();
    try std.testing.expectEqual(@as(usize, 2), renderer.pane_batches.items.len);

    const width: u32 = @intFromFloat(@ceil(viewport[0]));
    const height: u32 = @intFromFloat(@ceil(viewport[1]));
    var image = try renderer.renderOffscreen(alloc, viewport, width, height);
    defer image.deinit();
    const sample_y: usize = @intFromFloat(@floor(metrics.cell_height / 2));
    const left_x: usize = @intFromFloat(@floor(metrics.cell_width));
    const right_x: usize = @intFromFloat(@floor(pane_width + metrics.cell_width));
    const left_pixel = (sample_y * width + left_x) * 4;
    const right_pixel = (sample_y * width + right_x) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, image.pixels[left_pixel..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.pixels[right_pixel..][0..4]);
}

test "OSC 8 hover decorates only the matching semantic range" {
    const alloc = std.testing.allocator;
    var renderer = Renderer.init(alloc, .{ .family = "Menlo", .size = 13 }, 1) catch |err| switch (err) {
        error.NoMetalDevice => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var terminal = try vt.Vt.init(alloc, 4, 2);
    defer terminal.deinit();
    terminal.feed("\x1b]8;id=docs;https://example.com\x1b\\abcdef\x1b]8;;\x1b\\Z");
    const link_id = terminal.term.viewCellAt(0, 0).hyperlink_id;
    try std.testing.expect(link_id != 0);

    const metrics = renderer.cellMetrics();
    const viewport: [2]f32 = .{ metrics.cell_width * 4, metrics.cell_height * 2 };
    renderer.beginFrame();
    try renderer.appendPaneWithGraphics(terminal.term, false, 0, null, null, .{
        .origin = .{ 0, 0 },
        .size = viewport,
    });
    try std.testing.expectEqual(@as(usize, 0), renderer.decor_list.items.len);

    renderer.beginFrame();
    try renderer.appendPaneWithGraphics(terminal.term, false, link_id, null, null, .{
        .origin = .{ 0, 0 },
        .size = viewport,
    });
    try std.testing.expectEqual(@as(usize, 6), renderer.decor_list.items.len);
    try std.testing.expectEqual(@as(u32, 0), terminal.term.viewCellAt(1, 2).hyperlink_id);
}

test "offscreen Metal golden: mask glyphs and decorations" {
    const alloc = std.testing.allocator;
    var renderer = Renderer.init(alloc, .{ .family = "Menlo", .size = 13 }, 1) catch |err| switch (err) {
        error.NoMetalDevice => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var terminal = try vt.Vt.init(alloc, 8, 2);
    defer terminal.deinit();

    terminal.feed("\x1b[4mA\x1b[0m\x1b[9mB\x1b[0m\x1b[1;3mC\x1b[0m─");
    terminal.feed("\x1b[2;1H\x1b[2mD\x1b[0m\x1b[7mE\x1b[0m┼");

    var image = try renderGolden(&renderer, terminal.term, false);
    defer image.deinit();
    try expectSystemGolden(&image, 63, 32, 9997305713237981640);
}

test "offscreen Metal golden: mixed fallback and color glyphs" {
    const alloc = std.testing.allocator;
    var renderer = Renderer.init(alloc, .{ .family = "Menlo", .size = 13 }, 1) catch |err| switch (err) {
        error.NoMetalDevice => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var terminal = try vt.Vt.init(alloc, 12, 2);
    defer terminal.deinit();

    terminal.feed("A─😀界");
    terminal.feed("\x1b[?2027h\x1b[2;1He\u{0301} कि 👨🏽‍💻");

    var image = try renderGolden(&renderer, terminal.term, false);
    defer image.deinit();
    try expectSystemGolden(&image, 94, 32, 6411646892288276539);
}

test "offscreen Metal draws a Kitty image above terminal cells" {
    const alloc = std.testing.allocator;
    var renderer = Renderer.init(alloc, .{ .family = "Menlo", .size = 13 }, 1) catch |err| switch (err) {
        error.NoMetalDevice => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var terminal = try vt.Vt.init(alloc, 4, 2);
    defer terminal.deinit();

    var rgba: [4 * 4 * 4]u8 = undefined;
    for (0..16) |pixel| rgba[pixel * 4 ..][0..4].* = .{ 255, 0, 0, 255 };
    const images = [_]struct {
        id: u32,
        generation: u64,
        width: u32,
        height: u32,
        rgba: []const u8,
    }{.{ .id = 7, .generation = 11, .width = 4, .height = 4, .rgba = &rgba }};
    const placements = [_]struct {
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
    }{.{
        .image_id = 7,
        .generation = 11,
        .placement_id = 1,
        .row = 0,
        .col = 0,
        .cell_offset_x = 0,
        .cell_offset_y = 0,
        .source_x = 0,
        .source_y = 0,
        .source_width = 4,
        .source_height = 4,
        .dest_width = 4,
        .dest_height = 4,
        .z = 0,
    }};
    const graphics = .{ .session_id = @as(u64, 9), .images = &images, .placements = &placements };
    try renderer.buildFrameWithGraphics(terminal.term, false, graphics);
    const metrics = renderer.cellMetrics();
    const viewport: [2]f32 = .{ metrics.cell_width * 4, metrics.cell_height * 2 };
    const width: u32 = @intFromFloat(@ceil(viewport[0]));
    const height: u32 = @intFromFloat(@ceil(viewport[1]));
    var image = try renderer.renderOffscreen(alloc, viewport, width, height);
    defer image.deinit();

    const red = (@as(usize, 2) * width + 2) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, image.pixels[red..][0..4]);
    const background = (@as(usize, height - 2) * width + width - 2) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 24, 20, 16, 255 }, image.pixels[background..][0..4]);

    // Image ids and generations are session-local. Reusing both in another
    // session must upload that session's resource rather than aliasing the
    // previous Metal texture.
    var blue_rgba: [4 * 4 * 4]u8 = undefined;
    for (0..16) |pixel| blue_rgba[pixel * 4 ..][0..4].* = .{ 0, 0, 255, 255 };
    const blue_images = [_]struct {
        id: u32,
        generation: u64,
        width: u32,
        height: u32,
        rgba: []const u8,
    }{.{ .id = 7, .generation = 11, .width = 4, .height = 4, .rgba = &blue_rgba }};
    const other_session = .{
        .session_id = @as(u64, 10),
        .images = &blue_images,
        .placements = &placements,
    };
    try renderer.buildFrameWithGraphics(terminal.term, false, other_session);
    var blue_image = try renderer.renderOffscreen(alloc, viewport, width, height);
    defer blue_image.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, blue_image.pixels[red..][0..4]);

    renderer.beginFrame();
    try renderer.appendPaneWithGraphics(terminal.term, false, 0, graphics, null, .{
        .origin = .{ 0, 0 },
        .size = viewport,
    });
    try renderer.appendPaneWithGraphics(terminal.term, false, 0, other_session, null, .{
        .origin = .{ viewport[0], 0 },
        .size = viewport,
    });
    renderer.finishFrame();
    try std.testing.expectEqual(@as(usize, 2), renderer.image_textures.items.len);
    const paired_viewport: [2]f32 = .{ viewport[0] * 2, viewport[1] };
    const paired_width: u32 = @intFromFloat(@ceil(paired_viewport[0]));
    var paired_image = try renderer.renderOffscreen(
        alloc,
        paired_viewport,
        paired_width,
        height,
    );
    defer paired_image.deinit();
    const paired_left = (@as(usize, 2) * paired_width + 2) * 4;
    const paired_right_x: usize = @intFromFloat(@floor(viewport[0] + 2));
    const paired_right = (@as(usize, 2) * paired_width + paired_right_x) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, paired_image.pixels[paired_left..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, paired_image.pixels[paired_right..][0..4]);
}

test "Kitty Unicode placeholder never enters glyph atlases" {
    const alloc = std.testing.allocator;
    var renderer = Renderer.init(alloc, .{ .family = "Menlo", .size = 13 }, 1) catch |err| switch (err) {
        error.NoMetalDevice => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var terminal = try vt.Vt.init(alloc, 2, 1);
    defer terminal.deinit();
    terminal.feed("\x1b[48;2;1;2;3m\u{10EEEE}\u{0305}\u{0305}");

    try renderer.buildFrame(terminal.term, false);
    try std.testing.expectEqual(@as(usize, 0), renderer.glyph_list.items.len);
    try std.testing.expectEqual(@as(usize, 0), renderer.color_glyph_list.items.len);
    try std.testing.expectEqual(@as(usize, 1), renderer.bg_list.items.len);
}

test "offscreen Metal applies Kitty source crop scaling and z strata" {
    const alloc = std.testing.allocator;
    var renderer = Renderer.init(alloc, .{ .family = "Menlo", .size = 13 }, 1) catch |err| switch (err) {
        error.NoMetalDevice => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var terminal = try vt.Vt.init(alloc, 4, 1);
    defer terminal.deinit();
    terminal.feed("\x1b[48;2;0;255;0m    ");

    var red = [_]u8{ 255, 0, 0, 255 };
    var red_blue = [_]u8{ 255, 0, 0, 255, 0, 0, 255, 255 };
    const images = [_]struct {
        id: u32,
        generation: u64,
        width: u32,
        height: u32,
        rgba: []const u8,
    }{
        .{ .id = 1, .generation = 1, .width = 1, .height = 1, .rgba = &red },
        .{ .id = 2, .generation = 1, .width = 2, .height = 1, .rgba = &red_blue },
    };
    const Placement = struct {
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
    const placements = [_]Placement{
        .{
            .image_id = 1,
            .generation = 1,
            .placement_id = 1,
            .row = 0,
            .col = 0,
            .cell_offset_x = 0,
            .cell_offset_y = 0,
            .source_x = 0,
            .source_y = 0,
            .source_width = 1,
            .source_height = 1,
            .dest_width = 5,
            .dest_height = 5,
            .z = image_below_cell_backgrounds - 1,
        },
        .{
            .image_id = 1,
            .generation = 1,
            .placement_id = 2,
            .row = 0,
            .col = 1,
            .cell_offset_x = 0,
            .cell_offset_y = 0,
            .source_x = 0,
            .source_y = 0,
            .source_width = 1,
            .source_height = 1,
            .dest_width = 5,
            .dest_height = 5,
            .z = -1,
        },
        .{
            .image_id = 1,
            .generation = 1,
            .placement_id = 3,
            .row = 0,
            .col = 2,
            .cell_offset_x = 0,
            .cell_offset_y = 0,
            .source_x = 0,
            .source_y = 0,
            .source_width = 1,
            .source_height = 1,
            .dest_width = 5,
            .dest_height = 5,
            .z = 0,
        },
        .{
            .image_id = 2,
            .generation = 1,
            .placement_id = 4,
            .row = 0,
            .col = 3,
            .cell_offset_x = 0,
            .cell_offset_y = 0,
            .source_x = 1,
            .source_y = 0,
            .source_width = 1,
            .source_height = 1,
            .dest_width = 5,
            .dest_height = 5,
            .z = 0,
        },
    };
    try renderer.buildFrameWithGraphics(terminal.term, false, .{
        .session_id = @as(u64, 1),
        .images = &images,
        .placements = &placements,
    });
    const metrics = renderer.cellMetrics();
    const viewport: [2]f32 = .{ metrics.cell_width * 4, metrics.cell_height };
    const width: u32 = @intFromFloat(@ceil(viewport[0]));
    const height: u32 = @intFromFloat(@ceil(viewport[1]));
    var output = try renderer.renderOffscreen(alloc, viewport, width, height);
    defer output.deinit();

    const expected = [_][4]u8{
        .{ 0, 255, 0, 255 }, // very negative: covered by cell background
        .{ 0, 0, 255, 255 }, // negative: above background, below text
        .{ 0, 0, 255, 255 }, // nonnegative: above the complete cell
        .{ 255, 0, 0, 255 }, // cropped source selects the blue texel
    };
    for (expected, 0..) |pixel, col| {
        const x: usize = @intFromFloat(@floor(@as(f32, @floatFromInt(col)) * metrics.cell_width + 2));
        const offset = (@as(usize, 2) * width + x) * 4;
        try std.testing.expectEqualSlices(u8, &pixel, output.pixels[offset..][0..4]);
    }
}
