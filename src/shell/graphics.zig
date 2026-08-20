//! Host-owned Kitty graphics resources. The VT emits bounded commands; this
//! layer performs named-medium I/O, base64/zlib work, and owns decoded RGBA
//! pixels (RFC 0013).

const std = @import("std");
const vt = @import("../vt.zig");
const limits = @import("../graphics_limits.zig");
const png = @import("png.zig");
const c = std.c;

pub const max_images = limits.max_images;
pub const max_image_bytes = limits.max_image_bytes;
pub const max_total_bytes = limits.max_total_bytes;
pub const max_frames_per_image: usize = 256;
const max_shm_name_bytes: usize = 255;
const temporary_marker = "tty-graphics-protocol";

pub const Frame = struct {
    generation: u64,
    rgba: []u8,
    gap_ms: u32,
    transient: bool,
    refs: std.atomic.Value(usize) = .init(1),

    pub fn retain(self: *Frame) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *Frame, alloc: std.mem.Allocator) void {
        const previous = self.refs.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous != 1) return;
        alloc.free(self.rgba);
        alloc.destroy(self);
    }
};

pub const Image = struct {
    id: u32,
    number: u32,
    identity_generation: u64,
    width: u32,
    height: u32,
    root: *Frame,
    frames: std.ArrayList(*Frame) = .empty,
    current_frame: u32 = 1,
    animation_state: vt.graphics.AnimationState = .stopped,
    max_wraps: u32 = 0,
    completed_wraps: u32 = 0,
    shown_at_ms: i64 = 0,
    placed: bool,
    age: u64,
    refs: std.atomic.Value(usize) = .init(1),

    pub fn retain(self: *Image) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *Image, alloc: std.mem.Allocator) void {
        const previous = self.refs.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous != 1) return;
        self.root.release(alloc);
        for (self.frames.items) |item| item.release(alloc);
        self.frames.deinit(alloc);
        alloc.destroy(self);
    }

    pub fn frameCount(self: *const Image) usize {
        return self.frames.items.len + 1;
    }

    pub fn frame(self: *const Image, number: u32) ?*Frame {
        if (number == 1) return self.root;
        if (number < 2 or number - 2 >= self.frames.items.len) return null;
        return self.frames.items[number - 2];
    }

    pub fn current(self: *const Image) *Frame {
        return self.frame(self.current_frame) orelse self.root;
    }
};

pub const RenderView = struct {
    id: u32,
    width: u32,
    height: u32,
    frame: *Frame,
};

pub const Result = struct {
    ok: bool,
    image_id: u32 = 0,
    image_number: u32 = 0,
    generation: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    implicit_id: bool = false,
    message: []const u8 = "OK",
};

pub const FrameDeleteResult = struct {
    image_id: u32 = 0,
    removed_image: bool = false,
};

