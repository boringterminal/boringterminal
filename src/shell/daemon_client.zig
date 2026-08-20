//! GUI-side client for RFC 0012. Interactive and serialized refresh commands
//! use separate local Unix sockets; daemon invalidations arrive on a third
//! reader connection.

const std = @import("std");
const protocol = @import("../daemon/protocol.zig");
const lifecycle = @import("../daemon/lifecycle.zig");
const selected_protocol = @import("daemon_protocol/selected.zig");
const vt = @import("../vt.zig");
const c = std.c;
const session_mod = @import("session.zig");
const title_mod = @import("title.zig");
const objc = @import("../render/objc.zig");
const staged_upload = @import("../render/staged_upload.zig");

pub const StagedUpload = staged_upload.Upload;

pub const EventFn = *const fn (?*anyopaque, u64, protocol.EventFlags) void;
pub const RefreshFn = *const fn (?*anyopaque, u64) void;
pub const PrepareImageFn = *const fn (
    ?*anyopaque,
    *const protocol.Image,
) anyerror!objc.Id;
pub const PrepareStagedImageFn = *const fn (
    ?*anyopaque,
    *const StagedFetch,
) anyerror!*StagedUpload;

pub const StagedFetch = struct {
    session_id: u64,
    metadata: protocol.StagedImage,
    mapping: *anyopaque,
    mapping_length: usize,
    staging_key: staged_upload.StagingKey,
    release_context: ?*anyopaque,
    release_fn: staged_upload.ReleaseFn,
};

pub const GraphicsImage = struct {
    id: u32,
    generation: u64,
    width: u32,
    height: u32,
    rgba: []u8,
    backing: ?[]u8,
    texture: objc.Id = null,
    upload: ?*StagedUpload = null,
    staged: bool = false,

    fn take(image: protocol.Image, texture: objc.Id) GraphicsImage {
        return .{
            .id = image.id,
            .generation = image.generation,
            .width = image.width,
            .height = image.height,
            .rgba = image.rgba,
            .backing = image.backing,
            .texture = texture,
        };
    }

    fn protocolView(self: *const GraphicsImage) protocol.Image {
        return .{
            .id = self.id,
            .generation = self.generation,
            .width = self.width,
            .height = self.height,
            .rgba = self.rgba,
            .backing = null,
        };
    }

    pub fn deinit(self: *GraphicsImage, alloc: std.mem.Allocator) void {
        if (self.upload) |upload| upload.release();
        if (self.texture != null) objc.release(self.texture);
        if (self.backing) |bytes| alloc.free(bytes) else if (self.rgba.len != 0) alloc.free(self.rgba);
        self.* = undefined;
    }
};

pub const RefreshWorkerOptions = struct {
    callback_context: ?*anyopaque = null,
    callback: RefreshFn,
    image_context: ?*anyopaque = null,
    prepare_image: ?PrepareImageFn = null,
    prepare_staged_image: ?PrepareStagedImageFn = null,
};

pub const ResizeRequest = struct {
    cols: u16,
    rows: u16,
    pixel_width: u16,
    pixel_height: u16,
    generation: u64,
};

fn coalesceResize(slot: *?ResizeRequest, request: ResizeRequest) void {
    slot.* = request;
}

