//! Metal externs, enums, and pipeline helpers trimmed to what a cell-grid
//! renderer needs, plus the CAMetalLayer presentation path.

const std = @import("std");
const objc = @import("objc.zig");

pub const PixelFormat = struct {
    pub const r8_unorm: objc.NSUInteger = 10;
    pub const rgba8_unorm: objc.NSUInteger = 70;
    pub const bgra8_unorm: objc.NSUInteger = 80;
};

pub const Origin = extern struct { x: usize = 0, y: usize = 0, z: usize = 0 };
pub const Size3D = extern struct { width: usize = 1, height: usize = 1, depth: usize = 1 };
pub const Region = extern struct { origin: Origin = .{}, size: Size3D = .{} };

pub const LoadAction = struct {
    pub const clear: objc.NSUInteger = 2;
};
pub const StoreAction = struct {
    pub const store: objc.NSUInteger = 1;
};
pub const PrimitiveType = struct {
    pub const triangle_strip: objc.NSUInteger = 4;
};
pub const CommandBufferStatus = struct {
    pub const completed: objc.NSUInteger = 4;
    pub const @"error": objc.NSUInteger = 5;
};
pub const StorageMode = struct {
    pub const shared: objc.NSUInteger = 0;
    pub const private: objc.NSUInteger = 2;
};
pub const TextureUsage = struct {
    pub const shader_read: objc.NSUInteger = 1;
};

pub const BlendOp = struct {
    pub const add: objc.NSUInteger = 0;
};
pub const BlendFactor = struct {
    pub const one: objc.NSUInteger = 1;
    pub const source_alpha: objc.NSUInteger = 4;
    pub const one_minus_source_alpha: objc.NSUInteger = 5;
};

pub const ClearColor = extern struct { red: f64, green: f64, blue: f64, alpha: f64 };
pub const ScissorRect = extern struct { x: usize, y: usize, width: usize, height: usize };
pub const TextureSize = struct { width: usize, height: usize };

extern "c" fn MTLCreateSystemDefaultDevice() objc.Id;

pub fn createDevice() objc.Id {
    return MTLCreateSystemDefaultDevice();
}

pub fn newCommandQueue(device: objc.Id) objc.Id {
    return objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        device,
        objc.sel("newCommandQueue"),
    );
}

pub fn newLibraryWithSource(device: objc.Id, source: [*:0]const u8) ?objc.Id {
    var err: objc.Id = null;
    const ns_source = objc.nsString(source);
    const lib = objc.msg(*const fn (
        objc.Id,
        objc.Sel,
        objc.Id,
        objc.Id,
        *objc.Id,
    ) callconv(.c) objc.Id)(
        device,
        objc.sel("newLibraryWithSource:options:error:"),
        ns_source,
        null,
        &err,
    );
    if (lib == null) {
        logNSError("MTLLibrary compile failed", err);
        return null;
    }
    return lib;
}

pub fn newFunctionWithName(library: objc.Id, name: [*:0]const u8) objc.Id {
    return objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        library,
        objc.sel("newFunctionWithName:"),
        objc.nsString(name),
    );
}

pub const Pipeline = struct {
    library: objc.Id,
    state: objc.Id,
};

/// Compile MSL source and build a source-over-blended pipeline targeting
/// bgra8. All our pipelines are the same shape.
pub fn buildPipeline(
    device: objc.Id,
    source: [*:0]const u8,
    vertex_fn_name: [*:0]const u8,
    fragment_fn_name: [*:0]const u8,
) !Pipeline {
    return buildPipelineWithBlend(device, source, vertex_fn_name, fragment_fn_name, .straight);
}

pub fn buildPremultipliedPipeline(
    device: objc.Id,
    source: [*:0]const u8,
    vertex_fn_name: [*:0]const u8,
    fragment_fn_name: [*:0]const u8,
) !Pipeline {
    return buildPipelineWithBlend(device, source, vertex_fn_name, fragment_fn_name, .premultiplied);
}