pub const Store = struct {
    /// Pointer indirection keeps a fetched generation address-stable while a
    /// daemon graphics worker copies it outside the session mutex.
    images: std.ArrayList(*Image) = .empty,
    total_bytes: usize = 0,
    next_generation: u64 = 1,
    next_image_id: u32 = 1,
    age: u64 = 0,
    /// Borrowed from the daemon's stable environment map.
    temporary_directory: ?[]const u8 = null,

    pub fn deinit(self: *Store, alloc: std.mem.Allocator) void {
        for (self.images.items) |image| image.release(alloc);
        self.images.deinit(alloc);
        self.* = .{};
    }

    pub fn find(self: *const Store, id: u32, generation: u64) ?*Image {
        for (self.images.items) |image| {
            if (image.id == id and image.identity_generation == generation) return image;
        }
        return null;
    }

    pub fn currentRender(self: *const Store, id: u32, root_generation: u64) ?RenderView {
        const image = self.find(id, root_generation) orelse return null;
        return .{ .id = image.id, .width = image.width, .height = image.height, .frame = image.current() };
    }

    pub fn renderByGeneration(self: *const Store, id: u32, generation: u64) ?RenderView {
        const image = self.findById(id) orelse return null;
        if (image.root.generation == generation)
            return .{ .id = image.id, .width = image.width, .height = image.height, .frame = image.root };
        for (image.frames.items) |frame| {
            if (frame.generation == generation)
                return .{ .id = image.id, .width = image.width, .height = image.height, .frame = frame };
        }
        return null;
    }

    /// Reconcile resource liveness with the pure VT's authoritative placement
    /// list before applying quota policy. Erase/scroll actions need not emit
    /// host effects solely to make an orphan evictable.
    pub fn syncPlacements(self: *Store, placements: []const vt.graphics.Placement) void {
        for (self.images.items) |image| image.placed = false;
        for (placements) |placement| {
            for (self.images.items) |image| {
                if (image.id == placement.image_id and image.identity_generation == placement.generation) {
                    image.placed = true;
                    break;
                }
            }
        }
    }

    pub fn load(self: *Store, alloc: std.mem.Allocator, request: *const vt.graphics.Load) Result {
        if (request.image_id != 0 and request.image_number != 0)
            return .{ .ok = false, .message = "EINVAL:image id and number are mutually exclusive" };
        if (request.medium == .unsupported)
            return .{ .ok = false, .message = "ENOTSUP:unsupported transmission medium" };
        if (request.format != .png and (request.width == 0 or request.height == 0 or
            request.width > vt.graphics.max_dimension or request.height > vt.graphics.max_dimension))
            return .{ .ok = false, .message = "EINVAL:invalid dimensions" };
        const decoded = decodePixels(alloc, request, self.temporary_directory) catch |err| return .{
            .ok = false,
            .message = switch (err) {
                error.ImageTooLarge => "E2BIG:image exceeds resource limit",
                error.OutOfMemory => "ENOMEM:image allocation failed",
                error.InvalidSharedMemoryName => "EINVAL:invalid shared memory name",
                error.SharedMemoryOpen => "ENOENT:shared memory open failed",
                error.SharedMemoryRange => "EINVAL:invalid shared memory range",
                error.SharedMemoryRead => "EIO:shared memory read failed",
                error.InvalidFilePath => "EINVAL:invalid file path",
                error.FileOpen => "ENOENT:file open failed",
                error.FileType => "EINVAL:not a regular file",
                error.FileRange => "EINVAL:invalid file range",
                error.FileRead => "EIO:file read failed",
                error.UnsafeTemporaryFile => "EINVAL:unsafe temporary file",
                else => "EINVAL:invalid image payload",
            },
        };
        if (request.query) {
            alloc.free(decoded.rgba);
            return .{
                .ok = true,
                .image_id = request.image_id,
                .image_number = request.image_number,
            };
        }

        const implicit_id = request.image_id == 0 and request.image_number == 0;
        const assigned_id = if (request.image_id != 0)
            request.image_id
        else
            self.allocateId() orelse {
                alloc.free(decoded.rgba);
                return .{ .ok = false, .message = "ENOSPC:image id space exhausted" };
            };
        const replace_id = if (request.image_id != 0) assigned_id else 0;
        self.evictUnplaced(alloc, decoded.rgba.len, replace_id);
        const adjusted_old = if (replace_id != 0) self.indexOf(replace_id) else null;
        const adjusted_old_bytes = if (adjusted_old) |index| imageByteSize(self.images.items[index]) else 0;
        if (self.total_bytes - adjusted_old_bytes + decoded.rgba.len > max_total_bytes or
            (adjusted_old == null and self.images.items.len >= max_images))
        {
            alloc.free(decoded.rgba);
            return .{ .ok = false, .message = "ENOSPC:image quota exhausted" };
        }

        self.age +%= 1;
        const generation = self.next_generation;
        self.next_generation +%= 1;
        const root = alloc.create(Frame) catch {
            alloc.free(decoded.rgba);
            return .{ .ok = false, .message = "ENOMEM:image allocation failed" };
        };
        root.* = .{
            .generation = generation,
            .rgba = decoded.rgba,
            .gap_ms = 0,
            .transient = request.transient,
        };
        const replacement = alloc.create(Image) catch {
            root.release(alloc);
            return .{ .ok = false, .message = "ENOMEM:image allocation failed" };
        };
        replacement.* = .{
            .id = assigned_id,
            .number = request.image_number,
            .identity_generation = generation,
            .width = decoded.width,
            .height = decoded.height,
            .root = root,
            .placed = false,
            .age = self.age,
        };
        if (adjusted_old) |index| {
            const old = self.images.items[index];
            self.total_bytes -= imageByteSize(old);
            self.images.items[index] = replacement;
            old.release(alloc);
        } else {
            self.images.append(alloc, replacement) catch {
                replacement.release(alloc);
                return .{ .ok = false, .message = "ENOMEM:image allocation failed" };
            };
        }
        self.total_bytes += decoded.rgba.len;
        return .{
            .ok = true,
            .image_id = assigned_id,
            .image_number = request.image_number,
            .generation = generation,
            .width = decoded.width,
            .height = decoded.height,
            .implicit_id = implicit_id,
        };
    }

    pub fn put(self: *const Store, request: *const vt.graphics.Put) Result {
        if (request.image_id != 0 and request.image_number != 0)
            return .{ .ok = false, .message = "EINVAL:image id and number are mutually exclusive" };
        const image = if (request.image_id != 0)
            self.findById(request.image_id)
        else if (request.image_number != 0)
            self.findNewestByNumber(request.image_number)
        else
            null;
        const found = image orelse return .{ .ok = false, .message = "ENOENT:image not found" };
        return .{
            .ok = true,
            .image_id = found.id,
            .image_number = request.image_number,
            .generation = found.identity_generation,
            .width = found.width,
            .height = found.height,
        };
    }

    pub fn loadFrame(
        self: *Store,
        alloc: std.mem.Allocator,
        request: *const vt.graphics.FrameLoad,
    ) Result {
        const image = self.resolveImage(request.image_id, request.image_number) orelse
            return .{ .ok = false, .message = "ENOENT:image not found" };
        if (request.image_id != 0 and request.image_number != 0)
            return .{ .ok = false, .message = "EINVAL:image id and number are mutually exclusive" };
        const decoded = decodeFramePixels(alloc, request, self.temporary_directory) catch |err| return .{
            .ok = false,
            .message = decodeErrorMessage(err),
        };
        defer alloc.free(decoded.rgba);
        if (decoded.width == 0 or decoded.height == 0 or
            request.x > image.width or request.y > image.height or
            decoded.width > image.width - request.x or decoded.height > image.height - request.y)
            return .{ .ok = false, .message = "EINVAL:frame rectangle out of bounds" };

        const frame_count: u32 = @intCast(image.frameCount());
        if (request.edit_frame > frame_count)
            return .{ .ok = false, .message = "ENOENT:frame not found" };
        const edit_number = request.edit_frame;
        const old_frame = if (edit_number != 0) image.frame(edit_number) else null;
        const base_frame = if (old_frame) |frame|
            frame
        else if (request.base_frame != 0)
            image.frame(request.base_frame) orelse
                return .{ .ok = false, .message = "ENOENT:base frame not found" }
        else
            null;
        if (old_frame == null and image.frames.items.len >= max_frames_per_image - 1)
            return .{ .ok = false, .message = "ENOSPC:frame quota exhausted" };

        const canvas_len = image.root.rgba.len;
        const canvas = alloc.alloc(u8, canvas_len) catch
            return .{ .ok = false, .message = "ENOMEM:frame allocation failed" };
        var canvas_owned = true;
        defer if (canvas_owned) alloc.free(canvas);
        if (base_frame) |frame| {
            @memcpy(canvas, frame.rgba);
        } else {
            fillRgba(canvas, request.background_rgba);
        }
        composeRect(
            canvas,
            image.width,
            decoded.rgba,
            decoded.width,
            decoded.height,
            request.x,
            request.y,
            request.overwrite,
        );

        const inherited_transient = if (base_frame) |frame| frame.transient else false;
        const transient = request.transient or inherited_transient;
        const old_bytes = if (old_frame) |frame| frame.rgba.len else 0;
        self.evictForAdditional(alloc, canvas.len - old_bytes, image.id);
        if (self.total_bytes - old_bytes + canvas.len > max_total_bytes)
            return .{ .ok = false, .message = "ENOSPC:image quota exhausted" };

        const generation = self.next_generation;
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
        const frame = alloc.create(Frame) catch
            return .{ .ok = false, .message = "ENOMEM:frame allocation failed" };
        frame.* = .{
            .generation = generation,
            .rgba = canvas,
            .gap_ms = if (request.gap_ms > 0)
                @intCast(request.gap_ms)
            else if (request.gap_ms < 0)
                0
            else if (old_frame) |old|
                old.gap_ms
            else
                40,
            .transient = transient,
        };
        canvas_owned = false;
        if (old_frame) |old| {
            if (edit_number == 1) {
                image.root = frame;
            } else {
                image.frames.items[edit_number - 2] = frame;
            }
            self.total_bytes -= old.rgba.len;
            old.release(alloc);
        } else {
            image.frames.append(alloc, frame) catch {
                frame.release(alloc);
                return .{ .ok = false, .message = "ENOMEM:frame allocation failed" };
            };
        }
        self.total_bytes += canvas.len;
        image.age = self.bumpAge();
        return .{
            .ok = true,
            .image_id = image.id,
            .image_number = request.image_number,
            .generation = image.identity_generation,
            .width = image.width,
            .height = image.height,
        };
    }

    pub fn controlAnimation(
        self: *Store,
        request: vt.graphics.AnimationControl,
        now_ms: i64,
    ) Result {
        if (request.image_id != 0 and request.image_number != 0)
            return .{ .ok = false, .message = "EINVAL:image id and number are mutually exclusive" };
        const image = self.resolveImage(request.image_id, request.image_number) orelse
            return .{ .ok = false, .message = "ENOENT:image not found" };
        if (request.frame != 0) {
            if (image.frame(request.frame)) |frame| {
                if (request.gap_ms != 0)
                    frame.gap_ms = if (request.gap_ms < 0) 0 else @intCast(request.gap_ms);
            }
        }
        if (request.current_frame != 0 and image.frame(request.current_frame) != null) {
            image.current_frame = request.current_frame;
            image.shown_at_ms = now_ms;
        }
        if (request.state != .unchanged) {
            image.animation_state = request.state;
            image.completed_wraps = 0;
            if (request.state != .stopped) image.shown_at_ms = now_ms;
        }
        if (request.loops != 0) image.max_wraps = request.loops - 1;
        image.age = self.bumpAge();
        return .{
            .ok = true,
            .image_id = image.id,
            .image_number = request.image_number,
            .generation = image.identity_generation,
            .width = image.width,
            .height = image.height,
        };
    }

    pub fn composeFrame(
        self: *Store,
        alloc: std.mem.Allocator,
        request: vt.graphics.FrameCompose,
    ) Result {
        if (request.image_id != 0 and request.image_number != 0)
            return .{ .ok = false, .message = "EINVAL:image id and number are mutually exclusive" };
        const image = self.resolveImage(request.image_id, request.image_number) orelse
            return .{ .ok = false, .message = "ENOENT:image not found" };
        const source = image.frame(request.source_frame) orelse
            return .{ .ok = false, .message = "ENOENT:source frame not found" };
        const destination = image.frame(request.destination_frame) orelse
            return .{ .ok = false, .message = "ENOENT:destination frame not found" };
        const width = if (request.width != 0) request.width else image.width;
        const height = if (request.height != 0) request.height else image.height;
        if (!rectFits(request.source_x, request.source_y, width, height, image.width, image.height) or
            !rectFits(request.destination_x, request.destination_y, width, height, image.width, image.height))
            return .{ .ok = false, .message = "EINVAL:composition rectangle out of bounds" };
        if (source == destination and rectanglesOverlap(
            request.source_x,
            request.source_y,
            request.destination_x,
            request.destination_y,
            width,
            height,
        )) return .{ .ok = false, .message = "EINVAL:overlapping self-composition" };

        const canvas = alloc.dupe(u8, destination.rgba) catch
            return .{ .ok = false, .message = "ENOMEM:frame allocation failed" };
        var canvas_owned = true;
        defer if (canvas_owned) alloc.free(canvas);
        composeSubRect(
            canvas,
            image.width,
            source.rgba,
            image.width,
            request.source_x,
            request.source_y,
            request.destination_x,
            request.destination_y,
            width,
            height,
            request.overwrite,
        );
        const generation = self.next_generation;
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
        const replacement = alloc.create(Frame) catch
            return .{ .ok = false, .message = "ENOMEM:frame allocation failed" };
        replacement.* = .{
            .generation = generation,
            .rgba = canvas,
            .gap_ms = destination.gap_ms,
            .transient = source.transient or destination.transient,
        };
        canvas_owned = false;
        if (request.destination_frame == 1) {
            image.root = replacement;
        } else {
            image.frames.items[request.destination_frame - 2] = replacement;
        }
        destination.release(alloc);
        image.age = self.bumpAge();
        return .{
            .ok = true,
            .image_id = image.id,
            .image_number = request.image_number,
            .generation = image.identity_generation,
            .width = image.width,
            .height = image.height,
        };
    }

    pub fn advanceAnimations(self: *Store, now_ms: i64) bool {
        var changed = false;
        for (self.images.items) |image| {
            if (!animationActive(image)) continue;
            var remaining: usize = 1024;
            while (remaining > 0) : (remaining -= 1) {
                const current = image.current();
                const due = image.shown_at_ms + current.gap_ms;
                if (current.gap_ms != 0 and now_ms < due) break;
                var next = image.current_frame + 1;
                if (next > image.frameCount()) {
                    if (image.animation_state == .loading) break;
                    if (image.max_wraps != 0 and image.completed_wraps >= image.max_wraps) break;
                    image.completed_wraps += 1;
                    next = 1;
                }
                image.current_frame = next;
                if (current.gap_ms != 0) image.shown_at_ms = due;
                changed = true;
            }
            if (remaining == 0) image.shown_at_ms = now_ms;
        }
        return changed;
    }

    pub fn nextAnimationDelayMs(self: *const Store, now_ms: i64) ?u32 {
        var minimum: ?u32 = null;
        for (self.images.items) |image| {
            if (!animationActive(image)) continue;
            const gap = image.current().gap_ms;
            const due = image.shown_at_ms + gap;
            const delay: u32 = if (gap == 0 or due <= now_ms) 1 else @intCast(@min(@as(i64, std.math.maxInt(u32)), due - now_ms));
            if (minimum == null or delay < minimum.?) minimum = delay;
        }
        return minimum;
    }

    pub fn deleteFrame(
        self: *Store,
        alloc: std.mem.Allocator,
        command: vt.graphics.Delete,
    ) FrameDeleteResult {
        const target = switch (command.selector) {
            .animation_frames => |value| value,
            else => return .{},
        };
        const image = self.resolveImage(target.image_id, target.image_number) orelse return .{};
        const image_id = image.id;
        const count: u32 = @intCast(image.frameCount());
        const frame_number = if (target.frame == 0) 1 else @min(target.frame, count);
        if (count == 1) {
            if (!command.free) return .{ .image_id = image_id };
            const index = self.indexOf(image_id) orelse return .{};
            self.removeAt(alloc, index);
            return .{ .image_id = image_id, .removed_image = true };
        }

        if (frame_number == 1) {
            const old_root = image.root;
            image.root = image.frames.orderedRemove(0);
            self.total_bytes -= old_root.rgba.len;
            old_root.release(alloc);
            if (image.current_frame > 1) image.current_frame -= 1;
        } else {
            const removed = image.frames.orderedRemove(frame_number - 2);
            self.total_bytes -= removed.rgba.len;
            removed.release(alloc);
            if (image.current_frame > frame_number) {
                image.current_frame -= 1;
            } else if (image.current_frame == frame_number) {
                image.current_frame = @min(frame_number, @as(u32, @intCast(image.frameCount())));
            }
        }
        image.completed_wraps = 0;
        image.age = self.bumpAge();
        return .{ .image_id = image_id };
    }

    pub fn resolveDelete(self: *const Store, command: vt.graphics.Delete) ?u32 {
        return switch (command.selector) {
            .image => |target| if (self.findById(target.image_id)) |image| image.id else null,
            .newest => |target| if (self.findNewestByNumber(target.image_number)) |image| image.id else null,
            else => null,
        };
    }

    pub fn freeDeleted(
        self: *Store,
        alloc: std.mem.Allocator,
        command: vt.graphics.Delete,
        resolved_image_id: ?u32,
        removed_ids: []const u32,
    ) void {
        if (!command.free) return;
        var index = self.images.items.len;
        while (index > 0) {
            index -= 1;
            const image = self.images.items[index];
            if (image.placed) continue;
            const matches = switch (command.selector) {
                .all => true,
                .image, .newest => resolved_image_id != null and image.id == resolved_image_id.?,
                .range => |target| image.id >= target.first and image.id <= target.last,
                .animation_frames => false,
                else => containsId(removed_ids, image.id),
            };
            if (matches) self.removeAt(alloc, index);
        }
    }

    pub fn freeOrphans(self: *Store, alloc: std.mem.Allocator, image_ids: []const u32) void {
        var index = self.images.items.len;
        while (index > 0) {
            index -= 1;
            const image = self.images.items[index];
            if (!image.placed and containsId(image_ids, image.id)) self.removeAt(alloc, index);
        }
    }

    fn indexOf(self: *const Store, id: u32) ?usize {
        for (self.images.items, 0..) |image, index| if (image.id == id) return index;
        return null;
    }

    fn findById(self: *const Store, id: u32) ?*Image {
        const index = self.indexOf(id) orelse return null;
        return self.images.items[index];
    }

    fn findNewestByNumber(self: *const Store, number: u32) ?*Image {
        var newest: ?*Image = null;
        for (self.images.items) |image| {
            if (image.number != number) continue;
            if (newest == null or image.identity_generation > newest.?.identity_generation) newest = image;
        }
        return newest;
    }

    fn allocateId(self: *Store) ?u32 {
        var attempts: usize = 0;
        while (attempts <= max_images) : (attempts += 1) {
            const candidate = self.next_image_id;
            self.next_image_id +%= 1;
            if (self.next_image_id == 0) self.next_image_id = 1;
            if (candidate != 0 and self.indexOf(candidate) == null) return candidate;
        }
        return null;
    }

    fn resolveImage(self: *const Store, id: u32, number: u32) ?*Image {
        if (id != 0) return self.findById(id);
        if (number != 0) return self.findNewestByNumber(number);
        return null;
    }

    fn bumpAge(self: *Store) u64 {
        self.age +%= 1;
        if (self.age == 0) self.age = 1;
        return self.age;
    }

    fn evictForAdditional(
        self: *Store,
        alloc: std.mem.Allocator,
        additional_bytes: usize,
        exclude_id: u32,
    ) void {
        while (self.total_bytes + additional_bytes > max_total_bytes) {
            var candidate: ?usize = null;
            for (self.images.items, 0..) |image, index| {
                if (image.id == exclude_id or image.placed) continue;
                if (candidate == null or
                    (imageTransient(image) and !imageTransient(self.images.items[candidate.?])) or
                    (imageTransient(image) == imageTransient(self.images.items[candidate.?]) and
                        image.age < self.images.items[candidate.?].age)) candidate = index;
            }
            const index = candidate orelse return;
            self.removeAt(alloc, index);
        }
    }

    fn evictUnplaced(self: *Store, alloc: std.mem.Allocator, incoming_bytes: usize, replace_id: u32) void {
        while (self.total_bytes > 0) {
            const replace_index = self.indexOf(replace_id);
            const replaced_bytes = if (replace_index) |index| imageByteSize(self.images.items[index]) else 0;
            const projected_total = self.total_bytes - replaced_bytes + incoming_bytes;
            const projected_count = self.images.items.len + @intFromBool(replace_index == null);
            if (projected_total <= max_total_bytes and projected_count <= max_images) return;

            var candidate: ?usize = null;
            for (self.images.items, 0..) |image, index| {
                if (image.id == replace_id) continue;
                if (image.placed) continue;
                if (candidate == null or
                    (imageTransient(image) and !imageTransient(self.images.items[candidate.?])) or
                    (imageTransient(image) == imageTransient(self.images.items[candidate.?]) and
                        image.age < self.images.items[candidate.?].age)) candidate = index;
            }
            const index = candidate orelse return;
            self.removeAt(alloc, index);
        }
    }

    fn removeAt(self: *Store, alloc: std.mem.Allocator, index: usize) void {
        const image = self.images.items[index];
        self.total_bytes -= imageByteSize(image);
        _ = self.images.orderedRemove(index);
        image.release(alloc);
    }
};