pub const SearchStatus = struct {
    total: u32,
    truncated: bool,
    selected_index: ?u32,
    pending: bool,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    client: *Client,
    id: u64,

    mutex: std.Io.Mutex = .init,
    render_snapshot: ?protocol.Snapshot = null,
    graphics_images: std.ArrayList(GraphicsImage) = .empty,
    grid_dirty: std.atomic.Value(bool) = .init(true),
    bell_pending: std.atomic.Value(bool) = .init(false),
    exited: std.atomic.Value(bool) = .init(false),
    working: std.atomic.Value(bool) = .init(false),
    attention_pending: std.atomic.Value(bool) = .init(false),
    metadata_dirty: std.atomic.Value(bool) = .init(true),
    visible: std.atomic.Value(bool) = .init(false),

    refresh_mutex: std.Io.Mutex = .init,
    refresh_condition: std.Io.Condition = .init,
    refresh_requested: bool = false,
    refresh_stopping: bool = false,
    pending_resize: ?ResizeRequest = null,
    refresh_thread: ?std.Thread = null,
    refresh_context: ?*anyopaque = null,
    refresh_fn: ?RefreshFn = null,
    image_context: ?*anyopaque = null,
    prepare_image_fn: ?PrepareImageFn = null,
    prepare_staged_image_fn: ?PrepareStagedImageFn = null,

    title_mutex: std.Io.Mutex = .init,
    title_buf: [512]u8 = undefined,
    title_len: usize = 0,
    title_dirty: bool = true,
    scroll_accum: f64 = 0,
    scroll_accum_x: f64 = 0,
    requested_cols: u16 = 0,
    requested_rows: u16 = 0,
    requested_pixel_width: u16 = 0,
    requested_pixel_height: u16 = 0,
    geometry_generation: std.atomic.Value(u64) = .init(0),
    applied_geometry_generation: std.atomic.Value(u64) = .init(0),
    render_snapshot_geometry_generation: u64 = 0,

    search_mutex: std.Io.Mutex = .init,
    search_query: [vt.search.max_query_bytes]u8 = undefined,
    search_query_len: usize = 0,
    search_current: ?vt.search.Match = null,
    search_generation: u64 = 0,
    search_operation: protocol.SearchOperation = .refresh,
    search_total: u32 = 0,
    search_truncated: bool = false,
    search_selected_index: ?u32 = null,
    search_pending: bool = false,

    pub fn create(
        gpa: std.mem.Allocator,
        io: std.Io,
        client: *Client,
        metadata: protocol.Metadata,
    ) !*Session {
        const self = try gpa.create(Session);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .client = client,
            .id = metadata.id,
        };
        self.applyMetadata(metadata);
        return self;
    }

    pub fn destroy(self: *Session) void {
        self.stopRefreshWorker();
        if (self.render_snapshot) |*snapshot| snapshot.deinit(self.gpa);
        for (self.graphics_images.items) |*image| image.deinit(self.gpa);
        self.graphics_images.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn startRefreshWorker(self: *Session, options: RefreshWorkerOptions) !void {
        if (self.refresh_thread != null) return;
        self.refresh_context = options.callback_context;
        self.refresh_fn = options.callback;
        self.image_context = options.image_context;
        self.prepare_image_fn = options.prepare_image;
        self.prepare_staged_image_fn = options.prepare_staged_image;
        self.refresh_thread = try std.Thread.spawn(.{}, refreshLoop, .{self});
    }

    pub fn requestRefresh(self: *Session) void {
        if (self.refresh_thread == null) return;
        self.refresh_mutex.lockUncancelable(self.io);
        defer self.refresh_mutex.unlock(self.io);
        if (self.refresh_stopping) return;
        self.refresh_requested = true;
        self.refresh_condition.signal(self.io);
    }

    pub fn requestResize(self: *Session, request: ResizeRequest) void {
        if (self.refresh_thread == null) return;
        self.refresh_mutex.lockUncancelable(self.io);
        defer self.refresh_mutex.unlock(self.io);
        if (self.refresh_stopping) return;
        coalesceResize(&self.pending_resize, request);
        self.refresh_requested = true;
        self.grid_dirty.store(true, .release);
        self.refresh_condition.signal(self.io);
    }

    fn stopRefreshWorker(self: *Session) void {
        const thread = self.refresh_thread orelse return;
        self.refresh_mutex.lockUncancelable(self.io);
        self.refresh_stopping = true;
        self.refresh_condition.signal(self.io);
        self.refresh_mutex.unlock(self.io);
        thread.join();
        self.refresh_thread = null;
        self.refresh_fn = null;
        self.refresh_context = null;
        self.prepare_image_fn = null;
        self.prepare_staged_image_fn = null;
        self.image_context = null;
    }

    pub fn setVisible(self: *Session, visible: bool) void {
        const was_visible = self.visible.swap(visible, .acq_rel);
        if (was_visible == visible) return;
        if (visible) self.grid_dirty.store(true, .release);
        self.requestRefresh();
    }

    fn refreshLoop(self: *Session) void {
        while (true) {
            self.refresh_mutex.lockUncancelable(self.io);
            while (!self.refresh_requested and self.pending_resize == null and
                !self.refresh_stopping)
            {
                self.refresh_condition.waitUncancelable(self.io, &self.refresh_mutex);
            }
            const resize = self.pending_resize;
            self.pending_resize = null;
            const stopping = self.refresh_stopping;
            self.refresh_requested = false;
            self.refresh_mutex.unlock(self.io);

            if (resize) |request| {
                self.client.resize(
                    self.id,
                    request.cols,
                    request.rows,
                    request.pixel_width,
                    request.pixel_height,
                ) catch {
                    self.grid_dirty.store(true, .release);
                    if (stopping) return;
                    continue;
                };
                self.applied_geometry_generation.store(request.generation, .release);
                self.grid_dirty.store(true, .release);
            }
            // A viewer may close immediately after its final frame change.
            // Persist that last geometry in the daemon before this worker exits.
            if (stopping) return;

            // Do not fetch a snapshot that is already known to be obsolete.
            self.refresh_mutex.lockUncancelable(self.io);
            const newer_resize_pending = self.pending_resize != null;
            self.refresh_mutex.unlock(self.io);
            if (newer_resize_pending) continue;

            if (!self.visible.load(.acquire)) {
                self.dropPreparedTextures();
                if (!self.metadata_dirty.load(.acquire)) continue;
            }
            self.refresh() catch continue;
            if (!self.visible.load(.acquire)) self.dropPreparedTextures();
            if (self.refresh_fn) |callback| callback(self.refresh_context, self.id);
        }
    }

    pub fn applyEvent(self: *Session, flags: protocol.EventFlags) void {
        if (flags.grid or flags.lifecycle) self.grid_dirty.store(true, .release);
        if (flags.metadata or flags.lifecycle) self.metadata_dirty.store(true, .release);
        if (flags.bell) self.bell_pending.store(true, .release);
    }

    pub fn refresh(self: *Session) !void {
        // Clear before requesting so an invalidation that races the snapshot
        // remains set instead of being accidentally erased afterward.
        self.grid_dirty.store(false, .release);
        self.metadata_dirty.store(false, .release);
        errdefer {
            self.grid_dirty.store(true, .release);
            self.metadata_dirty.store(true, .release);
        }
        var query_buf: [vt.search.max_query_bytes]u8 = undefined;
        const search_state = self.copySearchState(&query_buf);
        var search_result: ?protocol.SearchResult = null;
        errdefer if (search_result) |*result| result.deinit(self.gpa);
        if (search_state.query.len != 0) {
            search_result = try self.client.refreshSearch(
                self.id,
                search_state.operation,
                search_state.query,
                search_state.current,
            );
        }

        // Navigation may have changed the daemon-owned viewport, so capture
        // the authoritative cells only after the search response.
        const snapshot_geometry_generation = self.applied_geometry_generation.load(.acquire);
        var snapshot = try self.client.refreshSnapshot(self.id);
        errdefer snapshot.deinit(self.gpa);
        if (search_result) |*result| {
            if (self.searchStateIsCurrent(search_state.generation, search_state.query) and
                result.cols == snapshot.cols and result.rows == snapshot.rows and
                result.grid_epoch == snapshot.grid_epoch)
            {
                self.commitSearchResult(search_state.generation, search_state.query, result);
                snapshot.search_matches = result.matches;
                snapshot.search_selected = result.selected_cells;
                result.matches = &.{};
                result.selected_cells = &.{};
            }
            result.deinit(self.gpa);
            search_result = null;
        }

        var fetched: std.ArrayList(GraphicsImage) = .empty;
        defer {
            for (fetched.items) |*image| image.deinit(self.gpa);
            fetched.deinit(self.gpa);
        }
        for (snapshot.images) |image_ref| {
            if (self.hasCachedImage(image_ref)) continue;
            var image = try self.fetchImage(image_ref);
            fetched.append(self.gpa, image) catch |err| {
                image.deinit(self.gpa);
                return err;
            };
        }
        try self.prepareCachedImages(snapshot.images);
        try self.graphics_images.ensureUnusedCapacity(self.gpa, fetched.items.len);

        self.exited.store(snapshot.exited, .release);
        self.working.store(snapshot.working, .release);
        self.attention_pending.store(snapshot.attention, .release);
        self.setTitle(snapshot.title);

        self.mutex.lockUncancelable(self.io);
        var image_index = self.graphics_images.items.len;
        while (image_index > 0) {
            image_index -= 1;
            if (snapshotHasImage(snapshot.images, self.graphics_images.items[image_index])) continue;
            var removed = self.graphics_images.orderedRemove(image_index);
            removed.deinit(self.gpa);
        }
        for (fetched.items) |image| self.graphics_images.appendAssumeCapacity(image);
        fetched.items.len = 0;
        if (self.render_snapshot) |*old| old.deinit(self.gpa);
        self.render_snapshot = snapshot;
        self.render_snapshot_geometry_generation = snapshot_geometry_generation;
        self.mutex.unlock(self.io);
    }

    pub fn setSearch(
        self: *Session,
        query: []const u8,
        operation: protocol.SearchOperation,
    ) !void {
        try vt.search.validateQuery(query);
        self.search_mutex.lockUncancelable(self.io);
        const same_query = std.mem.eql(u8, self.search_query[0..self.search_query_len], query);
        if (!same_query or operation == .initial) self.search_current = null;
        @memcpy(self.search_query[0..query.len], query);
        self.search_query_len = query.len;
        self.search_generation +%= 1;
        self.search_operation = operation;
        self.search_pending = true;
        self.search_mutex.unlock(self.io);
        self.grid_dirty.store(true, .release);
        self.requestRefresh();
    }

    pub fn searchStatus(self: *Session) SearchStatus {
        self.search_mutex.lockUncancelable(self.io);
        defer self.search_mutex.unlock(self.io);
        return .{
            .total = self.search_total,
            .truncated = self.search_truncated,
            .selected_index = self.search_selected_index,
            .pending = self.search_pending,
        };
    }

    pub fn clearSearch(self: *Session) void {
        self.search_mutex.lockUncancelable(self.io);
        self.search_query_len = 0;
        self.search_current = null;
        self.search_generation +%= 1;
        self.search_operation = .refresh;
        self.search_total = 0;
        self.search_truncated = false;
        self.search_selected_index = null;
        self.search_pending = false;
        self.search_mutex.unlock(self.io);

        self.mutex.lockUncancelable(self.io);
        if (self.render_snapshot) |*snapshot| {
            if (snapshot.search_matches) |mask| self.gpa.free(mask);
            if (snapshot.search_selected) |mask| self.gpa.free(mask);
            snapshot.search_matches = null;
            snapshot.search_selected = null;
        }
        self.mutex.unlock(self.io);
    }

    const SearchState = struct {
        query: []const u8,
        current: ?vt.search.Match,
        generation: u64,
        operation: protocol.SearchOperation,
    };

    fn copySearchState(self: *Session, query_buf: []u8) SearchState {
        self.search_mutex.lockUncancelable(self.io);
        defer self.search_mutex.unlock(self.io);
        @memcpy(query_buf[0..self.search_query_len], self.search_query[0..self.search_query_len]);
        return .{
            .query = query_buf[0..self.search_query_len],
            .current = self.search_current,
            .generation = self.search_generation,
            .operation = self.search_operation,
        };
    }

    fn searchStateIsCurrent(self: *Session, generation: u64, query: []const u8) bool {
        self.search_mutex.lockUncancelable(self.io);
        defer self.search_mutex.unlock(self.io);
        return self.search_generation == generation and
            std.mem.eql(u8, self.search_query[0..self.search_query_len], query);
    }

    fn commitSearchResult(
        self: *Session,
        generation: u64,
        query: []const u8,
        result: *const protocol.SearchResult,
    ) void {
        self.search_mutex.lockUncancelable(self.io);
        defer self.search_mutex.unlock(self.io);
        if (self.search_generation == generation and
            std.mem.eql(u8, self.search_query[0..self.search_query_len], query))
        {
            self.search_current = result.selected;
            self.search_operation = .refresh;
            self.search_total = result.total;
            self.search_truncated = result.truncated;
            self.search_selected_index = result.selected_index;
            self.search_pending = false;
        }
    }

    fn fetchImage(self: *Session, image_ref: protocol.ImageRef) !GraphicsImage {
        if (self.visible.load(.acquire) and self.client.sharedGraphicsEnabled()) {
            var staged = self.client.refreshStagedImage(
                self.id,
                image_ref.id,
                image_ref.generation,
            ) catch |err| switch (err) {
                error.GraphicsBusy, error.RemoteError => return err,
                else => return self.fetchByteImage(image_ref),
            };
            var upload_owns_lease = false;
            defer if (!upload_owns_lease)
                self.client.releaseStagedImage(staged.staging_key) catch {};
            if (!imageMatchesRef(staged.metadata, image_ref)) return error.ProtocolMismatch;
            const prepare = self.prepare_staged_image_fn orelse return error.MissingImagePreparer;
            const upload = prepare(self.image_context, &staged) catch |err| {
                self.client.disableSharedGraphics();
                return err;
            };
            upload_owns_lease = true;
            return .{
                .id = staged.metadata.id,
                .generation = staged.metadata.generation,
                .width = staged.metadata.width,
                .height = staged.metadata.height,
                .rgba = &.{},
                .backing = null,
                .upload = upload,
                .staged = true,
            };
        }
        return self.fetchByteImage(image_ref);
    }

    fn fetchByteImage(self: *Session, image_ref: protocol.ImageRef) !GraphicsImage {
        var protocol_image = try self.client.refreshImageBytes(
            self.id,
            image_ref.id,
            image_ref.generation,
        );
        if (!imageMatchesRef(protocol_image, image_ref)) {
            protocol_image.deinit(self.gpa);
            return error.ProtocolMismatch;
        }
        const texture = self.prepareImageIfVisible(&protocol_image) catch |err| {
            protocol_image.deinit(self.gpa);
            return err;
        };
        return GraphicsImage.take(protocol_image, texture);
    }

    fn hasCachedImage(self: *Session, image_ref: protocol.ImageRef) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.graphics_images.items) |image| {
            if (imageMatchesRef(image, image_ref)) return true;
        }
        return false;
    }

    fn prepareImageIfVisible(self: *Session, image: *const protocol.Image) !objc.Id {
        if (!self.visible.load(.acquire)) return null;
        const prepare = self.prepare_image_fn orelse return null;
        return try prepare(self.image_context, image);
    }

    fn prepareCachedImages(self: *Session, refs: []const protocol.ImageRef) !void {
        if (!self.visible.load(.acquire)) return;
        const prepare = self.prepare_image_fn orelse return;
        for (self.graphics_images.items) |*image| {
            if (image.staged) continue;
            self.mutex.lockUncancelable(self.io);
            if (image.texture != null or !snapshotHasImage(refs, image.*)) {
                self.mutex.unlock(self.io);
                continue;
            }
            const view = image.protocolView();
            self.mutex.unlock(self.io);
            const texture = try prepare(self.image_context, &view);
            self.mutex.lockUncancelable(self.io);
            if (image.texture == null) {
                image.texture = texture;
            } else {
                objc.release(texture);
            }
            self.mutex.unlock(self.io);
        }
    }

    fn dropPreparedTextures(self: *Session) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var index = self.graphics_images.items.len;
        while (index > 0) {
            index -= 1;
            const image = &self.graphics_images.items[index];
            if (image.staged) {
                var removed = self.graphics_images.orderedRemove(index);
                removed.deinit(self.gpa);
                continue;
            }
            if (image.texture == null) continue;
            objc.release(image.texture);
            image.texture = null;
        }
    }

    pub fn discardFailedStagedImages(self: *Session) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var removed_any = false;
        var index = self.graphics_images.items.len;
        while (index > 0) {
            index -= 1;
            const upload = self.graphics_images.items[index].upload orelse continue;
            if (upload.currentState() != .failed) continue;
            var removed = self.graphics_images.orderedRemove(index);
            removed.deinit(self.gpa);
            removed_any = true;
        }
        return removed_any;
    }

    pub fn needsAttention(self: *const Session) bool {
        return self.attention_pending.load(.acquire);
    }

    pub fn requestTitleRefresh(self: *Session) void {
        self.title_mutex.lockUncancelable(self.io);
        defer self.title_mutex.unlock(self.io);
        self.title_dirty = true;
    }

    pub fn copyTitle(self: *Session, out: []u8, only_dirty: bool) ?[]const u8 {
        self.title_mutex.lockUncancelable(self.io);
        defer self.title_mutex.unlock(self.io);
        if (only_dirty and !self.title_dirty) return null;
        self.title_dirty = false;
        const n = @min(out.len, self.title_len);
        @memcpy(out[0..n], self.title_buf[0..n]);
        return out[0..n];
    }

    pub fn copyTitleSnapshot(self: *Session, out: []u8) []const u8 {
        self.title_mutex.lockUncancelable(self.io);
        defer self.title_mutex.unlock(self.io);
        const n = @min(out.len, self.title_len);
        @memcpy(out[0..n], self.title_buf[0..n]);
        return out[0..n];
    }

    fn applyMetadata(self: *Session, metadata: protocol.Metadata) void {
        self.exited.store(metadata.exited, .release);
        self.working.store(metadata.working, .release);
        self.attention_pending.store(metadata.attention, .release);
        self.setTitle(metadata.title);
    }

    fn setTitle(self: *Session, title: []const u8) void {
        self.title_mutex.lockUncancelable(self.io);
        defer self.title_mutex.unlock(self.io);
        self.title_len = title_mod.sanitizeUtf8Into(title, &self.title_buf).len;
        self.title_dirty = true;
    }
};