const SourceBlend = enum { straight, premultiplied };

fn buildPipelineWithBlend(
    device: objc.Id,
    source: [*:0]const u8,
    vertex_fn_name: [*:0]const u8,
    fragment_fn_name: [*:0]const u8,
    source_blend: SourceBlend,
) !Pipeline {
    const library = newLibraryWithSource(device, source) orelse
        return error.MetalShaderCompile;
    errdefer objc.release(library);

    const vfn = newFunctionWithName(library, vertex_fn_name);
    defer objc.release(vfn);
    const ffn = newFunctionWithName(library, fragment_fn_name);
    defer objc.release(ffn);
    if (vfn == null or ffn == null) return error.MetalShaderMissing;

    const desc = objc.allocInit(objc.cls("MTLRenderPipelineDescriptor"));
    defer objc.release(desc);
    objc.setId(desc, objc.sel("setVertexFunction:"), vfn);
    objc.setId(desc, objc.sel("setFragmentFunction:"), ffn);

    const attachments = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        desc,
        objc.sel("colorAttachments"),
    );
    const attachment = objc.msg(
        *const fn (objc.Id, objc.Sel, objc.NSUInteger) callconv(.c) objc.Id,
    )(attachments, objc.sel("objectAtIndexedSubscript:"), 0);
    objc.setU(attachment, objc.sel("setPixelFormat:"), PixelFormat.bgra8_unorm);
    objc.setU(attachment, objc.sel("setBlendingEnabled:"), 1);
    objc.setU(attachment, objc.sel("setRgbBlendOperation:"), BlendOp.add);
    objc.setU(attachment, objc.sel("setAlphaBlendOperation:"), BlendOp.add);
    objc.setU(
        attachment,
        objc.sel("setSourceRGBBlendFactor:"),
        if (source_blend == .premultiplied) BlendFactor.one else BlendFactor.source_alpha,
    );
    objc.setU(attachment, objc.sel("setDestinationRGBBlendFactor:"), BlendFactor.one_minus_source_alpha);
    objc.setU(attachment, objc.sel("setSourceAlphaBlendFactor:"), BlendFactor.one);
    objc.setU(attachment, objc.sel("setDestinationAlphaBlendFactor:"), BlendFactor.one_minus_source_alpha);

    var err: objc.Id = null;
    const state = objc.msg(*const fn (
        objc.Id,
        objc.Sel,
        objc.Id,
        *objc.Id,
    ) callconv(.c) objc.Id)(
        device,
        objc.sel("newRenderPipelineStateWithDescriptor:error:"),
        desc,
        &err,
    );
    if (state == null) {
        logNSError("MTLRenderPipelineState creation failed", err);
        return error.MetalPipelineCreate;
    }
    return .{ .library = library, .state = state };
}

pub fn newTexture2D(
    device: objc.Id,
    pixel_format: objc.NSUInteger,
    width: u32,
    height: u32,
) !objc.Id {
    return newTexture2DWithStorageMode(device, pixel_format, width, height, StorageMode.shared);
}

pub fn newTexture2DWithStorageMode(
    device: objc.Id,
    pixel_format: objc.NSUInteger,
    width: u32,
    height: u32,
    storage_mode: objc.NSUInteger,
) !objc.Id {
    const desc = objc.msg(
        *const fn (objc.Class, objc.Sel, objc.NSUInteger, usize, usize, objc.BOOL) callconv(.c) objc.Id,
    )(
        objc.cls("MTLTextureDescriptor"),
        objc.sel("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"),
        pixel_format,
        width,
        height,
        0,
    );
    if (desc == null) return error.TextureDescriptor;
    objc.setU(desc, objc.sel("setStorageMode:"), storage_mode);

    const texture = objc.msg(
        *const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id,
    )(device, objc.sel("newTextureWithDescriptor:"), desc);
    if (texture == null) return error.TextureCreate;
    return texture;
}