fn imageByteSize(image: *const Image) usize {
    var total = image.root.rgba.len;
    for (image.frames.items) |frame| total += frame.rgba.len;
    return total;
}

fn imageTransient(image: *const Image) bool {
    if (image.root.transient) return true;
    for (image.frames.items) |frame| if (frame.transient) return true;
    return false;
}

fn animationCanAdvance(image: *const Image) bool {
    if (image.frameCount() < 2 or image.animation_state == .stopped or
        image.animation_state == .unchanged) return false;
    if (image.current_frame < image.frameCount()) return true;
    if (image.animation_state == .loading) return false;
    return image.max_wraps == 0 or image.completed_wraps < image.max_wraps;
}

fn animationActive(image: *const Image) bool {
    if (!animationCanAdvance(image)) return false;
    if (image.root.gap_ms != 0) return true;
    for (image.frames.items) |frame| if (frame.gap_ms != 0) return true;
    return false;
}

fn rectFits(
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    canvas_width: u32,
    canvas_height: u32,
) bool {
    if (width == 0 or height == 0 or x > canvas_width or y > canvas_height) return false;
    return width <= canvas_width - x and height <= canvas_height - y;
}

fn rectanglesOverlap(ax: u32, ay: u32, bx: u32, by: u32, width: u32, height: u32) bool {
    return ax < bx +| width and bx < ax +| width and ay < by +| height and by < ay +| height;
}

