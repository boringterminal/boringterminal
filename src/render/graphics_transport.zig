//! Experimental, source-independent Metal transport probes for RFC 0022.
//!
//! Nothing in the application calls this module. It exists so transport
//! policy is selected from reproducible measurements and exact pixel checks,
//! rather than by changing the production renderer until a path looks fast.

const std = @import("std");
const objc = @import("objc.zig");
const metal = @import("metal.zig");
const shaders = @import("shaders.zig");
const libc = std.c;

const ImageInstance = extern struct {
    origin: [2]f32,
    size: [2]f32,
    uv: [4]f32,
};

pub const Path = enum {
    synchronous_blit,
    fused_blit_and_sample,
    direct_linear_sample,

    pub fn label(self: Path) []const u8 {
        return switch (self) {
            .synchronous_blit => "synchronous-blit",
            .fused_blit_and_sample => "fused-blit-and-sample",
            .direct_linear_sample => "direct-linear-sample",
        };
    }
};

pub const Lifecycle = enum {
    reuse,
    recreate,

    pub fn label(self: Lifecycle) []const u8 {
        return @tagName(self);
    }
};

pub const Stats = struct {
    path: Path,
    lifecycle: Lifecycle,
    width: u32,
    height: u32,
    frames: usize,
    p50_ns: u64,
    p95_ns: u64,
    max_ns: u64,
};