/// Create a shader-readable linear texture view over an existing Metal
/// buffer. This is an experimental transport primitive (RFC 0022), not the
/// production image-cache policy. The caller must keep the buffer and its
/// backing allocation alive until every command buffer sampling the texture
/// has completed.
pub fn newLinearTexture2D(
    buffer: objc.Id,
    pixel_format: objc.NSUInteger,
    width: u32,
    height: u32,
    bytes_per_row: usize,
) !objc.Id {
    const active_row = try std.math.mul(usize, width, 4);
    const device = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        buffer,
        objc.sel("device"),
    );
    const alignment = minimumLinearTextureAlignment(device, pixel_format);
    const buffer_length = objc.msg(
        *const fn (objc.Id, objc.Sel) callconv(.c) objc.NSUInteger,
    )(buffer, objc.sel("length"));
    if (alignment == 0 or
        bytes_per_row < active_row or
        bytes_per_row % alignment != 0 or
        try std.math.mul(usize, bytes_per_row, height) > buffer_length)
        return error.InvalidLinearTextureLayout;
    const desc = objc.msg(
        *const fn (objc.Class, objc.Sel, objc.NSUInteger, usize, usize, objc.BOOL) callconv(.c) objc.Id,
    )(
        objc.cls("MTLTextureDescriptor"),
        objc.sel("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"),
        pixel_format,
        width,
        height,
        0,
    );
    if (desc == null) return error.TextureDescriptor;
    const storage_mode = objc.msg(
        *const fn (objc.Id, objc.Sel) callconv(.c) objc.NSUInteger,
    )(buffer, objc.sel("storageMode"));
    objc.setU(desc, objc.sel("setStorageMode:"), storage_mode);
    objc.setU(desc, objc.sel("setUsage:"), TextureUsage.shader_read);
    const texture = objc.msg(
        *const fn (objc.Id, objc.Sel, objc.Id, objc.NSUInteger, objc.NSUInteger) callconv(.c) objc.Id,
    )(
        buffer,
        objc.sel("newTextureWithDescriptor:offset:bytesPerRow:"),
        desc,
        0,
        bytes_per_row,
    );
    if (texture == null) return error.TextureCreate;
    return texture;
}

pub fn replaceRegion(
    texture: objc.Id,
    region: Region,
    bytes: *const anyopaque,
    bytes_per_row: usize,
) void {
    objc.msg(
        *const fn (
            objc.Id,
            objc.Sel,
            Region,
            objc.NSUInteger,
            *const anyopaque,
            objc.NSUInteger,
        ) callconv(.c) void,
    )(
        texture,
        objc.sel("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"),
        region,
        0,
        bytes,
        bytes_per_row,
    );
}

pub fn getBytes(
    texture: objc.Id,
    out: *anyopaque,
    bytes_per_row: usize,
    region: Region,
) void {
    objc.msg(
        *const fn (objc.Id, objc.Sel, *anyopaque, objc.NSUInteger, Region, objc.NSUInteger) callconv(.c) void,
    )(
        texture,
        objc.sel("getBytes:bytesPerRow:fromRegion:mipmapLevel:"),
        out,
        bytes_per_row,
        region,
        0,
    );
}

pub fn textureSize(texture: objc.Id) TextureSize {
    return .{
        .width = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSUInteger)(
            texture,
            objc.sel("width"),
        ),
        .height = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSUInteger)(
            texture,
            objc.sel("height"),
        ),
    };
}

pub fn newBufferWithLength(device: objc.Id, length: usize) objc.Id {
    return objc.msg(*const fn (objc.Id, objc.Sel, usize, objc.NSUInteger) callconv(.c) objc.Id)(
        device,
        objc.sel("newBufferWithLength:options:"),
        length,
        0, // MTLResourceStorageModeShared
    );
}