fn fillRgba(pixels: []u8, rgba: u32) void {
    const color = [_]u8{
        @truncate(rgba >> 24),
        @truncate(rgba >> 16),
        @truncate(rgba >> 8),
        @truncate(rgba),
    };
    var offset: usize = 0;
    while (offset < pixels.len) : (offset += 4) @memcpy(pixels[offset..][0..4], &color);
}

fn blendPixel(destination: *[4]u8, source: *const [4]u8, overwrite: bool) void {
    if (overwrite or source[3] == 255) {
        destination.* = source.*;
        return;
    }
    if (source[3] == 0) return;
    const source_alpha: u32 = source[3];
    const destination_alpha: u32 = destination[3];
    const inverse: u32 = 255 - source_alpha;
    const out_alpha: u32 = source_alpha + (destination_alpha * inverse + 127) / 255;
    if (out_alpha == 0) {
        destination.* = @splat(0);
        return;
    }
    for (0..3) |channel| {
        const source_premultiplied = @as(u32, source[channel]) * source_alpha;
        const destination_premultiplied =
            (@as(u32, destination[channel]) * destination_alpha * inverse + 127) / 255;
        destination[channel] = @intCast(
            (source_premultiplied + destination_premultiplied + out_alpha / 2) / out_alpha,
        );
    }
    destination[3] = @intCast(out_alpha);
}

fn composeRect(
    destination: []u8,
    destination_width: u32,
    source: []const u8,
    source_width: u32,
    source_height: u32,
    destination_x: u32,
    destination_y: u32,
    overwrite: bool,
) void {
    for (0..source_height) |row| {
        for (0..source_width) |col| {
            const source_offset = (row * source_width + col) * 4;
            const destination_offset =
                ((@as(usize, destination_y) + row) * destination_width + destination_x + col) * 4;
            const destination_pixel: *[4]u8 = @ptrCast(destination[destination_offset..][0..4]);
            const source_pixel: *const [4]u8 = @ptrCast(source[source_offset..][0..4]);
            blendPixel(destination_pixel, source_pixel, overwrite);
        }
    }
}

fn composeSubRect(
    destination: []u8,
    destination_width: u32,
    source: []const u8,
    source_width: u32,
    source_x: u32,
    source_y: u32,
    destination_x: u32,
    destination_y: u32,
    width: u32,
    height: u32,
    overwrite: bool,
) void {
    for (0..height) |row| {
        for (0..width) |col| {
            const source_offset =
                ((@as(usize, source_y) + row) * source_width + source_x + col) * 4;
            const destination_offset =
                ((@as(usize, destination_y) + row) * destination_width + destination_x + col) * 4;
            const destination_pixel: *[4]u8 = @ptrCast(destination[destination_offset..][0..4]);
            const source_pixel: *const [4]u8 = @ptrCast(source[source_offset..][0..4]);
            blendPixel(destination_pixel, source_pixel, overwrite);
        }
    }
}

const Decoded = struct { width: u32, height: u32, rgba: []u8 };

fn decodeFramePixels(
    alloc: std.mem.Allocator,
    request: *const vt.graphics.FrameLoad,
    temporary_directory: ?[]const u8,
) !Decoded {
    const load: vt.graphics.Load = .{
        .query = false,
        .display = false,
        .image_id = request.image_id,
        .image_number = request.image_number,
        .placement_id = 0,
        .format = request.format,
        .compression = request.compression,
        .medium = request.medium,
        .width = request.width,
        .height = request.height,
        .data_size = request.data_size,
        .data_offset = request.data_offset,
        .quiet = request.quiet,
        .cursor_no_move = true,
        .z = 0,
        .transient = request.transient,
        .on_alt = false,
        .row_id = 0,
        .col = 0,
        .encoded = request.encoded,
    };
    return decodePixels(alloc, &load, temporary_directory);
}

fn decodeErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ImageTooLarge => "E2BIG:image exceeds resource limit",
        error.OutOfMemory => "ENOMEM:image allocation failed",
        error.InvalidSharedMemoryName => "EINVAL:invalid shared memory name",
        error.SharedMemoryOpen => "ENOENT:shared memory open failed",
        error.SharedMemoryRange => "EINVAL:invalid shared memory range",
        error.SharedMemoryRead => "EIO:shared memory read failed",
        error.InvalidFilePath => "EINVAL:invalid file path",
        error.FileOpen => "ENOENT:file open failed",
        error.FileType => "EINVAL:not a regular file",
        error.FileRange => "EINVAL:invalid file range",
        error.FileRead => "EIO:file read failed",
        error.UnsafeTemporaryFile => "EINVAL:unsafe temporary file",
        else => "EINVAL:invalid image payload",
    };
}

fn decodePixels(
    alloc: std.mem.Allocator,
    request: *const vt.graphics.Load,
    temporary_directory: ?[]const u8,
) !Decoded {
    if (request.format == .png) {
        if (request.compression == .zlib and request.data_size == 0)
            return error.InvalidByteRange;
        const transport = try loadTransport(alloc, request, null, temporary_directory);
        defer alloc.free(transport);
        const png_data = switch (request.compression) {
            .none => transport,
            .zlib => blk: {
                if (request.data_size > max_image_bytes) return error.ImageTooLarge;
                break :blk try decompressExact(alloc, transport, request.data_size);
            },
        };
        defer if (request.compression == .zlib) alloc.free(png_data);
        const image = try png.decode(alloc, png_data);
        return .{ .width = image.width, .height = image.height, .rgba = image.rgba };
    }

    const channels: usize = switch (request.format) {
        .rgb => 3,
        .rgba => 4,
        .png => unreachable,
    };
    const count = std.math.mul(usize, request.width, request.height) catch return error.ImageTooLarge;
    const expected = std.math.mul(usize, count, channels) catch return error.ImageTooLarge;
    if (expected > max_image_bytes) return error.ImageTooLarge;

    const transport = try loadTransport(alloc, request, expected, temporary_directory);
    var transport_owned = true;
    defer if (transport_owned) alloc.free(transport);

    const raw = switch (request.compression) {
        .none => blk: {
            if (transport.len != expected) return error.InvalidByteCount;
            transport_owned = false;
            break :blk transport;
        },
        .zlib => try decompressExact(alloc, transport, expected),
    };
    if (request.format == .rgba)
        return .{ .width = request.width, .height = request.height, .rgba = raw };
    defer alloc.free(raw);
    const rgba = try alloc.alloc(u8, count * 4);
    for (0..count) |index| {
        rgba[index * 4 + 0] = raw[index * 3 + 0];
        rgba[index * 4 + 1] = raw[index * 3 + 1];
        rgba[index * 4 + 2] = raw[index * 3 + 2];
        rgba[index * 4 + 3] = 255;
    }
    return .{ .width = request.width, .height = request.height, .rgba = rgba };
}