fn imageMatchesRef(image: anytype, image_ref: protocol.ImageRef) bool {
    return image.id == image_ref.id and
        image.generation == image_ref.generation and
        image.width == image_ref.width and
        image.height == image_ref.height;
}

fn snapshotHasImage(refs: []const protocol.ImageRef, image: anytype) bool {
    for (refs) |image_ref| if (imageMatchesRef(image, image_ref)) return true;
    return false;
}

fn graphicsReleaseCallback(
    context: ?*anyopaque,
    record: staged_upload.ReleaseRecord,
) void {
    const client: *Client = @ptrCast(@alignCast(context.?));
    client.enqueueGraphicsRelease(record);
}

pub const SessionManager = session_mod.Manager(Session);

const RequestLane = enum {
    interactive,
    refresh,
};

const MappedGraphicsSlot = struct {
    mapping: ?*anyopaque = null,
    capacity: usize = 0,

    fn deinit(self: *MappedGraphicsSlot) void {
        if (self.mapping) |mapping| _ = c.munmap(@ptrCast(@alignCast(mapping)), self.capacity);
        self.* = .{};
    }
};

const graphics_release_capacity = 3;

const GraphicsReleaseQueue = struct {
    records: [graphics_release_capacity]staged_upload.ReleaseRecord = undefined,
    len: usize = 0,
    overflowed: bool = false,
};

pub const DaemonIdentity = struct {
    lifecycle_supported: bool = false,
    product_version: [lifecycle.max_product_version]u8 = undefined,
    product_version_len: u8 = 0,
    reported_sessions: u32 = 0,
    reported_attach_connections: u32 = 0,

    pub fn versionText(self: *const DaemonIdentity) ?[]const u8 {
        if (!self.lifecycle_supported) return null;
        return self.product_version[0..self.product_version_len];
    }
};

pub const UpgradeRequiredInfo = struct {
    identity: DaemonIdentity,
    dialects: [lifecycle.max_dialects]u16,
    dialect_count: u8,

    pub fn supportedDialects(self: *const UpgradeRequiredInfo) []const u16 {
        return self.dialects[0..self.dialect_count];
    }
};

pub fn inspectUpgradeRequiredDaemon(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) !UpgradeRequiredInfo {
    const path = try protocol.socketPath(gpa, env);
    defer gpa.free(path);
    const fd = try connect(path, io);
    defer _ = c.close(fd);
    const status = try queryLifecycle(fd, gpa);
    return .{
        .identity = status.identity,
        .dialects = status.dialects,
        .dialect_count = status.dialect_count,
    };
}