pub fn minimumLinearTextureAlignment(device: objc.Id, pixel_format: objc.NSUInteger) usize {
    return objc.msg(*const fn (objc.Id, objc.Sel, objc.NSUInteger) callconv(.c) objc.NSUInteger)(
        device,
        objc.sel("minimumLinearTextureAlignmentForPixelFormat:"),
        pixel_format,
    );
}

pub fn newBufferWithBytesNoCopy(device: objc.Id, bytes: *anyopaque, length: usize) objc.Id {
    return objc.msg(*const fn (
        objc.Id,
        objc.Sel,
        *anyopaque,
        objc.NSUInteger,
        objc.NSUInteger,
        objc.Id,
    ) callconv(.c) objc.Id)(
        device,
        objc.sel("newBufferWithBytesNoCopy:length:options:deallocator:"),
        bytes,
        length,
        0, // MTLResourceStorageModeShared
        null,
    );
}

pub fn copyBufferToTexture(
    queue: objc.Id,
    buffer: objc.Id,
    bytes_per_row: usize,
    width: usize,
    height: usize,
    texture: objc.Id,
) !void {
    const command_buffer = newCommandBuffer(queue);
    if (command_buffer == null) return error.MetalCommandBuffer;
    try encodeBufferToTexture(command_buffer, buffer, bytes_per_row, width, height, texture);
    try commitAndWait(command_buffer);
}

pub fn newCommandBuffer(queue: objc.Id) objc.Id {
    return objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        queue,
        objc.sel("commandBuffer"),
    );
}

pub fn encodeBufferToTexture(
    command_buffer: objc.Id,
    buffer: objc.Id,
    bytes_per_row: usize,
    width: usize,
    height: usize,
    texture: objc.Id,
) !void {
    const encoder = try beginBlit(command_buffer);
    encodeBufferToTextureOnEncoder(
        encoder,
        buffer,
        bytes_per_row,
        width,
        height,
        texture,
    );
    endEncoding(encoder);
}

pub fn beginBlit(command_buffer: objc.Id) !objc.Id {
    const encoder = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        command_buffer,
        objc.sel("blitCommandEncoder"),
    );
    if (encoder == null) return error.MetalBlitEncoder;
    return encoder;
}

pub fn encodeBufferToTextureOnEncoder(
    encoder: objc.Id,
    buffer: objc.Id,
    bytes_per_row: usize,
    width: usize,
    height: usize,
    texture: objc.Id,
) void {
    objc.msg(*const fn (
        objc.Id,
        objc.Sel,
        objc.Id,
        objc.NSUInteger,
        objc.NSUInteger,
        objc.NSUInteger,
        Size3D,
        objc.Id,
        objc.NSUInteger,
        objc.NSUInteger,
        Origin,
    ) callconv(.c) void)(
        encoder,
        objc.sel("copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:"),
        buffer,
        0,
        bytes_per_row,
        bytes_per_row * height,
        .{ .width = width, .height = height, .depth = 1 },
        texture,
        0,
        0,
        .{},
    );
}

pub fn endEncoding(encoder: objc.Id) void {
    objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(encoder, objc.sel("endEncoding"));
}

pub fn commitAndWait(command_buffer: objc.Id) !void {
    objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(command_buffer, objc.sel("commit"));
    waitUntilCompleted(command_buffer);
    if (commandBufferStatus(command_buffer) != CommandBufferStatus.completed)
        return error.MetalCommandBuffer;
}

pub fn bufferContents(buffer: objc.Id) [*]u8 {
    return @ptrCast(objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) ?*anyopaque)(
        buffer,
        objc.sel("contents"),
    ).?);
}

// -- frame encoding ---------------------------------------------------------

pub const Frame = struct {
    command_buffer: objc.Id,
    encoder: objc.Id,
};

pub const CompletionCallback = *const fn (?*anyopaque, objc.Id) callconv(.c) void;