pub const Harness = struct {
    width: u32,
    height: u32,
    bytes_per_row: usize,
    mapping: *anyopaque,
    mapping_length: usize,
    source_bytes: [*]u8,
    device: objc.Id,
    queue: objc.Id,
    pipeline: metal.Pipeline,
    buffer: objc.Id,
    synchronous_texture: objc.Id,
    fused_texture: objc.Id,
    linear_texture: objc.Id,
    target_texture: objc.Id,

    pub fn init(width: u32, height: u32) !Harness {
        if (width == 0 or height == 0) return error.InvalidImageSize;
        const device = metal.createDevice();
        if (device == null) return error.NoMetalDevice;
        errdefer objc.release(device);
        const queue = metal.newCommandQueue(device);
        if (queue == null) return error.NoCommandQueue;
        errdefer objc.release(queue);
        const pipeline = try metal.buildPipeline(
            device,
            shaders.image,
            "image_vertex",
            "image_fragment",
        );
        errdefer {
            objc.release(pipeline.state);
            objc.release(pipeline.library);
        }

        const row_alignment = metal.minimumLinearTextureAlignment(
            device,
            metal.PixelFormat.rgba8_unorm,
        );
        if (row_alignment == 0 or !std.math.isPowerOfTwo(row_alignment))
            return error.InvalidMetalAlignment;
        const active_row = try std.math.mul(usize, width, 4);
        const bytes_per_row = std.mem.alignForward(usize, active_row, row_alignment);
        const image_length = try std.math.mul(usize, bytes_per_row, height);
        const page_size_signed = libc.sysconf(@intFromEnum(libc._SC.PAGESIZE));
        if (page_size_signed <= 0) return error.PageSizeUnavailable;
        const page_size: usize = @intCast(page_size_signed);
        const mapping_length = std.mem.alignForward(usize, image_length, page_size);
        const mapping = libc.mmap(
            null,
            mapping_length,
            libc.PROT{ .READ = true, .WRITE = true },
            libc.MAP{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        if (mapping == libc.MAP_FAILED) return error.MappingFailed;
        errdefer _ = libc.munmap(@ptrCast(@alignCast(mapping)), mapping_length);
        const source_bytes: [*]u8 = @ptrCast(mapping);
        fillPattern(source_bytes, width, height, bytes_per_row, 0);

        const buffer = metal.newBufferWithBytesNoCopy(device, mapping, mapping_length);
        if (buffer == null) return error.MetalBufferCreate;
        errdefer objc.release(buffer);
        const synchronous_texture = try metal.newTexture2DWithStorageMode(
            device,
            metal.PixelFormat.rgba8_unorm,
            width,
            height,
            metal.StorageMode.shared,
        );
        errdefer objc.release(synchronous_texture);
        const fused_texture = try metal.newTexture2DWithStorageMode(
            device,
            metal.PixelFormat.rgba8_unorm,
            width,
            height,
            metal.StorageMode.private,
        );
        errdefer objc.release(fused_texture);
        const linear_texture = metal.newLinearTexture2D(
            buffer,
            metal.PixelFormat.rgba8_unorm,
            width,
            height,
            bytes_per_row,
        ) catch |err| switch (err) {
            error.TextureCreate => null,
            else => return err,
        };
        errdefer if (linear_texture != null) objc.release(linear_texture);
        const target_texture = try metal.newTexture2D(
            device,
            metal.PixelFormat.bgra8_unorm,
            width,
            height,
        );
        errdefer objc.release(target_texture);

        return .{
            .width = width,
            .height = height,
            .bytes_per_row = bytes_per_row,
            .mapping = mapping,
            .mapping_length = mapping_length,
            .source_bytes = source_bytes,
            .device = device,
            .queue = queue,
            .pipeline = pipeline,
            .buffer = buffer,
            .synchronous_texture = synchronous_texture,
            .fused_texture = fused_texture,
            .linear_texture = linear_texture,
            .target_texture = target_texture,
        };
    }

    pub fn deinit(self: *Harness) void {
        objc.release(self.target_texture);
        if (self.linear_texture != null) objc.release(self.linear_texture);
        objc.release(self.fused_texture);
        objc.release(self.synchronous_texture);
        // The texture view must die before the buffer, and the buffer before
        // its no-copy backing mapping.
        objc.release(self.buffer);
        objc.release(self.pipeline.state);
        objc.release(self.pipeline.library);
        objc.release(self.queue);
        objc.release(self.device);
        _ = libc.munmap(@ptrCast(@alignCast(self.mapping)), self.mapping_length);
        self.* = undefined;
    }

    pub fn exercise(
        self: *Harness,
        path: Path,
        lifecycle: Lifecycle,
        generation: u8,
    ) !void {
        fillPattern(self.source_bytes, self.width, self.height, self.bytes_per_row, generation);
        const buffer = if (lifecycle == .reuse) self.buffer else blk: {
            const candidate = metal.newBufferWithBytesNoCopy(
                self.device,
                self.mapping,
                self.mapping_length,
            );
            if (candidate == null) return error.MetalBufferCreate;
            break :blk candidate;
        };
        defer if (lifecycle == .recreate) objc.release(buffer);
        switch (path) {
            .synchronous_blit => {
                const texture = if (lifecycle == .reuse)
                    self.synchronous_texture
                else
                    try metal.newTexture2DWithStorageMode(
                        self.device,
                        metal.PixelFormat.rgba8_unorm,
                        self.width,
                        self.height,
                        metal.StorageMode.shared,
                    );
                defer if (lifecycle == .recreate) objc.release(texture);
                try metal.copyBufferToTexture(
                    self.queue,
                    buffer,
                    self.bytes_per_row,
                    self.width,
                    self.height,
                    texture,
                );
                try self.renderTexture(null, texture);
            },
            .fused_blit_and_sample => {
                const texture = if (lifecycle == .reuse)
                    self.fused_texture
                else
                    try metal.newTexture2DWithStorageMode(
                        self.device,
                        metal.PixelFormat.rgba8_unorm,
                        self.width,
                        self.height,
                        metal.StorageMode.private,
                    );
                defer if (lifecycle == .recreate) objc.release(texture);
                const command_buffer = metal.newCommandBuffer(self.queue);
                if (command_buffer == null) return error.MetalCommandBuffer;
                try metal.encodeBufferToTexture(
                    command_buffer,
                    buffer,
                    self.bytes_per_row,
                    self.width,
                    self.height,
                    texture,
                );
                try self.renderTexture(command_buffer, texture);
            },
            .direct_linear_sample => {
                const texture = if (lifecycle == .reuse)
                    self.linear_texture orelse return error.UnsupportedTransportPath
                else
                    metal.newLinearTexture2D(
                        buffer,
                        metal.PixelFormat.rgba8_unorm,
                        self.width,
                        self.height,
                        self.bytes_per_row,
                    ) catch |err| switch (err) {
                        error.TextureCreate => return error.UnsupportedTransportPath,
                        else => return err,
                    };
                defer if (lifecycle == .recreate) objc.release(texture);
                try self.renderTexture(null, texture);
            },
        }
    }

    pub fn verify(self: *Harness, alloc: std.mem.Allocator, generation: u8) !void {
        const row_bytes = try std.math.mul(usize, self.width, 4);
        const length = try std.math.mul(usize, row_bytes, self.height);
        const actual = try alloc.alloc(u8, length);
        defer alloc.free(actual);
        metal.getBytes(self.target_texture, actual.ptr, row_bytes, .{
            .size = .{ .width = self.width, .height = self.height, .depth = 1 },
        });
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            var x: usize = 0;
            while (x < self.width) : (x += 1) {
                const offset = (y * @as(usize, self.width) + x) * 4;
                const rgba = patternPixel(x, y, generation);
                const expected = [_]u8{ rgba[2], rgba[1], rgba[0], rgba[3] };
                if (!std.mem.eql(u8, &expected, actual[offset..][0..4]))
                    return error.PixelMismatch;
            }
        }
    }

    fn renderTexture(self: *Harness, command_buffer: objc.Id, source: objc.Id) !void {
        const clear: metal.ClearColor = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 };
        const frame = if (command_buffer != null)
            metal.beginFrameOnCommandBuffer(command_buffer, self.target_texture, clear)
        else
            metal.beginFrame(self.queue, self.target_texture, clear);
        const ready = frame orelse return error.OffscreenCommandEncoding;
        const viewport = [2]f32{
            @floatFromInt(self.width),
            @floatFromInt(self.height),
        };
        const instance: ImageInstance = .{
            .origin = .{ 0, 0 },
            .size = viewport,
            .uv = .{ 0, 0, 1, 1 },
        };
        metal.setPipeline(ready.encoder, self.pipeline.state);
        metal.setVertexBytes(ready.encoder, &instance, @sizeOf(ImageInstance), 0);
        metal.setVertexBytes(ready.encoder, &viewport, @sizeOf([2]f32), 1);
        metal.setFragmentTexture(ready.encoder, source, 0);
        metal.drawQuads(ready.encoder, 1);
        try metal.endOffscreen(ready);
    }
};