pub fn terminateUpgradeRequiredDaemon(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) !void {
    const path = try protocol.socketPath(gpa, env);
    defer gpa.free(path);
    const fd = try connect(path, io);
    defer _ = c.close(fd);
    const pid = try verifiedDaemonPeerPid(fd);
    try lifecycle.writeFrame(fd, .terminate_all, &.{});
    var response = try lifecycle.readFrame(fd, gpa);
    defer response.deinit(gpa);
    if (response.tag != .ok or response.payload.len != 0) return error.ProtocolMismatch;
    try Client.waitForProcessExit(io, pid);
}

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    socket_path: []u8,
    dialect: selected_protocol.Dialect,
    daemon_identity: DaemonIdentity,
    command_fd: c.fd_t,
    command_mutex: std.Io.Mutex = .init,
    refresh_fd: c.fd_t,
    refresh_mutex: std.Io.Mutex = .init,
    shared_graphics: bool = false,
    graphics_row_alignment: u32 = 0,
    graphics_epoch: u64 = 0,
    graphics_slots: [3]MappedGraphicsSlot = [_]MappedGraphicsSlot{.{}} ** 3,
    graphics_active_leases: usize = 0,
    graphics_cleanup_pending: bool = false,
    graphics_disable_requested: std.atomic.Value(bool) = .init(false),
    graphics_release_mutex: std.Io.Mutex = .init,
    graphics_release_condition: std.Io.Condition = .init,
    graphics_release_queue: GraphicsReleaseQueue = .{},
    graphics_release_stopping: bool = false,
    graphics_release_thread: ?std.Thread = null,
    event_fd: std.atomic.Value(c.fd_t) = .init(-1),
    event_thread: ?std.Thread = null,
    event_callback: ?EventFn = null,
    event_context: ?*anyopaque = null,
    stopping: std.atomic.Value(bool) = .init(false),
    disconnected: std.atomic.Value(bool) = .init(false),

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        env: *const std.process.Environ.Map,
    ) !Client {
        const socket_path = try protocol.socketPath(gpa, env);
        errdefer gpa.free(socket_path);
        var daemon_identity: DaemonIdentity = .{};
        const negotiated = if (connect(socket_path, io) catch null) |lifecycle_fd| blk: {
            const status = queryLifecycle(lifecycle_fd, gpa) catch {
                _ = c.close(lifecycle_fd);
                const attach_fd = try connect(socket_path, io);
                break :blk try negotiateConnected(socket_path, io, gpa, attach_fd);
            };
            _ = c.close(lifecycle_fd);
            daemon_identity = status.identity;
            const dialect = selected_protocol.bestSupported(status.dialects[0..status.dialect_count]) orelse
                return error.DaemonUpgradeRequired;
            if (dialect.isCompatibility() and status.identity.reported_sessions == 0 and
                try stopIdleDaemon(socket_path, io, gpa))
            {
                daemon_identity = .{};
                break :blk try spawnAndConnectCurrent(gpa, io, env, socket_path);
            }
            const attach_fd = try connect(socket_path, io);
            errdefer _ = c.close(attach_fd);
            try probeDialect(attach_fd, dialect, gpa);
            break :blk NegotiatedConnection{ .fd = attach_fd, .dialect = dialect };
        } else try spawnAndConnectCurrent(gpa, io, env, socket_path);
        errdefer _ = c.close(negotiated.fd);
        if (!daemon_identity.lifecycle_supported) {
            if (connect(socket_path, io)) |lifecycle_fd| {
                defer _ = c.close(lifecycle_fd);
                if (queryLifecycle(lifecycle_fd, gpa)) |status| {
                    daemon_identity = status.identity;
                } else |_| {}
            } else |_| {}
        }
        const refresh_fd = try connect(socket_path, io);
        return .{
            .gpa = gpa,
            .io = io,
            .socket_path = socket_path,
            .dialect = negotiated.dialect,
            .daemon_identity = daemon_identity,
            .command_fd = negotiated.fd,
            .refresh_fd = refresh_fd,
        };
    }

    pub fn deinit(self: *Client) void {
        self.stopEvents();
        self.stopGraphicsReleaseWorker();
        self.refresh_mutex.lockUncancelable(self.io);
        for (&self.graphics_slots) |*slot| slot.deinit();
        _ = c.close(self.refresh_fd);
        self.refresh_mutex.unlock(self.io);
        _ = c.close(self.command_fd);
        self.gpa.free(self.socket_path);
        self.* = undefined;
    }

    /// Stop the invalidation lane before viewer-owned session caches are
    /// destroyed during an orderly app termination.
    pub fn stopEvents(self: *Client) void {
        self.stopping.store(true, .release);
        const event_fd = self.event_fd.load(.acquire);
        if (event_fd >= 0) _ = c.shutdown(event_fd, c.SHUT.RDWR);
        if (self.event_thread) |thread| thread.join();
        self.event_thread = null;
        const final_event_fd = self.event_fd.swap(-1, .acq_rel);
        if (final_event_fd >= 0) _ = c.close(final_event_fd);
        self.event_callback = null;
        self.event_context = null;
    }

    pub fn isDisconnected(self: *const Client) bool {
        return self.disconnected.load(.acquire);
    }

    pub fn attachDialect(self: *const Client) u16 {
        return self.dialect.number();
    }

    pub fn updatePending(self: *const Client) bool {
        return self.dialect.isCompatibility();
    }

    pub fn supportsSearch(self: *const Client) bool {
        return self.dialect.supportsSearch();
    }

    pub fn supportsCreateBeside(self: *const Client) bool {
        return self.dialect.supportsCreateBeside();
    }

    pub fn supportsPersistentPairZoom(self: *const Client) bool {
        return self.dialect.supportsPersistentPairZoom();
    }

    pub fn daemonIdentity(self: *const Client) *const DaemonIdentity {
        return &self.daemon_identity;
    }

    pub fn stopDaemonIfIdle(self: *Client) !bool {
        if (!self.daemon_identity.lifecycle_supported) return error.LifecycleUnavailable;
        const fd = try connect(self.socket_path, self.io);
        defer _ = c.close(fd);
        try lifecycle.writeFrame(fd, .stop_if_idle, &.{});
        var response = try lifecycle.readFrame(fd, self.gpa);
        defer response.deinit(self.gpa);
        if (response.payload.len != 0) return error.ProtocolMismatch;
        return switch (response.tag) {
            .ok => true,
            .busy => false,
            else => error.ProtocolMismatch,
        };
    }

    pub fn terminateDaemon(self: *Client) !void {
        if (!self.daemon_identity.lifecycle_supported) return error.LifecycleUnavailable;
        const pid = try verifiedDaemonPeerPid(self.command_fd);
        const fd = try connect(self.socket_path, self.io);
        defer _ = c.close(fd);
        try lifecycle.writeFrame(fd, .terminate_all, &.{});
        var response = try lifecycle.readFrame(fd, self.gpa);
        defer response.deinit(self.gpa);
        if (response.tag != .ok or response.payload.len != 0) return error.ProtocolMismatch;
        try waitForProcessExit(self.io, pid);
    }

    /// Recovery for a retained pre-BTL1 daemon. Authority comes from the
    /// connected Unix peer, never a pid file or process-name search.
    pub fn terminateVerifiedLegacyDaemon(self: *Client) !void {
        if (self.daemon_identity.lifecycle_supported) return error.NotLegacyDaemon;
        const pid = try verifiedDaemonPeerPid(self.command_fd);
        if (c.kill(pid, .TERM) < 0) return error.DaemonTerminateFailed;
        try waitForProcessExit(self.io, pid);
    }

    fn waitForProcessExit(io: std.Io, pid: c.pid_t) !void {
        var attempts: usize = 0;
        while (attempts < 200) : (attempts += 1) {
            const rc = c.kill(pid, @enumFromInt(0));
            if (rc < 0 and c.errno(rc) == .SRCH) return;
            try io.sleep(.fromMilliseconds(20), .awake);
        }
        return error.DaemonTerminateTimeout;
    }

    pub fn enableSharedGraphics(self: *Client, row_alignment: usize) void {
        const page_size_signed = c.sysconf(@intFromEnum(c._SC.PAGESIZE));
        if (row_alignment == 0 or row_alignment > std.math.maxInt(u32) or
            page_size_signed <= 0 or row_alignment > page_size_signed or
            !std.math.isPowerOfTwo(row_alignment)) return;
        const probe_fd = connect(self.socket_path, self.io) catch return;
        errdefer _ = c.close(probe_fd);
        selected_protocol.writeFrame(probe_fd, self.dialect, .graphics_attach, &.{}) catch return;
        var response = selected_protocol.readFrame(probe_fd, self.dialect, self.gpa) catch return;
        defer response.deinit(self.gpa);
        if (response.tag != .graphics_ready or response.payload.len != 0) return;

        self.refresh_mutex.lockUncancelable(self.io);
        const old_fd = self.refresh_fd;
        self.refresh_fd = probe_fd;
        self.graphics_row_alignment = @intCast(row_alignment);
        self.graphics_epoch +%= 1;
        if (self.graphics_epoch == 0) self.graphics_epoch = 1;
        self.graphics_disable_requested.store(false, .release);
        self.shared_graphics = true;
        self.refresh_mutex.unlock(self.io);
        _ = c.close(old_fd);
    }

    pub fn sharedGraphicsEnabled(self: *Client) bool {
        if (self.graphics_disable_requested.load(.acquire)) return false;
        self.refresh_mutex.lockUncancelable(self.io);
        defer self.refresh_mutex.unlock(self.io);
        return self.shared_graphics;
    }

    fn disableSharedGraphics(self: *Client) void {
        self.refresh_mutex.lockUncancelable(self.io);
        defer self.refresh_mutex.unlock(self.io);
        if (self.shared_graphics) self.disableSharedGraphicsLocked();
    }

    pub fn startGraphicsReleaseWorker(self: *Client) !void {
        if (self.graphics_release_thread != null) return;
        self.graphics_release_stopping = false;
        self.graphics_release_thread = try std.Thread.spawn(.{}, graphicsReleaseLoop, .{self});
    }

    fn stopGraphicsReleaseWorker(self: *Client) void {
        const thread = self.graphics_release_thread orelse return;
        self.graphics_release_mutex.lockUncancelable(self.io);
        self.graphics_release_stopping = true;
        self.graphics_release_condition.signal(self.io);
        self.graphics_release_mutex.unlock(self.io);
        thread.join();
        self.graphics_release_thread = null;
    }

    fn enqueueGraphicsRelease(self: *Client, record: staged_upload.ReleaseRecord) void {
        self.graphics_release_mutex.lockUncancelable(self.io);
        defer self.graphics_release_mutex.unlock(self.io);
        if (self.graphics_release_stopping) return;
        if (record.disable_after_release)
            self.graphics_disable_requested.store(true, .release);
        if (self.graphics_release_queue.len == graphics_release_capacity) {
            // Three live daemon leases are the hard upper bound. Reaching a
            // fourth completion record means ownership bookkeeping is broken;
            // close the lane on the worker rather than dropping a capability.
            self.graphics_release_queue.overflowed = true;
            self.graphics_disable_requested.store(true, .release);
        } else {
            self.graphics_release_queue.records[self.graphics_release_queue.len] = record;
            self.graphics_release_queue.len += 1;
        }
        self.graphics_release_condition.signal(self.io);
    }

    fn graphicsReleaseLoop(self: *Client) void {
        while (true) {
            self.graphics_release_mutex.lockUncancelable(self.io);
            while (self.graphics_release_queue.len == 0 and
                !self.graphics_release_queue.overflowed and
                !self.graphics_release_stopping)
            {
                self.graphics_release_condition.waitUncancelable(
                    self.io,
                    &self.graphics_release_mutex,
                );
            }
            if (self.graphics_release_queue.overflowed) {
                self.graphics_release_queue = .{};
                self.graphics_release_mutex.unlock(self.io);
                self.refresh_mutex.lockUncancelable(self.io);
                if (self.shared_graphics) self.disableSharedGraphicsLocked();
                self.graphics_active_leases = 0;
                self.cleanupGraphicsMappingsLocked();
                self.refresh_mutex.unlock(self.io);
                continue;
            }
            if (self.graphics_release_queue.len == 0 and self.graphics_release_stopping) {
                self.graphics_release_mutex.unlock(self.io);
                return;
            }
            const record = self.graphics_release_queue.records[0];
            if (self.graphics_release_queue.len > 1) {
                std.mem.copyForwards(
                    staged_upload.ReleaseRecord,
                    self.graphics_release_queue.records[0 .. self.graphics_release_queue.len - 1],
                    self.graphics_release_queue.records[1..self.graphics_release_queue.len],
                );
            }
            self.graphics_release_queue.len -= 1;
            self.graphics_release_mutex.unlock(self.io);

            self.releaseStagedImage(record.key) catch {};
            if (record.disable_after_release) self.disableSharedGraphics();
        }
    }

    pub fn startEvents(self: *Client, context: ?*anyopaque, callback: EventFn) !void {
        if (self.event_thread != null) return;
        const fd = try subscribeEvent(self.socket_path, self.io, self.gpa, self.dialect);
        errdefer _ = c.close(fd);
        self.event_fd.store(fd, .release);
        errdefer self.event_fd.store(-1, .release);
        self.event_context = context;
        self.event_callback = callback;
        self.event_thread = try std.Thread.spawn(.{}, eventLoop, .{self});
    }

    pub fn list(self: *Client) ![]protocol.Metadata {
        const registry = try self.listRegistry();
        self.gpa.free(registry.display_items);
        return registry.sessions;
    }

    pub fn listRegistry(self: *Client) !protocol.RegistrySnapshot {
        var response = try self.request(.list, &.{});
        defer response.deinit(self.gpa);
        try expectTag(response.tag, .session_list);
        var dec: protocol.Decoder = .{ .bytes = response.payload };
        return selected_protocol.decodeRegistry(self.dialect, &dec, self.gpa);
    }

    pub fn create(self: *Client, cols: u16, rows: u16, cwd: ?[]const u8) !protocol.Metadata {
        var enc = protocol.Encoder.init(self.gpa);
        defer enc.deinit();
        try protocol.encodeCreateRequest(&enc, .{ .cols = cols, .rows = rows, .cwd = cwd });
        var response = try self.request(.create, enc.slice());
        defer response.deinit(self.gpa);
        try expectTag(response.tag, .metadata);
        var dec: protocol.Decoder = .{ .bytes = response.payload };
        const metadata = try selected_protocol.decodeMetadata(self.dialect, &dec, self.gpa);
        errdefer {
            var owned = metadata;
            owned.deinit(self.gpa);
        }
        try dec.finish();
        return metadata;
    }

    pub fn createBeside(
        self: *Client,
        existing_id: u64,
        cols: u16,
        rows: u16,
        cwd: ?[]const u8,
    ) !protocol.Metadata {
        if (!self.dialect.supportsCreateBeside()) return error.FeatureUnavailable;
        var enc = protocol.Encoder.init(self.gpa);
        defer enc.deinit();
        try protocol.encodeCreateBesideRequest(&enc, .{
            .existing_id = existing_id,
            .create = .{ .cols = cols, .rows = rows, .cwd = cwd },
        });
        var response = try self.request(.create_beside, enc.slice());
        defer response.deinit(self.gpa);
        try expectTag(response.tag, .metadata);
        var dec: protocol.Decoder = .{ .bytes = response.payload };
        const metadata = try selected_protocol.decodeMetadata(self.dialect, &dec, self.gpa);
        errdefer {
            var owned = metadata;
            owned.deinit(self.gpa);
        }
        try dec.finish();
        return metadata;
    }

    pub fn snapshot(self: *Client, id: u64) !protocol.Snapshot {
        return self.snapshotOn(.interactive, id);
    }

    pub fn search(
        self: *Client,
        id: u64,
        operation: protocol.SearchOperation,
        query: []const u8,
        current: ?vt.search.Match,
    ) !protocol.SearchResult {
        return self.searchOn(.interactive, id, operation, query, current);
    }

    fn refreshSearch(
        self: *Client,
        id: u64,
        operation: protocol.SearchOperation,
        query: []const u8,
        current: ?vt.search.Match,
    ) !protocol.SearchResult {
        return self.searchOn(.refresh, id, operation, query, current);
    }

    fn searchOn(
        self: *Client,
        lane: RequestLane,
        id: u64,
        operation: protocol.SearchOperation,
        query: []const u8,
        current: ?vt.search.Match,
    ) !protocol.SearchResult {
        if (!self.dialect.supportsSearch()) return error.FeatureUnavailable;
        var enc = protocol.Encoder.init(self.gpa);
        defer enc.deinit();
        try protocol.encodeSearchRequest(&enc, .{
            .id = id,
            .operation = operation,
            .query = query,
            .current = current,
        });
        var response = try self.requestLane(lane, .search, enc.slice());
        defer response.deinit(self.gpa);
        try expectTag(response.tag, .search_result);
        var dec: protocol.Decoder = .{ .bytes = response.payload };
        var result = try protocol.SearchResult.decode(&dec, self.gpa);
        errdefer result.deinit(self.gpa);
        try dec.finish();
        return result;
    }

    fn refreshSnapshot(self: *Client, id: u64) !protocol.Snapshot {
        return self.snapshotOn(.refresh, id);
    }

    fn snapshotOn(self: *Client, lane: RequestLane, id: u64) !protocol.Snapshot {
        var enc = protocol.Encoder.init(self.gpa);
        defer enc.deinit();
        try enc.int(u64, id);
        var response = try self.requestLane(lane, .snapshot, enc.slice());
        defer response.deinit(self.gpa);
        try expectTag(response.tag, .snapshot_result);
        var dec: protocol.Decoder = .{ .bytes = response.payload };
        var result = try selected_protocol.decodeSnapshot(self.dialect, &dec, self.gpa);
        errdefer result.deinit(self.gpa);
        try dec.finish();
        return result;
    }

    pub fn image(self: *Client, id: u64, image_id: u32, generation: u64) !protocol.Image {
        return self.imageOn(.interactive, id, image_id, generation);
    }

    fn refreshImageBytes(self: *Client, id: u64, image_id: u32, generation: u64) !protocol.Image {
        return self.imageOn(.refresh, id, image_id, generation);
    }

    fn refreshStagedImage(
        self: *Client,
        id: u64,
        image_id: u32,
        generation: u64,
    ) !StagedFetch {
        self.refresh_mutex.lockUncancelable(self.io);
        defer self.refresh_mutex.unlock(self.io);
        if (!self.shared_graphics or self.graphics_disable_requested.load(.acquire))
            return error.SharedGraphicsUnavailable;
        var enc = protocol.Encoder.init(self.gpa);
        defer enc.deinit();
        try enc.int(u64, id);
        try enc.int(u32, image_id);
        try enc.int(u64, generation);
        try enc.int(u32, self.graphics_row_alignment);
        selected_protocol.writeFrame(self.refresh_fd, self.dialect, .stage_image, enc.slice()) catch |err| {
            self.disableSharedGraphicsLocked();
            return err;
        };
        var received_fd = protocol.readDescriptorEnvelope(self.refresh_fd) catch |err| {
            self.disableSharedGraphicsLocked();
            return err;
        };
        errdefer {
            if (received_fd) |received| _ = c.close(received);
        }
        var response = selected_protocol.readFrame(self.refresh_fd, self.dialect, self.gpa) catch |err| {
            self.disableSharedGraphicsLocked();
            return err;
        };
        defer response.deinit(self.gpa);
        if (response.tag == .protocol_error) {
            if (received_fd != null) {
                self.disableSharedGraphicsLocked();
                return error.ProtocolMismatch;
            }
            return error.RemoteError;
        }
        if (response.tag == .graphics_busy) {
            if (received_fd != null or response.payload.len != 0) {
                self.disableSharedGraphicsLocked();
                return error.ProtocolMismatch;
            }
            return error.GraphicsBusy;
        }
        if (response.tag != .staged_image) {
            self.disableSharedGraphicsLocked();
            return error.ProtocolMismatch;
        }
        var dec: protocol.Decoder = .{ .bytes = response.payload };
        const metadata = protocol.decodeStagedImage(&dec) catch |err| {
            self.disableSharedGraphicsLocked();
            return err;
        };
        dec.finish() catch |err| {
            self.disableSharedGraphicsLocked();
            return err;
        };
        const slot = &self.graphics_slots[metadata.slot_index];
        if (received_fd) |new_fd| {
            var stat: c.Stat = undefined;
            while (c.fstat(new_fd, &stat) < 0) {
                if (c.errno(-1) == .INTR) continue;
                self.disableSharedGraphicsLocked();
                return error.InvalidStagingDescriptor;
            }
            if (stat.size <= 0 or @as(u64, @intCast(stat.size)) < metadata.byte_length or
                @as(u64, @intCast(stat.size)) > protocol.max_payload)
            {
                self.disableSharedGraphicsLocked();
                return error.InvalidStagingDescriptor;
            }
            const capacity: usize = @intCast(stat.size);
            const mapping = c.mmap(
                null,
                capacity,
                c.PROT{ .READ = true },
                c.MAP{ .TYPE = .SHARED },
                new_fd,
                0,
            );
            if (mapping == c.MAP_FAILED) {
                self.disableSharedGraphicsLocked();
                return error.InvalidStagingDescriptor;
            }
            slot.deinit();
            slot.* = .{ .mapping = mapping, .capacity = capacity };
            _ = c.close(new_fd);
            received_fd = null;
        } else if (slot.mapping == null or slot.capacity < metadata.byte_length) {
            self.disableSharedGraphicsLocked();
            return error.MissingStagingDescriptor;
        }
        self.graphics_active_leases += 1;
        return .{
            .session_id = id,
            .metadata = metadata,
            .mapping = slot.mapping.?,
            .mapping_length = slot.capacity,
            .staging_key = .{
                .connection_epoch = self.graphics_epoch,
                .slot_index = metadata.slot_index,
                .lease_token = metadata.lease_token,
            },
            .release_context = self,
            .release_fn = graphicsReleaseCallback,
        };
    }

    fn releaseStagedImage(self: *Client, key: staged_upload.StagingKey) !void {
        self.refresh_mutex.lockUncancelable(self.io);
        defer {
            std.debug.assert(self.graphics_active_leases > 0);
            self.graphics_active_leases -= 1;
            self.cleanupGraphicsMappingsLocked();
            self.refresh_mutex.unlock(self.io);
        }
        if (!self.shared_graphics or key.connection_epoch != self.graphics_epoch) return;
        var enc = protocol.Encoder.init(self.gpa);
        defer enc.deinit();
        try enc.byte(key.slot_index);
        try enc.int(u64, key.lease_token);
        selected_protocol.writeFrame(self.refresh_fd, self.dialect, .release_staged_image, enc.slice()) catch |err| {
            self.disableSharedGraphicsLocked();
            return err;
        };
        var response = selected_protocol.readFrame(self.refresh_fd, self.dialect, self.gpa) catch |err| {
            self.disableSharedGraphicsLocked();
            return err;
        };
        defer response.deinit(self.gpa);
        if (response.tag != .ok or response.payload.len != 0) {
            self.disableSharedGraphicsLocked();
            return error.ProtocolMismatch;
        }
    }

    fn disableSharedGraphicsLocked(self: *Client) void {
        self.shared_graphics = false;
        self.graphics_row_alignment = 0;
        self.graphics_epoch +%= 1;
        if (self.graphics_epoch == 0) self.graphics_epoch = 1;
        _ = c.close(self.refresh_fd);
        self.graphics_cleanup_pending = true;
        self.cleanupGraphicsMappingsLocked();
        self.refresh_fd = connect(self.socket_path, self.io) catch {
            self.refresh_fd = -1;
            self.markDisconnected();
            return;
        };
    }

    fn cleanupGraphicsMappingsLocked(self: *Client) void {
        if (!self.graphics_cleanup_pending or self.graphics_active_leases != 0) return;
        for (&self.graphics_slots) |*slot| slot.deinit();
        self.graphics_cleanup_pending = false;
    }

    fn imageOn(
        self: *Client,
        lane: RequestLane,
        id: u64,
        image_id: u32,
        generation: u64,
    ) !protocol.Image {
        var enc = protocol.Encoder.init(self.gpa);
        defer enc.deinit();
        try enc.int(u64, id);
        try enc.int(u32, image_id);
        try enc.int(u64, generation);
        var response = try self.requestLane(lane, .image, enc.slice());
        defer response.deinit(self.gpa);
        try expectTag(response.tag, .image_result);
        return try protocol.decodeImageFrame(&response);
    }

    pub fn writeInput(self: *Client, id: u64, bytes: []const u8) !void {
        var enc = protocol.Encoder.init(self.gpa);
        defer enc.deinit();
        try enc.int(u64, id);
        try enc.bytes(bytes);
        try self.requestOk(.write, enc.slice());
    }

    pub fn paste(self: *Client, id: u64, bytes: []const u8) !void {
        var enc = protocol.Encoder.init(self.gpa);
        defer enc.deinit();
        try enc.int(u64, id);
        try enc.bytes(bytes);
        try self.requestOk(.paste, enc.slice());
    }

    pub fn resize(self: *Client, id: u64, cols: u16, rows: u16, px_w: u16, px_h: u16) !void {
        var enc = protocol.Encoder.init(self.gpa);
        defer enc.deinit();
        try enc.int(u64, id);
        try enc.int(u16, cols);
        try enc.int(u16, rows);
        try enc.int(u16, px_w);
        try enc.int(u16, px_h);
        try self.requestOk(.resize, enc.slice());
    }

    pub fn setFocus(self: *Client, id: u64, focused: bool) !void {
        var enc = protocol.Encoder.init(self.gpa);
        defer enc.deinit();
        try enc.int(u64, id);
        try enc.boolean(focused);
        try self.requestOk(.focus, enc.slice());
    }

    pub fn mouseEvent(self: *Client, id: u64, event: vt.mouse.Event) !bool {
        var enc = protocol.Encoder.init(self.gpa);
        defer enc.deinit();
        try enc.int(u64, id);
        try selected_protocol.encodeMouseEvent(self.dialect, &enc, event);
        var response = try self.request(.mouse, enc.slice());
        defer response.deinit(self.gpa);
        try expectTag(response.tag, .bool_result);
        if (response.payload.len != 1) return error.ProtocolMismatch;
        return switch (response.payload[0]) {
            0 => false,
            1 => true,
            else => error.ProtocolMismatch,
        };
    }

    pub fn keyEvent(self: *Client, id: u64, event: vt.keyboard.Event) !void {
        var enc = protocol.Encoder.init(self.gpa);
        defer enc.deinit();
        try enc.int(u64, id);
        switch (try selected_protocol.encodeKeyEvent(self.dialect, &enc, event)) {
            .semantic => try self.requestOk(.key, enc.slice()),
            .raw => |bytes| try self.writeInput(id, bytes),
            .ignored => {},
        }
    }

    pub fn closeSession(self: *Client, id: u64) !void {
        try self.idCommand(.close, id);
    }

    pub fn pairSessions(self: *Client, left: u64, right: u64) !void {
        var enc = protocol.Encoder.init(self.gpa);
        defer enc.deinit();
        try enc.int(u64, left);
        try enc.int(u64, right);
        try self.requestOk(.pair, enc.slice());
    }

    pub fn separateSessions(self: *Client, member: u64) !void {
        try self.idCommand(.separate, member);
    }

    pub fn rememberPairFocus(self: *Client, member: u64) !void {
        try self.idCommand(.display_focus, member);
    }

    pub fn setPairRatio(self: *Client, member: u64, ratio: u16) !void {
        var enc = protocol.Encoder.init(self.gpa);
        defer enc.deinit();
        try enc.int(u64, member);
        try enc.int(u16, ratio);
        try self.requestOk(.display_ratio, enc.slice());
    }

    pub fn setPairZoom(self: *Client, member: u64, zoomed: bool) !void {
        if (!self.dialect.supportsPersistentPairZoom()) return error.FeatureUnavailable;
        var enc = protocol.Encoder.init(self.gpa);
        defer enc.deinit();
        try enc.int(u64, member);
        try enc.boolean(zoomed);
        try self.requestOk(.display_zoom, enc.slice());
    }

    pub fn moveDisplayItem(self: *Client, member: u64, destination: u32) !void {
        var enc = protocol.Encoder.init(self.gpa);
        defer enc.deinit();
        try enc.int(u64, member);
        try enc.int(u32, destination);
        try self.requestOk(.display_move, enc.slice());
    }

    pub fn swapPairSides(self: *Client, member: u64) !void {
        try self.idCommand(.display_swap, member);
    }

    pub fn transferPairMember(
        self: *Client,
        member: u64,
        target: u64,
        member_on_left: bool,
    ) !void {
        var enc = protocol.Encoder.init(self.gpa);
        defer enc.deinit();
        try enc.int(u64, member);
        try enc.int(u64, target);
        try enc.boolean(member_on_left);
        try self.requestOk(.display_transfer, enc.slice());
    }

    pub fn extractPairMember(self: *Client, member: u64, destination: u32) !void {
        var enc = protocol.Encoder.init(self.gpa);
        defer enc.deinit();
        try enc.int(u64, member);
        try enc.int(u32, destination);
        try self.requestOk(.display_extract, enc.slice());
    }

    pub fn hasForegroundJob(self: *Client, id: u64) !bool {
        var response = try self.idRequest(.foreground, id);
        defer response.deinit(self.gpa);
        try expectTag(response.tag, .bool_result);
        if (response.payload.len != 1) return error.ProtocolMismatch;
        return switch (response.payload[0]) {
            0 => false,
            1 => true,
            else => error.ProtocolMismatch,
        };
    }

    pub fn clearScrollback(self: *Client, id: u64) !void {
        try self.idCommand(.clear_scrollback, id);
    }

    pub fn forceEndSynchronizedOutput(self: *Client, id: u64) !void {
        try self.idCommand(.force_sync, id);
    }

    pub fn scroll(self: *Client, id: u64, delta: i64) !bool {
        var enc = protocol.Encoder.init(self.gpa);
        defer enc.deinit();
        try enc.int(u64, id);
        try enc.int(u64, @bitCast(delta));
        var response = try self.request(.scroll, enc.slice());
        defer response.deinit(self.gpa);
        try expectTag(response.tag, .bool_result);
        if (response.payload.len != 1) return error.ProtocolMismatch;
        return switch (response.payload[0]) {
            0 => false,
            1 => true,
            else => error.ProtocolMismatch,
        };
    }

    pub fn selectionStart(
        self: *Client,
        id: u64,
        row: u16,
        col: u16,
        mode: vt.terminal.SelectionMode,
    ) !void {
        var enc = protocol.Encoder.init(self.gpa);
        defer enc.deinit();
        try enc.int(u64, id);
        try enc.byte(@intFromEnum(mode));
        try enc.int(u16, row);
        try enc.int(u16, col);
        try self.requestOk(.selection_start, enc.slice());
    }

    pub fn selectionDrag(self: *Client, id: u64, row: u16, col: u16) !void {
        var enc = protocol.Encoder.init(self.gpa);
        defer enc.deinit();
        try enc.int(u64, id);
        try enc.int(u16, row);
        try enc.int(u16, col);
        try self.requestOk(.selection_drag, enc.slice());
    }

    pub fn selectionClear(self: *Client, id: u64) !void {
        try self.idCommand(.selection_clear, id);
    }

    pub fn selectionText(self: *Client, id: u64) !?[]u8 {
        var response = try self.idRequest(.selection_text, id);
        defer response.deinit(self.gpa);
        try expectTag(response.tag, .bytes_result);
        var dec: protocol.Decoder = .{ .bytes = response.payload };
        if (!try dec.boolean()) {
            try dec.finish();
            return null;
        }
        const bytes = try dec.allocBytes(self.gpa, protocol.max_payload);
        errdefer self.gpa.free(bytes);
        try dec.finish();
        return bytes;
    }

    fn idCommand(self: *Client, tag: protocol.Tag, id: u64) !void {
        var enc = protocol.Encoder.init(self.gpa);
        defer enc.deinit();
        try enc.int(u64, id);
        try self.requestOk(tag, enc.slice());
    }

    fn idRequest(self: *Client, tag: protocol.Tag, id: u64) !protocol.Frame {
        var enc = protocol.Encoder.init(self.gpa);
        defer enc.deinit();
        try enc.int(u64, id);
        return self.request(tag, enc.slice());
    }

    fn requestOk(self: *Client, tag: protocol.Tag, payload: []const u8) !void {
        var response = try self.request(tag, payload);
        defer response.deinit(self.gpa);
        try expectTag(response.tag, .ok);
        if (response.payload.len != 0) return error.ProtocolMismatch;
    }

    fn request(self: *Client, tag: protocol.Tag, payload: []const u8) !protocol.Frame {
        return self.requestLane(.interactive, tag, payload);
    }

    fn requestLane(
        self: *Client,
        lane: RequestLane,
        tag: protocol.Tag,
        payload: []const u8,
    ) !protocol.Frame {
        return switch (lane) {
            .interactive => self.requestLocked(
                &self.command_mutex,
                self.command_fd,
                tag,
                payload,
            ),
            .refresh => self.requestRefreshLocked(tag, payload),
        };
    }

    fn requestRefreshLocked(
        self: *Client,
        tag: protocol.Tag,
        payload: []const u8,
    ) !protocol.Frame {
        self.refresh_mutex.lockUncancelable(self.io);
        defer self.refresh_mutex.unlock(self.io);
        return self.requestOnFd(self.refresh_fd, tag, payload) catch |err| {
            if (err == error.RemoteError) return err;
            if (!self.shared_graphics) {
                self.markDisconnected();
                return err;
            }
            self.disableSharedGraphicsLocked();
            if (self.refresh_fd < 0) return err;
            return self.requestOnFd(self.refresh_fd, tag, payload) catch |fallback_err| {
                self.markDisconnected();
                return fallback_err;
            };
        };
    }

    fn requestLocked(
        self: *Client,
        mutex: *std.Io.Mutex,
        fd: c.fd_t,
        tag: protocol.Tag,
        payload: []const u8,
    ) !protocol.Frame {
        mutex.lockUncancelable(self.io);
        defer mutex.unlock(self.io);
        return self.requestOnFd(fd, tag, payload) catch |err| {
            if (err != error.RemoteError) self.markDisconnected();
            return err;
        };
    }

    fn requestOnFd(
        self: *Client,
        fd: c.fd_t,
        tag: protocol.Tag,
        payload: []const u8,
    ) !protocol.Frame {
        try selected_protocol.writeFrame(fd, self.dialect, tag, payload);
        const response = selected_protocol.readFrame(fd, self.dialect, self.gpa) catch |err| {
            return err;
        };
        if (response.tag == .protocol_error) {
            var owned = response;
            owned.deinit(self.gpa);
            return error.RemoteError;
        }
        return response;
    }

    fn eventLoop(self: *Client) void {
        while (!self.stopping.load(.acquire)) {
            const fd = self.event_fd.load(.acquire);
            var frame = selected_protocol.readFrame(fd, self.dialect, self.gpa) catch {
                if (!self.reconnectEvents(fd)) return;
                continue;
            };
            defer frame.deinit(self.gpa);
            if (frame.tag != .event or frame.payload.len != 9) {
                if (!self.reconnectEvents(fd)) return;
                continue;
            }
            const id = std.mem.readInt(u64, frame.payload[0..8], .little);
            const flags: protocol.EventFlags = @bitCast(frame.payload[8]);
            if (self.event_callback) |callback| callback(self.event_context, id, flags);
        }
    }

    fn reconnectEvents(self: *Client, old_fd: c.fd_t) bool {
        self.event_fd.store(-1, .release);
        _ = c.close(old_fd);
        if (self.stopping.load(.acquire)) return false;
        self.invalidateAll();

        while (!self.stopping.load(.acquire)) {
            const fd = subscribeEvent(self.socket_path, self.io, self.gpa, self.dialect) catch {
                if (!self.commandAlive()) return false;
                self.io.sleep(.fromMilliseconds(100), .awake) catch {};
                continue;
            };
            self.event_fd.store(fd, .release);
            if (self.stopping.load(.acquire)) {
                self.event_fd.store(-1, .release);
                _ = c.close(fd);
                return false;
            }
            self.invalidateAll();
            return true;
        }
        return false;
    }

    fn commandAlive(self: *Client) bool {
        var response = self.request(.list, &.{}) catch return false;
        defer response.deinit(self.gpa);
        if (response.tag == .session_list) return true;
        self.markDisconnected();
        return false;
    }

    fn invalidateAll(self: *Client) void {
        if (self.event_callback) |callback| callback(
            self.event_context,
            0,
            .{ .grid = true, .metadata = true, .lifecycle = true },
        );
    }

    fn markDisconnected(self: *Client) void {
        if (self.disconnected.swap(true, .acq_rel)) return;
        // Session ids begin at one. Zero is an internal client notification,
        // never a protocol session id.
        if (self.event_callback) |callback| callback(
            self.event_context,
            0,
            .{ .lifecycle = true },
        );
    }
};