// Minimal Objective-C Blocks ABI context for MTLCommandBuffer completion.
// The layout follows Clang's published Block ABI and the same MIT-licensed
// zig-objc/Ghostty pattern cited by RFC 0004. Captures are plain pointers, so
// no copy/dispose helpers are required when Metal copies this stack block.
const CompletionBlockDescriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
    signature: [*:0]const u8,
};

const CompletionBlock = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const fn (*const CompletionBlock, objc.Id) callconv(.c) void,
    descriptor: *const CompletionBlockDescriptor,
    context: ?*anyopaque,
    callback: CompletionCallback,
};

const ns_concrete_stack_block = @extern(*opaque {}, .{ .name = "_NSConcreteStackBlock" });
const block_has_signature: c_int = 1 << 30;
const completion_block_descriptor: CompletionBlockDescriptor = .{
    .size = @sizeOf(CompletionBlock),
    .signature = "v@?@",
};

fn invokeCompletionBlock(block: *const CompletionBlock, command_buffer: objc.Id) callconv(.c) void {
    block.callback(block.context, command_buffer);
}

pub fn addCompletedHandler(
    command_buffer: objc.Id,
    context: ?*anyopaque,
    callback: CompletionCallback,
) void {
    var block: CompletionBlock = .{
        .isa = @ptrCast(ns_concrete_stack_block),
        .flags = block_has_signature,
        .invoke = invokeCompletionBlock,
        .descriptor = &completion_block_descriptor,
        .context = context,
        .callback = callback,
    };
    objc.msg(*const fn (objc.Id, objc.Sel, *const CompletionBlock) callconv(.c) void)(
        command_buffer,
        objc.sel("addCompletedHandler:"),
        &block,
    );
}

pub fn beginFrame(queue: objc.Id, target_texture: objc.Id, clear: ClearColor) ?Frame {
    const cmd = newCommandBuffer(queue);
    if (cmd == null) return null;
    return beginFrameOnCommandBuffer(cmd, target_texture, clear);
}

pub fn beginFrameOnCommandBuffer(
    cmd: objc.Id,
    target_texture: objc.Id,
    clear: ClearColor,
) ?Frame {
    const pass = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("MTLRenderPassDescriptor"),
        objc.sel("renderPassDescriptor"),
    );
    const attachments = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        pass,
        objc.sel("colorAttachments"),
    );
    const attachment = objc.msg(
        *const fn (objc.Id, objc.Sel, objc.NSUInteger) callconv(.c) objc.Id,
    )(attachments, objc.sel("objectAtIndexedSubscript:"), 0);
    objc.setId(attachment, objc.sel("setTexture:"), target_texture);
    objc.setU(attachment, objc.sel("setLoadAction:"), LoadAction.clear);
    objc.setU(attachment, objc.sel("setStoreAction:"), StoreAction.store);
    objc.msg(*const fn (objc.Id, objc.Sel, ClearColor) callconv(.c) void)(
        attachment,
        objc.sel("setClearColor:"),
        clear,
    );

    const encoder = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        cmd,
        objc.sel("renderCommandEncoderWithDescriptor:"),
        pass,
    );
    if (encoder == null) return null;
    return .{ .command_buffer = cmd, .encoder = encoder };
}

pub fn setPipeline(encoder: objc.Id, state: objc.Id) void {
    objc.setId(encoder, objc.sel("setRenderPipelineState:"), state);
}

pub fn setVertexBuffer(encoder: objc.Id, buffer: objc.Id, offset: usize, index: usize) void {
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id, objc.NSUInteger, objc.NSUInteger) callconv(.c) void)(
        encoder,
        objc.sel("setVertexBuffer:offset:atIndex:"),
        buffer,
        offset,
        index,
    );
}

pub fn setVertexBytes(encoder: objc.Id, bytes: *const anyopaque, length: usize, index: usize) void {
    objc.msg(*const fn (objc.Id, objc.Sel, *const anyopaque, objc.NSUInteger, objc.NSUInteger) callconv(.c) void)(
        encoder,
        objc.sel("setVertexBytes:length:atIndex:"),
        bytes,
        length,
        index,
    );
}