fn decompressExact(alloc: std.mem.Allocator, transport: []const u8, expected: usize) ![]u8 {
    const out = try alloc.alloc(u8, expected);
    errdefer alloc.free(out);
    var input: std.Io.Reader = .fixed(transport);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflater: std.compress.flate.Decompress = .init(&input, .zlib, &window);
    inflater.reader.readSliceAll(out) catch return error.InvalidCompression;
    var extra: [1]u8 = undefined;
    if ((inflater.reader.readSliceShort(&extra) catch return error.InvalidCompression) != 0)
        return error.InvalidByteCount;
    if (inflater.err != null) return error.InvalidCompression;
    return out;
}

fn loadTransport(
    alloc: std.mem.Allocator,
    request: *const vt.graphics.Load,
    expected_uncompressed: ?usize,
    temporary_directory: ?[]const u8,
) ![]u8 {
    return switch (request.medium) {
        .direct => blk: {
            const compressed_png = request.format == .png and request.compression == .zlib;
            if (request.data_offset != 0 or (request.data_size != 0 and !compressed_png))
                return error.InvalidByteRange;
            const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(request.encoded) catch
                return error.InvalidBase64;
            if (decoded_len > max_image_bytes) return error.ImageTooLarge;
            const transport = try alloc.alloc(u8, decoded_len);
            errdefer alloc.free(transport);
            std.base64.standard.Decoder.decode(transport, request.encoded) catch
                return error.InvalidBase64;
            break :blk transport;
        },
        .shared => try readSharedMemory(alloc, request, expected_uncompressed),
        .file, .temporary => try readFile(
            alloc,
            request,
            request.medium == .temporary,
            temporary_directory,
        ),
        else => error.UnsupportedMedium,
    };
}

fn readFile(
    alloc: std.mem.Allocator,
    request: *const vt.graphics.Load,
    temporary: bool,
    temporary_directory: ?[]const u8,
) ![]u8 {
    const path_len = std.base64.standard.Decoder.calcSizeForSlice(request.encoded) catch
        return error.InvalidFilePath;
    if (path_len == 0 or path_len >= c.PATH_MAX) return error.InvalidFilePath;
    var path_buf: [c.PATH_MAX]u8 = undefined;
    std.base64.standard.Decoder.decode(path_buf[0..path_len], request.encoded) catch
        return error.InvalidFilePath;
    if (std.mem.indexOfScalar(u8, path_buf[0..path_len], 0) != null)
        return error.InvalidFilePath;
    path_buf[path_len] = 0;
    const path_z: [:0]const u8 = path_buf[0..path_len :0];

    // Follow symlinks as required by the protocol, then validate the exact
    // opened object through fstat/F_GETPATH. O_CLOEXEC prevents a concurrent
    // shell spawn from inheriting this host-only capability.
    const fd = c.open(path_z.ptr, .{ .CLOEXEC = true });
    if (fd < 0) return error.FileOpen;
    defer _ = c.close(fd);

    var opened_stat: c.Stat = undefined;
    while (c.fstat(fd, &opened_stat) < 0) {
        if (c.errno(-1) == .INTR) continue;
        return error.FileRead;
    }
    if (!c.S.ISREG(opened_stat.mode)) return error.FileType;

    var canonical_buf: [c.PATH_MAX]u8 = @splat(0);
    while (c.fcntl(fd, c.F.GETPATH, &canonical_buf) < 0) {
        if (c.errno(-1) == .INTR) continue;
        return error.InvalidFilePath;
    }
    const canonical_len = std.mem.indexOfScalar(u8, &canonical_buf, 0) orelse
        return error.InvalidFilePath;
    if (canonical_len == 0) return error.InvalidFilePath;
    const canonical = canonical_buf[0..canonical_len];
    const canonical_z: [*:0]const u8 = @ptrCast(&canonical_buf);
    if (isPathInDir("/dev", canonical)) return error.FileType;

    var cleanup_armed = false;
    defer if (cleanup_armed) cleanupTemporaryFile(canonical_z, opened_stat);
    if (temporary) {
        if (std.mem.indexOf(u8, canonical, temporary_marker) == null or
            !isKnownTemporaryPath(canonical, temporary_directory))
            return error.UnsafeTemporaryFile;
        cleanup_armed = true;
    }

    if (opened_stat.size < 0) return error.FileRange;
    const file_len: u64 = @intCast(opened_stat.size);
    const offset: u64 = request.data_offset;
    if (offset > file_len) return error.FileRange;
    const available = file_len - offset;
    const read_len_u64: u64 = if (request.data_size != 0 and !isCompressedPng(request))
        request.data_size
    else
        available;
    if (read_len_u64 > available or read_len_u64 > max_image_bytes)
        return error.FileRange;
    const read_len: usize = @intCast(read_len_u64);
    const transport = try alloc.alloc(u8, read_len);
    errdefer alloc.free(transport);

    var read: usize = 0;
    while (read < transport.len) {
        const count = c.pread(
            fd,
            transport[read..].ptr,
            transport.len - read,
            @intCast(offset + read),
        );
        if (count < 0) {
            if (c.errno(count) == .INTR) continue;
            return error.FileRead;
        }
        if (count == 0) return error.FileRange;
        read += @intCast(count);
    }
    return transport;
}

fn cleanupTemporaryFile(path: [*:0]const u8, opened_stat: c.Stat) void {
    // Do not unlink a different object if a producer swaps the canonical
    // directory entry after the descriptor was validated.
    var current_stat: c.Stat = undefined;
    if (c.fstatat(c.AT.FDCWD, path, &current_stat, 0) != 0 or
        current_stat.dev != opened_stat.dev or
        current_stat.ino != opened_stat.ino or
        !c.S.ISREG(current_stat.mode)) return;
    _ = c.unlink(path);
}

fn isKnownTemporaryPath(path: []const u8, configured: ?[]const u8) bool {
    if (canonicalDirectoryContains("/tmp", path)) return true;
    if (canonicalDirectoryContains("/var/tmp", path)) return true;
    if (configured) |directory| {
        if (canonicalDirectoryContains(directory, path)) return true;
    }
    return false;
}

fn canonicalDirectoryContains(directory: []const u8, path: []const u8) bool {
    if (directory.len == 0 or directory.len >= c.PATH_MAX or
        std.mem.indexOfScalar(u8, directory, 0) != null) return false;
    var directory_buf: [c.PATH_MAX]u8 = undefined;
    @memcpy(directory_buf[0..directory.len], directory);
    directory_buf[directory.len] = 0;
    const directory_z: [:0]const u8 = directory_buf[0..directory.len :0];
    var resolved_buf: [c.PATH_MAX]u8 = @splat(0);
    if (c.realpath(directory_z.ptr, &resolved_buf) == null) return false;
    const resolved_len = std.mem.indexOfScalar(u8, &resolved_buf, 0) orelse return false;
    return isPathInDir(resolved_buf[0..resolved_len], path);
}

fn isPathInDir(directory: []const u8, path: []const u8) bool {
    if (directory.len == 0 or !std.mem.startsWith(u8, path, directory)) return false;
    if (path.len == directory.len or std.fs.path.isSep(directory[directory.len - 1])) return true;
    return std.fs.path.isSep(path[directory.len]);
}

