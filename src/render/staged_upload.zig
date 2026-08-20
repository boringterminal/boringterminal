//! Viewer ownership for one RFC 0015 staging lease carried through RFC 0023's
//! Metal frame lifetime. This module performs no socket I/O.

const std = @import("std");
const objc = @import("objc.zig");

pub const ResourceKey = struct {
    session_id: u64,
    image_id: u32,
    generation: u64,
};

pub const StagingKey = struct {
    connection_epoch: u64,
    slot_index: u8,
    lease_token: u64,
};

pub const ReleaseRecord = struct {
    key: StagingKey,
    disable_after_release: bool = false,
};

pub const ReleaseFn = *const fn (?*anyopaque, ReleaseRecord) void;

pub const State = enum(u8) {
    queued,
    submitted,
    completed,
    failed,
    canceled,
};

pub const Upload = struct {
    alloc: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    state: std.atomic.Value(State) = .init(.queued),
    resource: ResourceKey,
    staging: StagingKey,
    width: u32,
    height: u32,
    bytes_per_row: usize,
    source_buffer: objc.Id,
    texture: objc.Id,
    release_context: ?*anyopaque,
    release_fn: ReleaseFn,

    pub fn create(
        alloc: std.mem.Allocator,
        resource: ResourceKey,
        staging: StagingKey,
        width: u32,
        height: u32,
        bytes_per_row: usize,
        source_buffer: objc.Id,
        texture: objc.Id,
        release_context: ?*anyopaque,
        release_fn: ReleaseFn,
    ) !*Upload {
        const self = try alloc.create(Upload);
        self.* = .{
            .alloc = alloc,
            .resource = resource,
            .staging = staging,
            .width = width,
            .height = height,
            .bytes_per_row = bytes_per_row,
            .source_buffer = source_buffer,
            .texture = texture,
            .release_context = release_context,
            .release_fn = release_fn,
        };
        return self;
    }

    pub fn retain(self: *Upload) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *Upload) void {
        const previous = self.refs.fetchSub(1, .release);
        std.debug.assert(previous > 0);
        if (previous != 1) return;
        _ = self.refs.load(.acquire);

        const current = self.state.load(.acquire);
        if (current == .queued) {
            const raced = self.state.cmpxchgStrong(.queued, .canceled, .acq_rel, .acquire);
            std.debug.assert(raced == null);
            self.retireSourceAndNotify(false);
        } else {
            // A submitted upload always has a frame-slot retain. Reaching the
            // final release in that state would free GPU-visible memory.
            std.debug.assert(current != .submitted);
            std.debug.assert(self.source_buffer == null);
        }

        if (self.texture != null) objc.release(self.texture);
        self.alloc.destroy(self);
    }

    pub fn markSubmitted(self: *Upload) !void {
        if (self.state.cmpxchgStrong(.queued, .submitted, .acq_rel, .acquire)) |_| {
            return error.InvalidUploadTransition;
        }
    }

    /// Called only by the main-thread completion drain after Metal has retired
    /// the command buffer. The source buffer dies before the daemon is told it
    /// may overwrite or unmap the slot.
    pub fn finish(self: *Upload, succeeded: bool) !void {
        const next: State = if (succeeded) .completed else .failed;
        if (self.state.cmpxchgStrong(.submitted, next, .acq_rel, .acquire)) |_| {
            return error.InvalidUploadTransition;
        }
        self.retireSourceAndNotify(!succeeded);
    }

    pub fn currentState(self: *const Upload) State {
        return self.state.load(.acquire);
    }

    fn retireSourceAndNotify(self: *Upload, disable_after_release: bool) void {
        std.debug.assert(self.source_buffer != null or @import("builtin").is_test);
        if (self.source_buffer != null) {
            objc.release(self.source_buffer);
            self.source_buffer = null;
        }
        self.release_fn(self.release_context, .{
            .key = self.staging,
            .disable_after_release = disable_after_release,
        });
    }
};

const ReleaseCapture = struct {
    count: usize = 0,
    last: ReleaseRecord = undefined,

    fn record(context: ?*anyopaque, release_record: ReleaseRecord) void {
        const self: *ReleaseCapture = @ptrCast(@alignCast(context.?));
        self.count += 1;
        self.last = release_record;
    }
};

fn testUpload(capture: *ReleaseCapture) !*Upload {
    return Upload.create(
        std.testing.allocator,
        .{ .session_id = 9, .image_id = 7, .generation = 5 },
        .{ .connection_epoch = 3, .slot_index = 2, .lease_token = 41 },
        2,
        1,
        256,
        null,
        null,
        capture,
        ReleaseCapture.record,
    );
}

test "queued upload cancellation releases its exact staging capability once" {
    var capture: ReleaseCapture = .{};
    const upload = try testUpload(&capture);
    upload.release();
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(@as(u64, 3), capture.last.key.connection_epoch);
    try std.testing.expectEqual(@as(u8, 2), capture.last.key.slot_index);
    try std.testing.expectEqual(@as(u64, 41), capture.last.key.lease_token);
    try std.testing.expect(!capture.last.disable_after_release);
}

test "submitted upload releases only after injected successful completion" {
    var capture: ReleaseCapture = .{};
    const upload = try testUpload(&capture);
    upload.retain(); // frame slot
    try upload.markSubmitted();
    upload.release(); // cache/image owner may disappear while GPU owns it
    try std.testing.expectEqual(@as(usize, 0), capture.count);
    try upload.finish(true);
    try std.testing.expectEqual(State.completed, upload.currentState());
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expect(!capture.last.disable_after_release);
    upload.release();
}

test "GPU failure releases the lease and requests shared-path disable" {
    var capture: ReleaseCapture = .{};
    const upload = try testUpload(&capture);
    try upload.markSubmitted();
    try upload.finish(false);
    try std.testing.expectEqual(State.failed, upload.currentState());
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expect(capture.last.disable_after_release);
    upload.release();
}

test "upload state machine rejects duplicate and out-of-order completion" {
    var capture: ReleaseCapture = .{};
    const upload = try testUpload(&capture);
    try std.testing.expectError(error.InvalidUploadTransition, upload.finish(true));
    try upload.markSubmitted();
    try std.testing.expectError(error.InvalidUploadTransition, upload.markSubmitted());
    try upload.finish(true);
    try std.testing.expectError(error.InvalidUploadTransition, upload.finish(true));
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    upload.release();
}