pub fn benchmark(
    io: std.Io,
    alloc: std.mem.Allocator,
    width: u32,
    height: u32,
    warmup: usize,
    frames: usize,
    path: Path,
    lifecycle: Lifecycle,
) !Stats {
    if (frames == 0) return error.NoBenchmarkFrames;
    var harness = try Harness.init(width, height);
    defer harness.deinit();
    var i: usize = 0;
    while (i < warmup) : (i += 1)
        try harness.exercise(path, lifecycle, @truncate(i));
    const samples = try alloc.alloc(u64, frames);
    defer alloc.free(samples);
    for (samples, 0..) |*sample, frame_index| {
        const before = std.Io.Clock.awake.now(io);
        try harness.exercise(path, lifecycle, @truncate(frame_index));
        const elapsed = before.durationTo(std.Io.Clock.awake.now(io));
        sample.* = @intCast(elapsed.nanoseconds);
    }
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return .{
        .path = path,
        .lifecycle = lifecycle,
        .width = width,
        .height = height,
        .frames = frames,
        .p50_ns = samples[(frames - 1) * 50 / 100],
        .p95_ns = samples[(frames - 1) * 95 / 100],
        .max_ns = samples[frames - 1],
    };
}

fn fillPattern(
    bytes: [*]u8,
    width: u32,
    height: u32,
    bytes_per_row: usize,
    generation: u8,
) void {
    var y: usize = 0;
    while (y < height) : (y += 1) {
        @memset(bytes[y * bytes_per_row ..][0..bytes_per_row], 0xa5);
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const pixel = patternPixel(x, y, generation);
            @memcpy(bytes[y * bytes_per_row + x * 4 ..][0..4], &pixel);
        }
    }
}

fn patternPixel(x: usize, y: usize, generation: u8) [4]u8 {
    return .{
        @truncate(x *% 17 +% y *% 3 +% generation),
        @truncate(x *% 5 +% y *% 19 +% generation *% 3),
        @truncate(x *% 11 +% y *% 7 +% generation *% 5),
        255,
    };
}

test "all graphics transport candidates preserve padded RGBA rows" {
    const alloc = std.testing.allocator;
    for (std.meta.tags(Path), 0..) |path, generation| {
        var harness = Harness.init(37, 19) catch |err| switch (err) {
            error.NoMetalDevice => return error.SkipZigTest,
            else => return err,
        };
        defer harness.deinit();
        try std.testing.expect(harness.bytes_per_row > 37 * 4);
        for (std.meta.tags(Lifecycle)) |lifecycle| {
            const value: u8 = @truncate(generation + @intFromEnum(lifecycle) + 1);
            harness.exercise(path, lifecycle, value) catch |err| switch (err) {
                error.UnsupportedTransportPath => continue,
                else => return err,
            };
            try harness.verify(alloc, value);
        }
    }
}

test "linear texture candidate rejects invalid stride before Metal" {
    var harness = Harness.init(37, 19) catch |err| switch (err) {
        error.NoMetalDevice => return error.SkipZigTest,
        else => return err,
    };
    defer harness.deinit();
    try std.testing.expectError(
        error.InvalidLinearTextureLayout,
        metal.newLinearTexture2D(
            harness.buffer,
            metal.PixelFormat.rgba8_unorm,
            harness.width,
            harness.height,
            @as(usize, harness.width) * 4,
        ),
    );
}