fn readSharedMemory(
    alloc: std.mem.Allocator,
    request: *const vt.graphics.Load,
    expected_uncompressed: ?usize,
) ![]u8 {
    const name_len = std.base64.standard.Decoder.calcSizeForSlice(request.encoded) catch
        return error.InvalidSharedMemoryName;
    if (name_len < 2 or name_len > max_shm_name_bytes) return error.InvalidSharedMemoryName;
    var name_buf: [max_shm_name_bytes + 1]u8 = undefined;
    std.base64.standard.Decoder.decode(name_buf[0..name_len], request.encoded) catch
        return error.InvalidSharedMemoryName;
    const name = name_buf[0..name_len];
    if (name[0] != '/' or std.mem.indexOfScalar(u8, name[1..], '/') != null or
        std.mem.indexOfScalar(u8, name, 0) != null)
        return error.InvalidSharedMemoryName;
    name_buf[name_len] = 0;
    const name_z: [:0]const u8 = name_buf[0..name_len :0];

    // shm_open(2) accepts its own deliberately small flag set and guarantees
    // FD_CLOEXEC on the returned descriptor. Passing O_CLOEXEC happened to
    // work on older Darwin but is rejected by macOS 26. Ghostty's MIT-licensed
    // implementation independently uses the same RDONLY-only open.
    const open_flags: c_int = @bitCast(c.O{ .ACCMODE = .RDONLY });
    const fd = c.shm_open(name_z.ptr, open_flags);
    if (fd < 0) return error.SharedMemoryOpen;
    defer _ = c.close(fd);
    // POSIX/Kitty ownership transfers to the terminal after a successful
    // open. Always make the object name disappear, even if validation or a
    // later read fails; the already-open descriptor remains readable.
    defer _ = c.shm_unlink(name_z.ptr);

    var stat: c.Stat = undefined;
    while (c.fstat(fd, &stat) < 0) {
        if (c.errno(-1) == .INTR) continue;
        return error.SharedMemoryRead;
    }
    if (stat.size < 0) return error.SharedMemoryRange;
    const object_len: u64 = @intCast(stat.size);
    const offset: u64 = request.data_offset;
    if (offset > object_len) return error.SharedMemoryRange;
    const available = object_len - offset;
    // Darwin rounds a POSIX shared-memory object's reported size up to a VM
    // page. With no explicit S range, raw formats are nevertheless exactly
    // width * height * channels bytes, so use that protocol-derived length.
    // Compressed data has no derivable transport length and uses the available
    // object range, matching Ghostty's shared-memory behavior.
    const read_len_u64: u64 = if (request.data_size != 0 and !isCompressedPng(request))
        request.data_size
    else if (request.compression == .none and expected_uncompressed != null)
        expected_uncompressed.?
    else
        available;
    if (read_len_u64 > available or read_len_u64 > max_image_bytes)
        return error.SharedMemoryRange;
    const read_len: usize = @intCast(read_len_u64);
    const transport = try alloc.alloc(u8, read_len);
    errdefer alloc.free(transport);
    if (read_len == 0) return transport;

    // Darwin's POSIX shared-memory descriptors are memory objects, not
    // ordinary files: read(2)/pread(2) fail with ENXIO. Map only the selected
    // byte range (plus its leading page fragment) and copy while the producer's
    // descriptor remains open.
    const page_size_signed = c.sysconf(@intFromEnum(c._SC.PAGESIZE));
    if (page_size_signed <= 0) return error.SharedMemoryRead;
    const page_size: u64 = @intCast(page_size_signed);
    const map_offset = offset - (offset % page_size);
    const prefix: usize = @intCast(offset - map_offset);
    const map_len = std.math.add(usize, prefix, read_len) catch
        return error.SharedMemoryRange;
    const mapping = c.mmap(
        null,
        map_len,
        c.PROT{ .READ = true },
        c.MAP{ .TYPE = .SHARED },
        fd,
        @intCast(map_offset),
    );
    if (mapping == c.MAP_FAILED) return error.SharedMemoryRead;
    defer _ = c.munmap(@ptrCast(@alignCast(mapping)), map_len);
    const mapped: [*]const u8 = @ptrCast(mapping);
    @memcpy(transport, mapped[prefix..][0..read_len]);
    return transport;
}

fn isCompressedPng(request: *const vt.graphics.Load) bool {
    return request.format == .png and request.compression == .zlib;
}

fn containsId(ids: []const u32, target: u32) bool {
    for (ids) |id| if (id == target) return true;
    return false;
}

fn testLoadRgba(
    store: *Store,
    alloc: std.mem.Allocator,
    id: u32,
    width: u32,
    height: u32,
    pixels: []const u8,
) !Result {
    const encoded_len = std.base64.standard.Encoder.calcSize(pixels.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, pixels);
    var request: vt.graphics.Load = .{
        .query = false,
        .display = false,
        .image_id = id,
        .placement_id = 0,
        .format = .rgba,
        .compression = .none,
        .medium = .direct,
        .width = width,
        .height = height,
        .data_size = 0,
        .data_offset = 0,
        .quiet = 0,
        .cursor_no_move = true,
        .z = 0,
        .on_alt = false,
        .row_id = 0,
        .col = 0,
        .encoded = encoded,
    };
    return store.load(alloc, &request);
}

fn testLoadFrame(
    store: *Store,
    alloc: std.mem.Allocator,
    id: u32,
    width: u32,
    height: u32,
    pixels: []const u8,
    options: struct {
        x: u32 = 0,
        y: u32 = 0,
        base: u32 = 0,
        edit: u32 = 0,
        gap: i32 = 0,
        overwrite: bool = false,
        background: u32 = 0,
        transient: bool = false,
    },
) !Result {
    const encoded_len = std.base64.standard.Encoder.calcSize(pixels.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, pixels);
    var request: vt.graphics.FrameLoad = .{
        .image_id = id,
        .image_number = 0,
        .format = .rgba,
        .compression = .none,
        .medium = .direct,
        .width = width,
        .height = height,
        .data_size = 0,
        .data_offset = 0,
        .quiet = 0,
        .x = options.x,
        .y = options.y,
        .base_frame = options.base,
        .edit_frame = options.edit,
        .gap_ms = options.gap,
        .overwrite = options.overwrite,
        .background_rgba = options.background,
        .transient = options.transient,
        .encoded = encoded,
    };
    return store.loadFrame(alloc, &request);
}

test "direct RGB query validates without storing" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    var request: vt.graphics.Load = .{
        .query = true,
        .display = false,
        .image_id = 4207,
        .placement_id = 0,
        .format = .rgb,
        .compression = .none,
        .medium = .direct,
        .width = 1,
        .height = 1,
        .data_size = 0,
        .data_offset = 0,
        .quiet = 0,
        .cursor_no_move = false,
        .z = 0,
        .on_alt = false,
        .row_id = 0,
        .col = 0,
        .encoded = @constCast("AAAA"),
    };
    const result = store.load(alloc, &request);
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(usize, 0), store.images.items.len);
}

test "terminal-browser zlib RGBA frame decodes and replaces atomically" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    var request: vt.graphics.Load = .{
        .query = false,
        .display = true,
        .image_id = 7,
        .placement_id = 1,
        .format = .rgba,
        .compression = .zlib,
        .medium = .direct,
        .width = 1,
        .height = 1,
        .data_size = 0,
        .data_offset = 0,
        .quiet = 2,
        .cursor_no_move = true,
        .z = 0,
        .on_alt = true,
        .row_id = 0,
        .col = 0,
        .encoded = @constCast("eJxjYGBgAAAABAAB"),
    };
    const result = store.load(alloc, &request);
    try std.testing.expect(result.ok);
    const image = store.find(7, result.generation) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, image.root.rgba);
    store.syncPlacements(&.{});
    try std.testing.expect(!image.placed);
}