pub fn setFragmentTexture(encoder: objc.Id, texture: objc.Id, index: usize) void {
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id, objc.NSUInteger) callconv(.c) void)(
        encoder,
        objc.sel("setFragmentTexture:atIndex:"),
        texture,
        index,
    );
}

pub fn setScissorRect(encoder: objc.Id, rect: ScissorRect) void {
    objc.msg(*const fn (objc.Id, objc.Sel, ScissorRect) callconv(.c) void)(
        encoder,
        objc.sel("setScissorRect:"),
        rect,
    );
}

pub fn drawQuads(encoder: objc.Id, instance_count: usize) void {
    objc.msg(*const fn (
        objc.Id,
        objc.Sel,
        objc.NSUInteger,
        objc.NSUInteger,
        objc.NSUInteger,
        objc.NSUInteger,
    ) callconv(.c) void)(
        encoder,
        objc.sel("drawPrimitives:vertexStart:vertexCount:instanceCount:"),
        PrimitiveType.triangle_strip,
        0,
        4,
        instance_count,
    );
}

/// `in_transaction` is the live-resize path (layer has
/// presentsWithTransaction on): commit, wait until scheduled, and present
/// the drawable directly so the frame lands inside the window server's
/// resize transaction — this is what keeps the grid re-laying out in real
/// time instead of the compositor stretching a stale frame.
pub fn endFrame(frame: Frame, drawable: objc.Id, in_transaction: bool) void {
    objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(frame.encoder, objc.sel("endEncoding"));
    if (in_transaction) {
        objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(frame.command_buffer, objc.sel("commit"));
        objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(
            frame.command_buffer,
            objc.sel("waitUntilScheduled"),
        );
        objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(drawable, objc.sel("present"));
    } else {
        objc.setId(frame.command_buffer, objc.sel("presentDrawable:"), drawable);
        objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(frame.command_buffer, objc.sel("commit"));
    }
}

pub fn waitUntilCompleted(command_buffer: objc.Id) void {
    objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(
        command_buffer,
        objc.sel("waitUntilCompleted"),
    );
}

pub fn commandBufferStatus(command_buffer: objc.Id) objc.NSUInteger {
    return objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSUInteger)(
        command_buffer,
        objc.sel("status"),
    );
}

/// Complete an offscreen render without involving a CAMetalDrawable. Shared
/// target textures may be read only after this returns.
pub fn endOffscreen(frame: Frame) !void {
    objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(frame.encoder, objc.sel("endEncoding"));
    objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(frame.command_buffer, objc.sel("commit"));
    objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(
        frame.command_buffer,
        objc.sel("waitUntilCompleted"),
    );
    const status = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSUInteger)(
        frame.command_buffer,
        objc.sel("status"),
    );
    if (status != CommandBufferStatus.completed) {
        const err = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
            frame.command_buffer,
            objc.sel("error"),
        );
        logNSError("offscreen Metal command failed", err);
        return error.MetalCommandBuffer;
    }
}

fn logNSError(prefix: []const u8, err: objc.Id) void {
    if (err == null) {
        std.log.err("{s}: (no NSError provided)", .{prefix});
        return;
    }
    const desc = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        err,
        objc.sel("localizedDescription"),
    );
    if (desc == null) {
        std.log.err("{s}: (no description)", .{prefix});
        return;
    }
    const c_str = objc.msg(
        *const fn (objc.Id, objc.Sel) callconv(.c) ?[*:0]const u8,
    )(desc, objc.sel("UTF8String"));
    if (c_str) |cs| {
        std.log.err("{s}: {s}", .{ prefix, cs });
    } else {
        std.log.err("{s}: (UTF8String was null)", .{prefix});
    }
}
