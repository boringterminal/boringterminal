//! Bounded host-side PNG decode for Kitty graphics `f=100` (RFC 0013).
//! ImageIO handles the full PNG format surface; this module validates the
//! allocation boundary first and publishes the store's straight-alpha RGBA8.

const std = @import("std");
const limits = @import("../graphics_limits.zig");
const vt = @import("../vt.zig");

const CFRef = ?*anyopaque;
const CGFloat = f64;
const CGRect = extern struct {
    origin: extern struct { x: CGFloat = 0, y: CGFloat = 0 } = .{},
    size: extern struct { width: CGFloat = 0, height: CGFloat = 0 } = .{},
};

const png_signature = "\x89PNG\r\n\x1a\n";
const bitmap_byte_order_32_big: u32 = 4 << 12;
const alpha_premultiplied_last: u32 = 1;

extern "c" fn CFDataCreate(allocator: CFRef, bytes: [*]const u8, length: isize) CFRef;
extern "c" fn CFRelease(value: CFRef) void;
extern "c" fn CGImageSourceCreateWithData(data: CFRef, options: CFRef) CFRef;
extern "c" fn CGImageSourceCreateImageAtIndex(source: CFRef, index: usize, options: CFRef) CFRef;
extern "c" fn CGImageGetWidth(image: CFRef) usize;
extern "c" fn CGImageGetHeight(image: CFRef) usize;
extern "c" fn CGImageRelease(image: CFRef) void;
extern "c" fn CGColorSpaceCreateWithName(name: CFRef) CFRef;
extern "c" fn CGColorSpaceRelease(color_space: CFRef) void;
extern "c" fn CGBitmapContextCreate(
    data: ?*anyopaque,
    width: usize,
    height: usize,
    bits_per_component: usize,
    bytes_per_row: usize,
    color_space: CFRef,
    bitmap_info: u32,
) CFRef;
extern "c" fn CGContextRelease(context: CFRef) void;
extern "c" fn CGContextDrawImage(context: CFRef, rect: CGRect, image: CFRef) void;
extern const kCGColorSpaceSRGB: CFRef;

pub const Image = struct {
    width: u32,
    height: u32,
    rgba: []u8,
};

pub fn decode(alloc: std.mem.Allocator, data: []const u8) !Image {
    const dimensions = try dimensionsFromHeader(data);
    const pixel_count = std.math.mul(usize, dimensions.width, dimensions.height) catch
        return error.ImageTooLarge;
    const byte_count = std.math.mul(usize, pixel_count, 4) catch
        return error.ImageTooLarge;
    if (byte_count > limits.max_image_bytes) return error.ImageTooLarge;

    const cf_data = CFDataCreate(null, data.ptr, @intCast(data.len));
    if (cf_data == null) return error.OutOfMemory;
    defer CFRelease(cf_data);
    const source = CGImageSourceCreateWithData(cf_data, null);
    if (source == null) return error.InvalidPng;
    defer CFRelease(source);
    const image = CGImageSourceCreateImageAtIndex(source, 0, null);
    if (image == null) return error.InvalidPng;
    defer CGImageRelease(image);
    if (CGImageGetWidth(image) != dimensions.width or
        CGImageGetHeight(image) != dimensions.height)
        return error.InvalidPng;

    const rgba = try alloc.alloc(u8, byte_count);
    errdefer alloc.free(rgba);
    @memset(rgba, 0);
    const color_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (color_space == null) return error.ImageDecode;
    defer CGColorSpaceRelease(color_space);
    const context = CGBitmapContextCreate(
        rgba.ptr,
        dimensions.width,
        dimensions.height,
        8,
        @as(usize, dimensions.width) * 4,
        color_space,
        bitmap_byte_order_32_big | alpha_premultiplied_last,
    );
    if (context == null) return error.ImageDecode;
    defer CGContextRelease(context);

    // ImageIO's CGImage drawn into this bitmap layout publishes the PNG's top
    // scanline first. Keep the default CTM; flipping it reverses row order.
    CGContextDrawImage(context, .{
        .size = .{
            .width = @floatFromInt(dimensions.width),
            .height = @floatFromInt(dimensions.height),
        },
    }, image);
    unpremultiply(rgba);
    return .{ .width = dimensions.width, .height = dimensions.height, .rgba = rgba };
}

const Dimensions = struct { width: u32, height: u32 };

fn dimensionsFromHeader(data: []const u8) !Dimensions {
    // Signature + IHDR length/type + the first eight IHDR data bytes.
    if (data.len < 24 or !std.mem.eql(u8, data[0..8], png_signature) or
        std.mem.readInt(u32, data[8..12], .big) != 13 or
        !std.mem.eql(u8, data[12..16], "IHDR"))
        return error.InvalidPng;
    const width = std.mem.readInt(u32, data[16..20], .big);
    const height = std.mem.readInt(u32, data[20..24], .big);
    if (width == 0 or height == 0 or
        width > vt.graphics.max_dimension or height > vt.graphics.max_dimension)
        return error.ImageTooLarge;
    return .{ .width = width, .height = height };
}

fn unpremultiply(rgba: []u8) void {
    var pixel: usize = 0;
    while (pixel < rgba.len) : (pixel += 4) {
        const alpha: u16 = rgba[pixel + 3];
        if (alpha == 0) {
            @memset(rgba[pixel..][0..3], 0);
            continue;
        }
        if (alpha == 255) continue;
        for (rgba[pixel..][0..3]) |*channel| {
            const straight = (@as(u16, channel.*) * 255 + alpha / 2) / alpha;
            channel.* = @intCast(@min(straight, 255));
        }
    }
}

test "ImageIO decodes PNG top-down into straight-alpha RGBA" {
    const encoded =
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFUlEQVR4nGP4z8Dwn+EEQwMDkAYDAEI+CUGYxtFzAAAAAElFTkSuQmCC";
    const size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const bytes = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(bytes);
    try std.base64.standard.Decoder.decode(bytes, encoded);
    var image = try decode(std.testing.allocator, bytes);
    defer std.testing.allocator.free(image.rgba);
    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expectEqual(@as(u32, 2), image.height);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.rgba[0..4]);
    try std.testing.expectEqual(@as(u8, 128), image.rgba[7]);
    try std.testing.expectApproxEqAbs(@as(f64, 200), @as(f64, image.rgba[5]), 1);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, image.rgba[8..12]);
}

test "PNG header rejects oversized decode before ImageIO" {
    var header: [24]u8 = @splat(0);
    @memcpy(header[0..8], png_signature);
    std.mem.writeInt(u32, header[8..12], 13, .big);
    @memcpy(header[12..16], "IHDR");
    std.mem.writeInt(u32, header[16..20], vt.graphics.max_dimension, .big);
    std.mem.writeInt(u32, header[20..24], vt.graphics.max_dimension, .big);
    try std.testing.expectError(error.ImageTooLarge, decode(std.testing.allocator, &header));
}