test "image numbers allocate fresh ids and put resolves newest resource" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    var request: vt.graphics.Load = .{
        .query = false,
        .display = false,
        .image_id = 0,
        .image_number = 77,
        .placement_id = 0,
        .format = .rgba,
        .compression = .none,
        .medium = .direct,
        .width = 1,
        .height = 1,
        .data_size = 0,
        .data_offset = 0,
        .quiet = 0,
        .cursor_no_move = false,
        .z = 0,
        .on_alt = false,
        .row_id = 0,
        .col = 0,
        .encoded = @constCast("AQIDBA=="),
    };
    const first = store.load(alloc, &request);
    const second = store.load(alloc, &request);
    try std.testing.expect(first.ok and second.ok);
    try std.testing.expect(first.image_id != 0 and second.image_id != 0);
    try std.testing.expect(first.image_id != second.image_id);
    try std.testing.expectEqual(@as(usize, 2), store.images.items.len);

    const put = store.put(&.{
        .image_id = 0,
        .image_number = 77,
        .placement_id = 3,
        .quiet = 0,
        .cursor_no_move = true,
        .z = 0,
        .source_x = 0,
        .source_y = 0,
        .source_width = 0,
        .source_height = 0,
        .cell_offset_x = 0,
        .cell_offset_y = 0,
        .columns = 1,
        .rows = 1,
        .on_alt = false,
        .row_id = 0,
        .col = 0,
    });
    try std.testing.expect(put.ok);
    try std.testing.expectEqual(second.image_id, put.image_id);
    try std.testing.expectEqual(second.generation, put.generation);

    request.image_id = 9;
    const conflicting = store.load(alloc, &request);
    try std.testing.expect(!conflicting.ok);
    try std.testing.expectEqualStrings(
        "EINVAL:image id and number are mutually exclusive",
        conflicting.message,
    );
}

const test_png_base64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFUlEQVR4nGP4z8Dwn+EEQwMDkAYDAEI+CUGYxtFzAAAAAElFTkSuQmCC";

fn testPngRequest(encoded: []u8) vt.graphics.Load {
    return .{
        .query = false,
        .display = true,
        .image_id = 30,
        .placement_id = 1,
        .format = .png,
        .compression = .none,
        .medium = .direct,
        // PNG metadata is authoritative over supplied control dimensions.
        .width = 99,
        .height = 88,
        .data_size = 0,
        .data_offset = 0,
        .quiet = 0,
        .cursor_no_move = true,
        .z = 0,
        .on_alt = false,
        .row_id = 0,
        .col = 0,
        .encoded = encoded,
    };
}

test "direct PNG derives dimensions and stores straight-alpha pixels" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    var request = testPngRequest(@constCast(test_png_base64));
    const result = store.load(alloc, &request);
    try std.testing.expect(result.ok);
    const image = store.find(request.image_id, result.generation) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expectEqual(@as(u32, 2), image.height);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.root.rgba[0..4]);
    try std.testing.expectEqual(@as(u8, 128), image.root.rgba[7]);

    request.encoded = @constCast("aW52YWxpZA==");
    const malformed = store.load(alloc, &request);
    try std.testing.expect(!malformed.ok);
    try std.testing.expect(store.find(request.image_id, result.generation) != null);
}

test "outer-zlib PNG requires and validates S" {
    const alloc = std.testing.allocator;
    const compressed =
        "eJzrDPBz5+WS4mJgYOD19HAJAtJMIMzBBiSLtvGqAClRTxfHkIo5yT/OH/gw/yGLMzPzBDZmBic7TscZxy4WAxUweLr6uaxzSmgCAGp9EzI=";
    var store: Store = .{};
    defer store.deinit(alloc);
    var request = testPngRequest(@constCast(compressed));
    request.image_id = 31;
    request.compression = .zlib;
    const missing_size = store.load(alloc, &request);
    try std.testing.expect(!missing_size.ok);
    request.data_size = 78;
    const result = store.load(alloc, &request);
    try std.testing.expect(result.ok);
    const image = store.find(request.image_id, result.generation) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expectEqual(@as(u32, 2), image.height);
}

test "regular-file transport decodes PNG" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const png_size = try std.base64.standard.Decoder.calcSizeForSlice(test_png_base64);
    const png_bytes = try alloc.alloc(u8, png_size);
    defer alloc.free(png_bytes);
    try std.base64.standard.Decoder.decode(png_bytes, test_png_base64);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pixels.png", .data = png_bytes });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try tmp.dir.realPathFile(testing.io, "pixels.png", &path_buf)];
    var encoded_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
    const encoded_len = std.base64.standard.Encoder.calcSize(path.len);
    const encoded = std.base64.standard.Encoder.encode(encoded_buf[0..encoded_len], path);

    var store: Store = .{};
    defer store.deinit(alloc);
    var request = testPngRequest(@constCast(encoded));
    request.image_id = 32;
    request.medium = .file;
    const result = store.load(alloc, &request);
    try testing.expect(result.ok);
    const image = store.find(request.image_id, result.generation) orelse
        return error.TestExpectedEqual;
    try testing.expectEqual(@as(u32, 2), image.width);
    try testing.expectEqual(@as(u32, 2), image.height);
}

test "regular-file transport follows bounded offset and stores pixels" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "pixels.data",
        .data = &.{ 99, 98, 7, 8, 9, 255, 97 },
    });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try tmp.dir.realPathFile(testing.io, "pixels.data", &path_buf)];
    var encoded_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
    const encoded_len = std.base64.standard.Encoder.calcSize(path.len);
    const encoded = std.base64.standard.Encoder.encode(encoded_buf[0..encoded_len], path);

    var store: Store = .{};
    defer store.deinit(alloc);
    var request: vt.graphics.Load = .{
        .query = false,
        .display = true,
        .image_id = 21,
        .placement_id = 1,
        .format = .rgba,
        .compression = .none,
        .medium = .file,
        .width = 1,
        .height = 1,
        .data_size = 4,
        .data_offset = 2,
        .quiet = 0,
        .cursor_no_move = true,
        .z = 0,
        .on_alt = false,
        .row_id = 0,
        .col = 0,
        .encoded = @constCast(encoded),
    };
    const result = store.load(alloc, &request);
    try testing.expect(result.ok);
    const image = store.find(21, result.generation) orelse return error.TestExpectedEqual;
    try testing.expectEqualSlices(u8, &.{ 7, 8, 9, 255 }, image.root.rgba);

    // Without S, the protocol selects through EOF; raw validation must not
    // silently discard the trailing byte.
    request.image_id = 24;
    request.data_size = 0;
    const trailing = store.load(alloc, &request);
    try testing.expect(!trailing.ok);
    try testing.expect(store.indexOf(24) == null);
}

test "safe temporary-file transport unlinks after reading" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const filename = "tty-graphics-protocol-pixels.data";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = filename, .data = &.{ 1, 2, 3, 255 } });
    var directory_buf: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buf[0..try tmp.dir.realPath(testing.io, &directory_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try tmp.dir.realPathFile(testing.io, filename, &path_buf)];
    var encoded_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
    const encoded_len = std.base64.standard.Encoder.calcSize(path.len);
    const encoded = std.base64.standard.Encoder.encode(encoded_buf[0..encoded_len], path);

    var store: Store = .{ .temporary_directory = directory };
    defer store.deinit(alloc);
    var request: vt.graphics.Load = .{
        .query = true,
        .display = false,
        .image_id = 22,
        .placement_id = 0,
        .format = .rgba,
        .compression = .none,
        .medium = .temporary,
        .width = 1,
        .height = 1,
        .data_size = 0,
        .data_offset = 0,
        .quiet = 0,
        .cursor_no_move = false,
        .z = 0,
        .on_alt = false,
        .row_id = 0,
        .col = 0,
        .encoded = @constCast(encoded),
    };
    const result = store.load(alloc, &request);
    try testing.expect(result.ok);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, filename, .{}));
}

test "unsafe temporary-file path is rejected without deletion" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const filename = "ordinary-pixels.data";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = filename, .data = &.{ 1, 2, 3, 255 } });
    var directory_buf: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buf[0..try tmp.dir.realPath(testing.io, &directory_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try tmp.dir.realPathFile(testing.io, filename, &path_buf)];
    var encoded_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
    const encoded_len = std.base64.standard.Encoder.calcSize(path.len);
    const encoded = std.base64.standard.Encoder.encode(encoded_buf[0..encoded_len], path);

    var store: Store = .{ .temporary_directory = directory };
    defer store.deinit(alloc);
    var request: vt.graphics.Load = .{
        .query = true,
        .display = false,
        .image_id = 23,
        .placement_id = 0,
        .format = .rgba,
        .compression = .none,
        .medium = .temporary,
        .width = 1,
        .height = 1,
        .data_size = 0,
        .data_offset = 0,
        .quiet = 0,
        .cursor_no_move = false,
        .z = 0,
        .on_alt = false,
        .row_id = 0,
        .col = 0,
        .encoded = @constCast(encoded),
    };
    const result = store.load(alloc, &request);
    try testing.expect(!result.ok);
    try testing.expectEqualStrings("EINVAL:unsafe temporary file", result.message);
    try tmp.dir.access(testing.io, filename, .{});
}