const NegotiatedConnection = struct {
    fd: c.fd_t,
    dialect: selected_protocol.Dialect,
};

const sol_local: c_int = 0;
const local_peer_pid: u32 = 2;
const proc_pid_path_max = 4096;

extern "c" fn getpeereid(fd: c_int, uid: *c.uid_t, gid: *c.gid_t) c_int;
extern "c" fn proc_pidpath(pid: c_int, buffer: *anyopaque, buffer_size: u32) c_int;

fn verifiedDaemonPeerPid(fd: c.fd_t) !c.pid_t {
    var peer_uid: c.uid_t = undefined;
    var peer_gid: c.gid_t = undefined;
    if (getpeereid(fd, &peer_uid, &peer_gid) != 0 or peer_uid != c.getuid())
        return error.UnverifiedDaemonPeer;
    var pid: c.pid_t = 0;
    var pid_len: c.socklen_t = @sizeOf(c.pid_t);
    if (c.getsockopt(fd, sol_local, local_peer_pid, &pid, &pid_len) != 0 or
        pid_len != @sizeOf(c.pid_t) or pid <= 0)
        return error.UnverifiedDaemonPeer;
    var path: [proc_pid_path_max]u8 = undefined;
    const path_len = proc_pidpath(pid, &path, path.len);
    if (path_len <= 0) return error.UnverifiedDaemonPeer;
    const executable = path[0..@intCast(path_len)];
    if (!std.mem.eql(u8, std.fs.path.basename(executable), "boringterminald"))
        return error.UnverifiedDaemonPeer;
    // Re-read the peer pid after inspecting the executable so a changed peer
    // can never turn the following signal into a process-name lookup.
    var confirmed_pid: c.pid_t = 0;
    pid_len = @sizeOf(c.pid_t);
    if (c.getsockopt(fd, sol_local, local_peer_pid, &confirmed_pid, &pid_len) != 0 or
        confirmed_pid != pid)
        return error.UnverifiedDaemonPeer;
    return pid;
}