test "terminal-browser POSIX shared-memory query derives raw byte length and unlinks" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);

    var name_buf: [96]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/boringterminal-test-{d}", .{c.getpid()});
    _ = c.shm_unlink(name.ptr);
    const create_flags: c_int = @bitCast(c.O{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .EXCL = true,
    });
    const fd = c.shm_open(name.ptr, create_flags, @as(c.mode_t, 0o600));
    if (fd < 0) return error.SharedMemoryCreateFailed;
    defer _ = c.close(fd);
    defer _ = c.shm_unlink(name.ptr);
    if (c.ftruncate(fd, 4) < 0) return error.SharedMemoryCreateFailed;
    const pixel = [_]u8{ 7, 8, 9, 255 };
    const mapping = c.mmap(
        null,
        pixel.len,
        c.PROT{ .READ = true, .WRITE = true },
        c.MAP{ .TYPE = .SHARED },
        fd,
        0,
    );
    if (mapping == c.MAP_FAILED) return error.SharedMemoryCreateFailed;
    defer _ = c.munmap(@ptrCast(@alignCast(mapping)), pixel.len);
    const mapped: [*]u8 = @ptrCast(mapping);
    @memcpy(mapped[0..pixel.len], &pixel);

    var encoded_buf: [160]u8 = undefined;
    const encoded_len = std.base64.standard.Encoder.calcSize(name.len);
    const encoded = std.base64.standard.Encoder.encode(encoded_buf[0..encoded_len], name);
    var request: vt.graphics.Load = .{
        .query = true,
        .display = false,
        .image_id = 299,
        .placement_id = 0,
        .format = .rgba,
        .compression = .none,
        .medium = .shared,
        .width = 1,
        .height = 1,
        // terminal-browser omits S; Darwin reports the page-rounded backing
        // size, so the loader must derive four bytes from 1x1 RGBA.
        .data_size = 0,
        .data_offset = 0,
        .quiet = 0,
        .cursor_no_move = false,
        .z = 0,
        .on_alt = false,
        .row_id = 0,
        .col = 0,
        .encoded = @constCast(encoded),
    };
    const result = store.load(alloc, &request);
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(usize, 0), store.images.items.len);

    const reopened = c.shm_open(name.ptr, @bitCast(c.O{ .ACCMODE = .RDONLY }));
    if (reopened >= 0) {
        _ = c.close(reopened);
        return error.SharedMemoryWasNotUnlinked;
    }
}

test "animation frames compose onto a base and edit in place" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    const base = [_]u8{ 255, 0, 0, 255, 0, 0, 0, 0 };
    const loaded = try testLoadRgba(&store, alloc, 41, 2, 1, &base);
    try std.testing.expect(loaded.ok);

    const half_blue = [_]u8{ 0, 0, 255, 128 };
    const added = try testLoadFrame(&store, alloc, 41, 1, 1, &half_blue, .{
        .x = 1,
        .base = 1,
        .transient = true,
    });
    try std.testing.expect(added.ok);
    const image = store.find(41, loaded.generation) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 2), image.frameCount());
    try std.testing.expectEqual(@as(u32, 40), image.frame(2).?.gap_ms);
    try std.testing.expect(image.frame(2).?.transient);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.frame(2).?.rgba[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 128 }, image.frame(2).?.rgba[4..8]);

    const green = [_]u8{ 0, 255, 0, 255 };
    const edited = try testLoadFrame(&store, alloc, 41, 1, 1, &green, .{
        .edit = 2,
        .overwrite = true,
        .gap = -1,
    });
    try std.testing.expect(edited.ok);
    try std.testing.expectEqual(@as(usize, 2), image.frameCount());
    try std.testing.expectEqual(@as(u32, 0), image.frame(2).?.gap_ms);
    try std.testing.expectEqualSlices(u8, &green, image.frame(2).?.rgba[0..4]);
}

test "frame composition replaces the requested destination rectangle" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    const root = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 };
    const loaded = try testLoadRgba(&store, alloc, 42, 2, 1, &root);
    try std.testing.expect(loaded.ok);
    const second = [_]u8{ 0, 0, 255, 255, 255, 255, 255, 255 };
    try std.testing.expect((try testLoadFrame(&store, alloc, 42, 2, 1, &second, .{
        .overwrite = true,
    })).ok);
    const result = store.composeFrame(alloc, .{
        .image_id = 42,
        .image_number = 0,
        .quiet = 0,
        .source_frame = 1,
        .destination_frame = 2,
        .destination_x = 1,
        .destination_y = 0,
        .width = 1,
        .height = 1,
        .source_x = 0,
        .source_y = 0,
        .overwrite = true,
    });
    try std.testing.expect(result.ok);
    const image = store.find(42, loaded.generation) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, image.frame(2).?.rgba[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.frame(2).?.rgba[4..8]);
}

test "terminal-driven animation advances and honors finite loop count" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    const red = [_]u8{ 255, 0, 0, 255 };
    const green = [_]u8{ 0, 255, 0, 255 };
    const blue = [_]u8{ 0, 0, 255, 255 };
    const loaded = try testLoadRgba(&store, alloc, 43, 1, 1, &red);
    try std.testing.expect(loaded.ok);
    try std.testing.expect((try testLoadFrame(&store, alloc, 43, 1, 1, &green, .{ .gap = 10 })).ok);
    try std.testing.expect((try testLoadFrame(&store, alloc, 43, 1, 1, &blue, .{ .gap = 10 })).ok);
    try std.testing.expect(store.controlAnimation(.{
        .image_id = 43,
        .image_number = 0,
        .quiet = 0,
        .state = .running,
        .frame = 1,
        .gap_ms = 10,
        .current_frame = 1,
        .loops = 2,
    }, 0).ok);
    const image = store.find(43, loaded.generation) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(?u32, 10), store.nextAnimationDelayMs(0));
    try std.testing.expect(store.advanceAnimations(10));
    try std.testing.expectEqual(@as(u32, 2), image.current_frame);
    try std.testing.expect(store.advanceAnimations(20));
    try std.testing.expectEqual(@as(u32, 3), image.current_frame);
    try std.testing.expect(store.advanceAnimations(30));
    try std.testing.expectEqual(@as(u32, 1), image.current_frame);
    try std.testing.expect(store.advanceAnimations(50));
    try std.testing.expectEqual(@as(u32, 3), image.current_frame);
    try std.testing.expect(!store.advanceAnimations(60));
    try std.testing.expectEqual(@as(?u32, null), store.nextAnimationDelayMs(60));
}

test "delete animation frame promotes root and uppercase deletes a lone image" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    const red = [_]u8{ 255, 0, 0, 255 };
    const green = [_]u8{ 0, 255, 0, 255 };
    const loaded = try testLoadRgba(&store, alloc, 44, 1, 1, &red);
    try std.testing.expect(loaded.ok);
    try std.testing.expect((try testLoadFrame(&store, alloc, 44, 1, 1, &green, .{})).ok);
    const selector: vt.graphics.DeleteSelector = .{ .animation_frames = .{
        .image_id = 44,
        .image_number = 0,
        .frame = 1,
    } };
    var command: vt.graphics.Delete = .{
        .selector = selector,
        .free = false,
        .quiet = 0,
        .on_alt = false,
        .view_top_row_id = 0,
        .cursor_row_id = 0,
        .cursor_col = 0,
    };
    try std.testing.expect(!store.deleteFrame(alloc, command).removed_image);
    const image = store.find(44, loaded.generation) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), image.frameCount());
    try std.testing.expectEqualSlices(u8, &green, image.root.rgba);
    command.free = true;
    try std.testing.expect(store.deleteFrame(alloc, command).removed_image);
    try std.testing.expectEqual(@as(usize, 0), store.images.items.len);
}