const LifecycleQuery = struct {
    identity: DaemonIdentity,
    dialects: [lifecycle.max_dialects]u16,
    dialect_count: u8,
};

fn stopIdleDaemon(
    path: []const u8,
    io: std.Io,
    alloc: std.mem.Allocator,
) !bool {
    const fd = try connect(path, io);
    defer _ = c.close(fd);
    try lifecycle.writeFrame(fd, .stop_if_idle, &.{});
    var response = try lifecycle.readFrame(fd, alloc);
    defer response.deinit(alloc);
    if (response.payload.len != 0) return error.ProtocolMismatch;
    if (response.tag == .busy) return false;
    if (response.tag != .ok) return error.ProtocolMismatch;
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (connect(path, io)) |probe_fd| {
            _ = c.close(probe_fd);
            try io.sleep(.fromMilliseconds(10), .awake);
        } else |_| return true;
    }
    return error.DaemonStopTimeout;
}

/// Complete a compatible update only after the calling viewer has closed all
/// of its attach lanes. Another viewer or any surviving session keeps the old
/// daemon authoritative and makes this a no-op.
pub fn finalizePendingUpdateIfIdle(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) !bool {
    const path = try protocol.socketPath(gpa, env);
    defer gpa.free(path);
    var attempts: usize = 0;
    while (attempts < 6) : (attempts += 1) {
        const status_fd = try connect(path, io);
        const status = queryLifecycle(status_fd, gpa) catch |err| {
            _ = c.close(status_fd);
            return err;
        };
        _ = c.close(status_fd);
        const dialect = selected_protocol.bestSupported(status.dialects[0..status.dialect_count]) orelse
            return false;
        if (!dialect.isCompatibility() or status.identity.reported_sessions != 0) return false;
        if (status.identity.reported_attach_connections == 0)
            return try stopIdleDaemon(path, io, gpa);
        // The daemon may not have observed the just-closed command/refresh
        // sockets yet. Bound this grace period so another viewer never makes
        // application termination feel blocked.
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return false;
}

fn spawnAndConnectCurrent(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    path: []const u8,
) !NegotiatedConnection {
    try spawnDaemon(gpa, io, env);
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (connect(path, io)) |fd| {
            probeDialect(fd, .current, gpa) catch {
                _ = c.close(fd);
                try io.sleep(.fromMilliseconds(20), .awake);
                continue;
            };
            return .{ .fd = fd, .dialect = .current };
        } else |_| {}
        try io.sleep(.fromMilliseconds(20), .awake);
    }
    return error.DaemonStartTimeout;
}

fn queryLifecycle(fd: c.fd_t, alloc: std.mem.Allocator) !LifecycleQuery {
    try lifecycle.writeFrame(fd, .status, &.{});
    var response = try lifecycle.readFrame(fd, alloc);
    defer response.deinit(alloc);
    if (response.tag != .status_result) return error.ProtocolMismatch;
    const status = try lifecycle.decodeStatus(response.payload);
    var identity: DaemonIdentity = .{
        .lifecycle_supported = true,
        .reported_sessions = status.session_count,
        .reported_attach_connections = status.attach_connection_count,
    };
    @memcpy(
        identity.product_version[0..status.product_version.len],
        status.product_version,
    );
    identity.product_version_len = @intCast(status.product_version.len);
    return .{
        .identity = identity,
        .dialects = status.dialects,
        .dialect_count = status.dialect_count,
    };
}

fn negotiateConnected(
    path: []const u8,
    io: std.Io,
    alloc: std.mem.Allocator,
    current_fd: c.fd_t,
) !NegotiatedConnection {
    if (probeDialect(current_fd, .current, alloc)) |_| {
        return .{ .fd = current_fd, .dialect = .current };
    } else |_| {
        _ = c.close(current_fd);
    }
    for (selected_protocol.retainedProbeOrder()) |dialect| {
        const compat_fd = try connect(path, io);
        if (probeDialect(compat_fd, dialect, alloc)) |_| {
            return .{ .fd = compat_fd, .dialect = dialect };
        } else |_| {
            _ = c.close(compat_fd);
        }
    }
    return error.DaemonUpgradeRequired;
}

/// A dialect is selected only after a complete registry round-trip. This
/// prevents EOF/version errors from becoming a partially initialized client.
fn probeDialect(
    fd: c.fd_t,
    dialect: selected_protocol.Dialect,
    alloc: std.mem.Allocator,
) !void {
    try selected_protocol.writeFrame(fd, dialect, .list, &.{});
    var response = try selected_protocol.readFrame(fd, dialect, alloc);
    defer response.deinit(alloc);
    if (response.tag != .session_list) return error.ProtocolMismatch;
    var dec: protocol.Decoder = .{ .bytes = response.payload };
    var registry = try selected_protocol.decodeRegistry(dialect, &dec, alloc);
    registry.deinit(alloc);
}

fn connect(path: []const u8, io: std.Io) !c.fd_t {
    const address = try std.Io.net.UnixAddress.init(path);
    const stream = try address.connect(io);
    return stream.socket.handle;
}

fn subscribeEvent(
    path: []const u8,
    io: std.Io,
    alloc: std.mem.Allocator,
    dialect: selected_protocol.Dialect,
) !c.fd_t {
    const fd = try connect(path, io);
    errdefer _ = c.close(fd);
    try selected_protocol.writeFrame(fd, dialect, .subscribe, &.{});
    var response = try selected_protocol.readFrame(fd, dialect, alloc);
    defer response.deinit(alloc);
    if (response.tag != .ok or response.payload.len != 0) return error.ProtocolMismatch;
    return fd;
}

fn spawnDaemon(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) !void {
    const executable_dir = try std.process.executableDirPathAlloc(io, gpa);
    defer gpa.free(executable_dir);
    const daemon_path = try std.fs.path.join(gpa, &.{ executable_dir, "boringterminald" });
    defer gpa.free(daemon_path);
    const child = try gpa.create(std.process.Child);
    errdefer gpa.destroy(child);
    child.* = try std.process.spawn(io, .{
        .argv = &.{daemon_path},
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
    const reaper = try gpa.create(Reaper);
    errdefer gpa.destroy(reaper);
    reaper.* = .{ .gpa = gpa, .io = io, .child = child };
    const thread = try std.Thread.spawn(.{}, Reaper.run, .{reaper});
    thread.detach();
}

const Reaper = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    child: *std.process.Child,

    fn run(self: *Reaper) void {
        _ = self.child.wait(self.io) catch {};
        self.gpa.destroy(self.child);
        self.gpa.destroy(self);
    }
};

fn expectTag(actual: protocol.Tag, expected: protocol.Tag) !void {
    if (actual != expected) return error.ProtocolMismatch;
}

const V13Fixture = struct {
    io: std.Io,
    path: []const u8,
    ready: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,

    fn run(self: *V13Fixture) void {
        self.runFallible() catch |err| {
            self.failure = err;
        };
        self.ready.store(true, .release);
    }

    fn runFallible(self: *V13Fixture) !void {
        const alloc = std.heap.page_allocator;
        const address = try std.Io.net.UnixAddress.init(self.path);
        var server = try address.listen(self.io, .{});
        defer server.deinit(self.io);
        self.ready.store(true, .release);

        // Pre-BTL1 peer rejects lifecycle, then the disposable current probe.
        var rejected_lifecycle = try server.accept(self.io);
        rejected_lifecycle.close(self.io);
        var rejected_current = try server.accept(self.io);
        rejected_current.close(self.io);

        // The third connection is the selected v13 command lane.
        var command = try server.accept(self.io);
        defer command.close(self.io);
        try expectFrozenFrame(
            command.socket.handle,
            alloc,
            @embedFile("daemon_protocol/fixtures/v13/list-request.hex"),
        );
        try sendFrozenFrame(
            command.socket.handle,
            alloc,
            @embedFile("daemon_protocol/fixtures/v13/empty-registry-response.hex"),
        );

        // Client performs one harmless lifecycle discovery after legacy
        // selection, then opens its refresh lane.
        var rejected_lifecycle_retry = try server.accept(self.io);
        rejected_lifecycle_retry.close(self.io);
        var refresh = try server.accept(self.io);
        defer refresh.close(self.io);

        try expectFrozenFrame(
            command.socket.handle,
            alloc,
            @embedFile("daemon_protocol/fixtures/v13/list-request.hex"),
        );
        try sendFrozenFrame(
            command.socket.handle,
            alloc,
            @embedFile("daemon_protocol/fixtures/v13/empty-registry-response.hex"),
        );

        // Ordinary semantic keys retain the exact public v13 payload.
        try expectFrozenFrame(
            command.socket.handle,
            alloc,
            @embedFile("daemon_protocol/fixtures/v13/up-key-request.hex"),
        );
        try protocol.writeFrameVersion(command.socket.handle, 13, .ok, &.{});

        // v15 committed text must cross v13 through its bounded raw-write
        // command, not the incompatible v15 key-event shape.
        try expectFrozenFrame(
            command.socket.handle,
            alloc,
            @embedFile("daemon_protocol/fixtures/v13/committed-text-request.hex"),
        );
        try protocol.writeFrameVersion(command.socket.handle, 13, .ok, &.{});

        // v15 supplies pixels internally but the public v13 request remains
        // the exact cell-only frame.
        try expectFrozenFrame(
            command.socket.handle,
            alloc,
            @embedFile("daemon_protocol/fixtures/v13/mouse-request.hex"),
        );
        try protocol.writeFrameVersion(command.socket.handle, 13, .bool_result, &.{1});
    }
};

const V10Fixture = struct {
    io: std.Io,
    path: []const u8,
    ready: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,

    fn run(self: *V10Fixture) void {
        self.runFallible() catch |err| {
            self.failure = err;
        };
        self.ready.store(true, .release);
    }

    fn runFallible(self: *V10Fixture) !void {
        const alloc = std.heap.page_allocator;
        const address = try std.Io.net.UnixAddress.init(self.path);
        var server = try address.listen(self.io, .{});
        defer server.deinit(self.io);
        self.ready.store(true, .release);

        var rejected_lifecycle = try server.accept(self.io);
        rejected_lifecycle.close(self.io);
        var rejected_current = try server.accept(self.io);
        rejected_current.close(self.io);
        var rejected_v13 = try server.accept(self.io);
        rejected_v13.close(self.io);

        var command = try server.accept(self.io);
        defer command.close(self.io);
        try expectFrozenFrame(
            command.socket.handle,
            alloc,
            @embedFile("daemon_protocol/fixtures/v10/list-request.hex"),
        );
        try sendFrozenFrame(
            command.socket.handle,
            alloc,
            @embedFile("daemon_protocol/fixtures/v10/empty-registry-response.hex"),
        );

        var rejected_lifecycle_retry = try server.accept(self.io);
        rejected_lifecycle_retry.close(self.io);
        var refresh = try server.accept(self.io);
        defer refresh.close(self.io);

        try expectFrozenFrame(
            command.socket.handle,
            alloc,
            @embedFile("daemon_protocol/fixtures/v10/list-request.hex"),
        );
        try sendFrozenFrame(
            command.socket.handle,
            alloc,
            @embedFile("daemon_protocol/fixtures/v10/empty-registry-response.hex"),
        );
        try expectFrozenFrame(
            command.socket.handle,
            alloc,
            @embedFile("daemon_protocol/fixtures/v10/snapshot-request.hex"),
        );
        try sendFrozenFrame(
            command.socket.handle,
            alloc,
            @embedFile("daemon_protocol/fixtures/v10/minimal-snapshot-response.hex"),
        );
        try expectFrozenFrame(
            command.socket.handle,
            alloc,
            @embedFile("daemon_protocol/fixtures/v10/up-key-request.hex"),
        );
        try protocol.writeFrameVersion(command.socket.handle, 10, .ok, &.{});
        try expectFrozenFrame(
            command.socket.handle,
            alloc,
            @embedFile("daemon_protocol/fixtures/v10/committed-text-request.hex"),
        );
        try protocol.writeFrameVersion(command.socket.handle, 10, .ok, &.{});
        try expectFrozenFrame(
            command.socket.handle,
            alloc,
            @embedFile("daemon_protocol/fixtures/v10/mouse-request.hex"),
        );
        try protocol.writeFrameVersion(command.socket.handle, 10, .bool_result, &.{1});
    }
};

const UnsupportedLegacyFixture = struct {
    io: std.Io,
    path: []const u8,
    ready: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,

    fn run(self: *UnsupportedLegacyFixture) void {
        self.runFallible() catch |err| {
            self.failure = err;
        };
        self.ready.store(true, .release);
    }

    fn runFallible(self: *UnsupportedLegacyFixture) !void {
        const address = try std.Io.net.UnixAddress.init(self.path);
        var server = try address.listen(self.io, .{});
        defer server.deinit(self.io);
        self.ready.store(true, .release);
        // Malformed lifecycle, current, v13, and v10 probes are all rejected.
        // Only after every retained dialect fails may startup classify the
        // peer as upgrade-required.
        inline for (0..4) |_| {
            var connection = try server.accept(self.io);
            connection.close(self.io);
        }
    }
};

fn frozenHex(alloc: std.mem.Allocator, source: []const u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(alloc);
    var high: ?u8 = null;
    for (source) |ch| {
        if (std.ascii.isWhitespace(ch)) continue;
        const nibble: u8 = switch (ch) {
            '0'...'9' => ch - '0',
            'a'...'f' => ch - 'a' + 10,
            'A'...'F' => ch - 'A' + 10,
            else => return error.InvalidFrozenFixture,
        };
        if (high) |value| {
            try bytes.append(alloc, value << 4 | nibble);
            high = null;
        } else {
            high = nibble;
        }
    }
    if (high != null or bytes.items.len == 0) return error.InvalidFrozenFixture;
    return bytes.toOwnedSlice(alloc);
}

fn readExactFixture(fd: c.fd_t, out: []u8) !void {
    var rest = out;
    while (rest.len > 0) {
        const n = c.read(fd, rest.ptr, rest.len);
        if (n == 0) return error.EndOfStream;
        if (n < 0) {
            if (c.errno(n) == .INTR) continue;
            return error.ReadFailed;
        }
        rest = rest[@intCast(n)..];
    }
}

fn sendExactFixture(fd: c.fd_t, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = c.send(fd, rest.ptr, rest.len, c.MSG.NOSIGNAL);
        if (n < 0) {
            if (c.errno(n) == .INTR) continue;
            return error.WriteFailed;
        }
        rest = rest[@intCast(n)..];
    }
}

fn expectFrozenFrame(fd: c.fd_t, alloc: std.mem.Allocator, source: []const u8) !void {
    const expected = try frozenHex(alloc, source);
    defer alloc.free(expected);
    const actual = try alloc.alloc(u8, expected.len);
    defer alloc.free(actual);
    try readExactFixture(fd, actual);
    if (!std.mem.eql(u8, expected, actual)) return error.InvalidFixtureRequest;
}

fn sendFrozenFrame(fd: c.fd_t, alloc: std.mem.Allocator, source: []const u8) !void {
    const frame = try frozenHex(alloc, source);
    defer alloc.free(frame);
    try sendExactFixture(fd, frame);
}

test "resize mailbox retains only the newest unpublished geometry" {
    var slot: ?ResizeRequest = null;
    coalesceResize(&slot, .{
        .cols = 80,
        .rows = 24,
        .pixel_width = 800,
        .pixel_height = 480,
        .generation = 1,
    });
    coalesceResize(&slot, .{
        .cols = 132,
        .rows = 48,
        .pixel_width = 1320,
        .pixel_height = 960,
        .generation = 7,
    });

    const latest = slot.?;
    try std.testing.expectEqual(@as(u16, 132), latest.cols);
    try std.testing.expectEqual(@as(u16, 48), latest.rows);
    try std.testing.expectEqual(@as(u16, 1320), latest.pixel_width);
    try std.testing.expectEqual(@as(u16, 960), latest.pixel_height);
    try std.testing.expectEqual(@as(u64, 7), latest.generation);
}

test "peer verification rejects a same-uid non-daemon executable" {
    const io = std.testing.io;
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buf,
        "/tmp/bt-peer-{x}.sock",
        .{std.mem.readInt(u64, &random_bytes, .little)},
    );
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    const address = try std.Io.net.UnixAddress.init(path);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const client_stream = try address.connect(io);
    defer client_stream.close(io);
    var accepted = try server.accept(io);
    defer accepted.close(io);

    // The listener is this test executable, not the signed helper. Matching
    // uid and possession of a Unix socket are not enough authority to signal.
    try std.testing.expectError(
        error.UnverifiedDaemonPeer,
        verifiedDaemonPeerPid(client_stream.socket.handle),
    );
}

test "client negotiates v10 and translates its frozen snapshot" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    var home_buf: [64]u8 = undefined;
    const home = try std.fmt.bufPrint(
        &home_buf,
        "/tmp/bt-v10-{x}",
        .{std.mem.readInt(u64, &random_bytes, .little)},
    );
    try std.Io.Dir.createDirAbsolute(io, home, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    var env = try std.process.Environ.createMap(std.testing.environ, alloc);
    defer env.deinit();
    try env.put("HOME", home);
    const support_dir = try protocol.supportDir(alloc, &env);
    defer alloc.free(support_dir);
    try std.Io.Dir.cwd().createDirPath(io, support_dir);
    const socket_path = try protocol.socketPath(alloc, &env);
    defer alloc.free(socket_path);

    var fixture: V10Fixture = .{ .io = io, .path = socket_path };
    const thread = try std.Thread.spawn(.{}, V10Fixture.run, .{&fixture});
    while (!fixture.ready.load(.acquire)) try io.sleep(.fromMilliseconds(1), .awake);
    if (fixture.failure) |err| return err;

    var client = try Client.init(alloc, io, &env);
    try std.testing.expectEqual(@as(u16, 10), client.attachDialect());
    try std.testing.expect(client.updatePending());
    try std.testing.expect(!client.supportsSearch());
    try std.testing.expect(!client.supportsCreateBeside());
    try std.testing.expect(!client.supportsPersistentPairZoom());
    var registry = try client.listRegistry();
    defer registry.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), registry.sessions.len);
    try std.testing.expectError(error.FeatureUnavailable, client.search(1, .initial, "x", null));
    try std.testing.expectError(error.FeatureUnavailable, client.createBeside(1, 40, 24, null));
    try std.testing.expectError(error.FeatureUnavailable, client.setPairZoom(1, true));
    var snapshot = try client.snapshot(1);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqualStrings("v10", snapshot.title);
    try std.testing.expectEqual(@as(u64, 0), snapshot.grid_epoch);
    try std.testing.expectEqual(@as(usize, 0), snapshot.hyperlinks.len);
    try std.testing.expectEqual(@as(u32, 0), snapshot.cells[0].hyperlink_id);
    try client.keyEvent(1, .{ .code = .up });
    try client.keyEvent(1, .{ .code = .text, .text = "hello" });
    try std.testing.expect(try client.mouseEvent(1, .{
        .kind = .press,
        .button = .left,
        .col = 4,
        .row = 2,
        .pixel_x = 80,
        .pixel_y = 40,
    }));
    client.deinit();
    thread.join();
    if (fixture.failure) |err| return err;
}

test "malformed peer exhausts exact dialects into typed upgrade result" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    var home_buf: [64]u8 = undefined;
    const home = try std.fmt.bufPrint(
        &home_buf,
        "/tmp/bt-unsupported-{x}",
        .{std.mem.readInt(u64, &random_bytes, .little)},
    );
    try std.Io.Dir.createDirAbsolute(io, home, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    var env = try std.process.Environ.createMap(std.testing.environ, alloc);
    defer env.deinit();
    try env.put("HOME", home);
    const support_dir = try protocol.supportDir(alloc, &env);
    defer alloc.free(support_dir);
    try std.Io.Dir.cwd().createDirPath(io, support_dir);
    const socket_path = try protocol.socketPath(alloc, &env);
    defer alloc.free(socket_path);

    var fixture: UnsupportedLegacyFixture = .{ .io = io, .path = socket_path };
    const thread = try std.Thread.spawn(.{}, UnsupportedLegacyFixture.run, .{&fixture});
    while (!fixture.ready.load(.acquire)) try io.sleep(.fromMilliseconds(1), .awake);
    try std.testing.expectError(error.DaemonUpgradeRequired, Client.init(alloc, io, &env));
    thread.join();
    if (fixture.failure) |err| return err;
}

test "client negotiates v13 and downgrades committed text" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    var home_buf: [64]u8 = undefined;
    const home = try std.fmt.bufPrint(
        &home_buf,
        "/tmp/bt-v13-{x}",
        .{std.mem.readInt(u64, &random_bytes, .little)},
    );
    try std.Io.Dir.createDirAbsolute(io, home, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    var env = try std.process.Environ.createMap(std.testing.environ, alloc);
    defer env.deinit();
    try env.put("HOME", home);
    const support_dir = try protocol.supportDir(alloc, &env);
    defer alloc.free(support_dir);
    try std.Io.Dir.cwd().createDirPath(io, support_dir);
    const socket_path = try protocol.socketPath(alloc, &env);
    defer alloc.free(socket_path);

    var fixture: V13Fixture = .{ .io = io, .path = socket_path };
    const thread = try std.Thread.spawn(.{}, V13Fixture.run, .{&fixture});
    while (!fixture.ready.load(.acquire)) try io.sleep(.fromMilliseconds(1), .awake);
    if (fixture.failure) |err| return err;

    var client = try Client.init(alloc, io, &env);
    try std.testing.expectEqual(@as(u16, 13), client.attachDialect());
    try std.testing.expect(client.updatePending());
    try std.testing.expect(!client.daemonIdentity().lifecycle_supported);
    var registry = try client.listRegistry();
    defer registry.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), registry.sessions.len);
    try client.keyEvent(1, .{ .code = .up });
    try client.keyEvent(1, .{ .code = .text, .text = "hello" });
    try std.testing.expect(try client.mouseEvent(1, .{
        .kind = .press,
        .button = .left,
        .col = 4,
        .row = 2,
        .pixel_x = 80,
        .pixel_y = 40,
    }));
    client.deinit();
    thread.join();
    if (fixture.failure) |err| return err;
}
