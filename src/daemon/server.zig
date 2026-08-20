//! `boringterminald`: PTY/VT ownership and the private viewer protocol.

const std = @import("std");
const protocol = @import("protocol.zig");
const lifecycle = @import("lifecycle.zig");
const product_version = @import("../version.zig");
const display_registry = @import("display_registry.zig");
const session_mod = @import("../shell/session.zig");
const graphics_mod = @import("../shell/graphics.zig");
const pty_mod = @import("../shell/pty.zig");
const working_directory = @import("../shell/working_directory.zig");
const vt = @import("../vt.zig");
const c = std.c;

const Daemon = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    sessions: session_mod.SessionManager,
    display: display_registry.Registry,
    next_session_id: u64 = 1,
    registry_mutex: std.Io.Mutex = .init,
    watchers_mutex: std.Io.Mutex = .init,
    watchers: std.ArrayList(c.fd_t) = .empty,
    focus_owner_fd: c.fd_t = -1,
    focused_session_id: ?u64 = null,
    graphics_budget_mutex: std.Io.Mutex = .init,
    graphics_staging_bytes: usize = 0,
    lifecycle_mutex: std.Io.Mutex = .init,
    attach_connections: u32 = 0,
    draining: std.atomic.Value(bool) = .init(false),
    shutting_down: std.atomic.Value(bool) = .init(false),
    listener_fd: std.atomic.Value(c.fd_t) = .init(-1),
    listener_closed: std.atomic.Value(bool) = .init(false),
};

const graphics_slot_count = 3;
const max_graphics_staging_bytes: usize = 128 * 1024 * 1024;

const GraphicsSlot = struct {
    fd: c.fd_t = -1,
    mapping: ?*anyopaque = null,
    capacity: usize = 0,
    leased: bool = false,
    lease_token: u64 = 0,
    descriptor_pending: bool = false,
};

const GraphicsPool = struct {
    slots: [graphics_slot_count]GraphicsSlot = [_]GraphicsSlot{.{}} ** graphics_slot_count,
    next_lease_token: u64 = 1,

    fn deinit(self: *GraphicsPool) void {
        var released: usize = 0;
        for (&self.slots) |*slot| {
            if (slot.mapping) |mapping| _ = c.munmap(@ptrCast(@alignCast(mapping)), slot.capacity);
            if (slot.fd >= 0) _ = c.close(slot.fd);
            released += slot.capacity;
            slot.* = .{};
        }
        daemon.graphics_budget_mutex.lockUncancelable(daemon.io);
        std.debug.assert(daemon.graphics_staging_bytes >= released);
        daemon.graphics_staging_bytes -= released;
        daemon.graphics_budget_mutex.unlock(daemon.io);
    }
};

var daemon: *Daemon = undefined;

pub fn run(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !void {
    daemon = try gpa.create(Daemon);
    daemon.* = .{
        .gpa = gpa,
        .io = io,
        .env = env,
        .sessions = session_mod.SessionManager.init(gpa),
        .display = display_registry.Registry.init(gpa),
    };

    const support_dir = try protocol.supportDir(gpa, env);
    defer gpa.free(support_dir);
    try std.Io.Dir.cwd().createDirPath(io, support_dir);
    const support_dir_z = try gpa.dupeZ(u8, support_dir);
    defer gpa.free(support_dir_z);
    if (c.chmod(support_dir_z.ptr, 0o700) != 0) return error.SetPermissionsFailed;

    const socket_path = try protocol.socketPath(gpa, env);
    defer gpa.free(socket_path);
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var server = address.listen(io, .{}) catch |err| switch (err) {
        error.AddressInUse => blk: {
            // A live winner owns the path. A stale inode is safe to remove
            // only after connect proves nobody is listening.
            if (address.connect(io)) |stream| {
                stream.close(io);
                return;
            } else |_| {}
            std.Io.Dir.deleteFileAbsolute(io, socket_path) catch |delete_err| switch (delete_err) {
                error.FileNotFound => {},
                else => return delete_err,
            };
            break :blk try address.listen(io, .{});
        },
        else => return err,
    };
    daemon.listener_fd.store(server.socket.handle, .release);
    defer if (!daemon.listener_closed.load(.acquire)) server.deinit(io);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    const socket_path_z = try gpa.dupeZ(u8, socket_path);
    defer gpa.free(socket_path_z);
    if (c.chmod(socket_path_z.ptr, 0o600) != 0) return error.SetPermissionsFailed;

    while (true) {
        const stream = server.accept(io) catch {
            if (daemon.shutting_down.load(.acquire)) break;
            continue;
        };
        const thread = std.Thread.spawn(.{}, connectionLoop, .{stream.socket.handle}) catch {
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

fn connectionLoop(fd: c.fd_t) void {
    defer _ = c.close(fd);
    const prefix = peekMagic(fd) catch return;
    if (lifecycle.isMagic(&prefix)) {
        lifecycleLoop(fd);
        return;
    }
    if (!beginAttach()) return;
    defer endAttach();
    defer clearFocusFor(fd);
    var first = protocol.readFrame(fd, daemon.gpa) catch return;
    defer first.deinit(daemon.gpa);
    if (first.tag == .subscribe) {
        if (first.payload.len != 0) return;
        subscribeLoop(fd);
        return;
    }

    var graphics_pool: ?GraphicsPool = null;
    defer if (graphics_pool) |*pool| pool.deinit();
    if (first.tag == .graphics_attach) {
        if (first.payload.len != 0) return;
        graphics_pool = .{};
        protocol.writeFrame(fd, .graphics_ready, &.{}) catch return;
    } else {
        handleCommand(fd, first.tag, first.payload, null) catch return;
    }

    while (true) {
        var frame = protocol.readFrame(fd, daemon.gpa) catch break;
        defer frame.deinit(daemon.gpa);
        if (frame.tag == .subscribe) break;
        handleCommand(fd, frame.tag, frame.payload, if (graphics_pool) |*pool| pool else null) catch break;
    }
}

fn peekMagic(fd: c.fd_t) ![4]u8 {
    var prefix: [4]u8 = undefined;
    while (true) {
        const n = c.recv(fd, &prefix, prefix.len, c.MSG.PEEK | c.MSG.WAITALL);
        if (n == prefix.len) return prefix;
        if (n == 0) return error.EndOfStream;
        if (n < 0 and c.errno(n) == .INTR) continue;
        return error.ReadFailed;
    }
}

fn beginAttach() bool {
    daemon.lifecycle_mutex.lockUncancelable(daemon.io);
    defer daemon.lifecycle_mutex.unlock(daemon.io);
    if (daemon.draining.load(.acquire)) return false;
    daemon.attach_connections += 1;
    return true;
}

fn endAttach() void {
    daemon.lifecycle_mutex.lockUncancelable(daemon.io);
    defer daemon.lifecycle_mutex.unlock(daemon.io);
    std.debug.assert(daemon.attach_connections > 0);
    daemon.attach_connections -= 1;
}

extern "c" fn getpeereid(fd: c_int, uid: *c.uid_t, gid: *c.gid_t) c_int;

fn lifecyclePeerAllowed(fd: c.fd_t) bool {
    var uid: c.uid_t = undefined;
    var gid: c.gid_t = undefined;
    return getpeereid(fd, &uid, &gid) == 0 and uid == c.getuid();
}

fn lifecycleLoop(fd: c.fd_t) void {
    if (!lifecyclePeerAllowed(fd)) return;
    var frame = lifecycle.readFrame(fd, daemon.gpa) catch return;
    defer frame.deinit(daemon.gpa);
    if (frame.payload.len != 0) return;
    switch (frame.tag) {
        .status => sendLifecycleStatus(fd) catch {},
        .stop_if_idle => stopIfIdle(fd),
        .terminate_all => terminateAll(fd),
        else => lifecycle.writeFrame(fd, .protocol_error, "invalid request") catch {},
    }
}

fn sendLifecycleStatus(fd: c.fd_t) !void {
    const dialects = [_]u16{protocol.version};
    daemon.lifecycle_mutex.lockUncancelable(daemon.io);
    defer daemon.lifecycle_mutex.unlock(daemon.io);
    daemon.registry_mutex.lockUncancelable(daemon.io);
    defer daemon.registry_mutex.unlock(daemon.io);
    const payload = try lifecycle.encodeStatus(daemon.gpa, .{
        .product_version = product_version.semantic,
        .dialects = &dialects,
        .session_count = @intCast(daemon.sessions.sessions.items.len),
        .attach_connection_count = daemon.attach_connections,
        .draining = daemon.draining.load(.acquire),
    });
    defer daemon.gpa.free(payload);
    try lifecycle.writeFrame(fd, .status_result, payload);
}

fn stopIfIdle(fd: c.fd_t) void {
    daemon.lifecycle_mutex.lockUncancelable(daemon.io);
    daemon.registry_mutex.lockUncancelable(daemon.io);
    const idle = daemon.sessions.sessions.items.len == 0 and
        daemon.attach_connections == 0 and !daemon.draining.load(.acquire);
    if (idle) daemon.draining.store(true, .release);
    daemon.registry_mutex.unlock(daemon.io);
    daemon.lifecycle_mutex.unlock(daemon.io);
    if (!idle) {
        lifecycle.writeFrame(fd, .busy, &.{}) catch {};
        return;
    }
    lifecycle.writeFrame(fd, .ok, &.{}) catch return;
    requestShutdown();
}

fn terminateAll(fd: c.fd_t) void {
    daemon.lifecycle_mutex.lockUncancelable(daemon.io);
    daemon.draining.store(true, .release);
    daemon.lifecycle_mutex.unlock(daemon.io);
    while (true) {
        daemon.registry_mutex.lockUncancelable(daemon.io);
        const id = if (daemon.sessions.sessions.items.len == 0)
            null
        else
            daemon.sessions.sessions.items[0].id;
        daemon.registry_mutex.unlock(daemon.io);
        closeSession(id orelse break) catch break;
    }
    lifecycle.writeFrame(fd, .ok, &.{}) catch return;
    // Preserve the ordinary HUP/grace/KILL close path before the service exits.
    daemon.io.sleep(.fromSeconds(2), .awake) catch {};
    requestShutdown();
}

fn requestShutdown() void {
    if (daemon.shutting_down.swap(true, .acq_rel)) return;
    const listener = daemon.listener_fd.swap(-1, .acq_rel);
    if (listener < 0) return;
    daemon.listener_closed.store(true, .release);
    _ = c.close(listener);
}

fn subscribeLoop(fd: c.fd_t) void {
    daemon.watchers_mutex.lockUncancelable(daemon.io);
    daemon.watchers.append(daemon.gpa, fd) catch {
        daemon.watchers_mutex.unlock(daemon.io);
        return;
    };
    daemon.watchers_mutex.unlock(daemon.io);
    protocol.writeFrame(fd, .ok, &.{}) catch {
        removeWatcher(fd);
        return;
    };

    var byte: [1]u8 = undefined;
    while (true) {
        const n = c.read(fd, &byte, 1);
        if (n == 0) break;
        if (n < 0) {
            if (c.errno(n) == .INTR) continue;
            break;
        }
    }
    removeWatcher(fd);
}

fn removeWatcher(fd: c.fd_t) void {
    daemon.watchers_mutex.lockUncancelable(daemon.io);
    defer daemon.watchers_mutex.unlock(daemon.io);
    for (daemon.watchers.items, 0..) |candidate, index| {
        if (candidate == fd) {
            _ = daemon.watchers.orderedRemove(index);
            return;
        }
    }
}

fn broadcast(session_id: u64, flags: protocol.EventFlags) void {
    var payload: [9]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], session_id, .little);
    payload[8] = @bitCast(flags);

    daemon.watchers_mutex.lockUncancelable(daemon.io);
    defer daemon.watchers_mutex.unlock(daemon.io);
    var index: usize = 0;
    while (index < daemon.watchers.items.len) {
        const fd = daemon.watchers.items[index];
        if (protocol.writeFrameNonBlocking(fd, .event, &payload)) {
            index += 1;
        } else {
            _ = daemon.watchers.orderedRemove(index);
            _ = c.shutdown(fd, c.SHUT.RDWR);
        }
    }
}

fn daemonSessionChanged(session: *session_mod.Session) void {
    broadcast(session.id, .{
        .grid = true,
        .metadata = session.metadata_dirty.swap(false, .acq_rel),
        .bell = session.bell_pending.swap(false, .acq_rel),
        .lifecycle = session.exited.load(.acquire),
    });
}

fn sendStagedProtocolError(fd: c.fd_t, message: []const u8) !void {
    try protocol.writeDescriptorEnvelope(fd, null);
    try sendProtocolError(fd, message);
}

fn stageImage(fd: c.fd_t, pool: *GraphicsPool, dec: *protocol.Decoder) !void {
    const session = acquireSession(try dec.int(u64)) orelse
        return sendStagedProtocolError(fd, "unknown session");
    defer session.release();
    const image_id = try dec.int(u32);
    const generation = try dec.int(u64);
    const row_alignment = try dec.int(u32);
    try dec.finish();
    const page_size_signed = c.sysconf(@intFromEnum(c._SC.PAGESIZE));
    if (page_size_signed <= 0) return sendStagedProtocolError(fd, "unavailable page size");
    const page_size: usize = @intCast(page_size_signed);
    if (row_alignment == 0 or !std.math.isPowerOfTwo(row_alignment) or row_alignment > page_size)
        return sendStagedProtocolError(fd, "invalid staging alignment");

    session.mutex.lockUncancelable(session.io);
    const render = session.graphics_store.renderByGeneration(image_id, generation) orelse {
        session.mutex.unlock(session.io);
        return sendStagedProtocolError(fd, "stale image resource");
    };
    render.frame.retain();
    session.mutex.unlock(session.io);
    defer render.frame.release(daemon.gpa);

    const active_row = std.math.mul(usize, render.width, 4) catch
        return sendStagedProtocolError(fd, "invalid staging geometry");
    const bytes_per_row = std.mem.alignForward(usize, active_row, row_alignment);
    const byte_length = std.math.mul(usize, bytes_per_row, render.height) catch
        return sendStagedProtocolError(fd, "invalid staging geometry");
    if (byte_length == 0 or byte_length > @import("../graphics_limits.zig").max_image_bytes)
        return sendStagedProtocolError(fd, "image exceeds staging limit");

    const slot_index = chooseGraphicsSlot(pool, byte_length) orelse {
        try protocol.writeDescriptorEnvelope(fd, null);
        return protocol.writeFrame(fd, .graphics_busy, &.{});
    };
    const slot = &pool.slots[slot_index];
    if (slot.capacity < byte_length) try growGraphicsSlot(slot, byte_length, page_size);

    const destination: [*]u8 = @ptrCast(slot.mapping.?);
    var row: usize = 0;
    while (row < render.height) : (row += 1) {
        const src_offset = row * active_row;
        const dst_offset = row * bytes_per_row;
        @memcpy(destination[dst_offset..][0..active_row], render.frame.rgba[src_offset..][0..active_row]);
    }

    var token = pool.next_lease_token;
    pool.next_lease_token +%= 1;
    if (pool.next_lease_token == 0) pool.next_lease_token = 1;
    if (token == 0) token = 1;
    slot.leased = true;
    slot.lease_token = token;

    var enc = protocol.Encoder.init(daemon.gpa);
    defer enc.deinit();
    try protocol.encodeStagedImage(&enc, .{
        .slot_index = @intCast(slot_index),
        .lease_token = token,
        .id = render.id,
        .generation = render.frame.generation,
        .width = render.width,
        .height = render.height,
        .bytes_per_row = @intCast(bytes_per_row),
        .byte_length = byte_length,
    });
    try protocol.writeDescriptorEnvelope(fd, if (slot.descriptor_pending) slot.fd else null);
    try protocol.writeFrame(fd, .staged_image, enc.slice());
    slot.descriptor_pending = false;
}

fn chooseGraphicsSlot(pool: *GraphicsPool, required: usize) ?usize {
    var first_free: ?usize = null;
    for (&pool.slots, 0..) |*slot, index| {
        if (slot.leased) continue;
        if (slot.capacity >= required) return index;
        if (first_free == null) first_free = index;
    }
    return first_free;
}

fn growGraphicsSlot(slot: *GraphicsSlot, required: usize, page_size: usize) !void {
    const page_rounded = std.mem.alignForward(usize, required, page_size);
    const capacity = std.math.ceilPowerOfTwo(usize, page_rounded) catch
        return error.StagingCapacityOverflow;
    if (capacity > @import("../graphics_limits.zig").max_image_bytes)
        return error.StagingCapacityOverflow;
    const old_capacity = slot.capacity;
    const delta = capacity - old_capacity;
    daemon.graphics_budget_mutex.lockUncancelable(daemon.io);
    if (daemon.graphics_staging_bytes > max_graphics_staging_bytes - delta) {
        daemon.graphics_budget_mutex.unlock(daemon.io);
        return error.StagingBudgetExceeded;
    }
    daemon.graphics_staging_bytes += delta;
    daemon.graphics_budget_mutex.unlock(daemon.io);
    errdefer {
        daemon.graphics_budget_mutex.lockUncancelable(daemon.io);
        daemon.graphics_staging_bytes -= capacity;
        daemon.graphics_budget_mutex.unlock(daemon.io);
        slot.* = .{};
    }

    if (slot.mapping) |mapping| _ = c.munmap(@ptrCast(@alignCast(mapping)), old_capacity);
    if (slot.fd >= 0) _ = c.close(slot.fd);
    slot.* = .{};

    // Darwin's POSIX shared-memory namespace permits only short names.
    var random_bytes: [8]u8 = undefined;
    try daemon.io.randomSecure(&random_bytes);
    var name_buf: [80]u8 = undefined;
    const name = try std.fmt.bufPrintZ(
        &name_buf,
        "/btg-{x}",
        .{std.mem.readInt(u64, &random_bytes, .little)},
    );
    _ = c.shm_unlink(name.ptr);
    const create_flags: c_int = @bitCast(c.O{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .EXCL = true,
    });
    const stage_fd = c.shm_open(name.ptr, create_flags, @as(c.mode_t, 0o600));
    if (stage_fd < 0) return error.StagingCreateFailed;
    errdefer _ = c.close(stage_fd);
    errdefer _ = c.shm_unlink(name.ptr);
    if (c.ftruncate(stage_fd, @intCast(capacity)) < 0) return error.StagingCreateFailed;
    const mapping = c.mmap(
        null,
        capacity,
        c.PROT{ .READ = true, .WRITE = true },
        c.MAP{ .TYPE = .SHARED },
        stage_fd,
        0,
    );
    if (mapping == c.MAP_FAILED) return error.StagingCreateFailed;
    _ = c.shm_unlink(name.ptr);
    slot.* = .{
        .fd = stage_fd,
        .mapping = mapping,
        .capacity = capacity,
        .descriptor_pending = true,
    };
}

fn handleCommand(
    fd: c.fd_t,
    tag: protocol.Tag,
    payload: []const u8,
    graphics_pool: ?*GraphicsPool,
) !void {
    var dec: protocol.Decoder = .{ .bytes = payload };
    switch (tag) {
        .list => {
            try dec.finish();
            var enc = protocol.Encoder.init(daemon.gpa);
            defer enc.deinit();
            daemon.registry_mutex.lockUncancelable(daemon.io);
            defer daemon.registry_mutex.unlock(daemon.io);
            try enc.int(u32, @intCast(daemon.sessions.sessions.items.len));
            for (daemon.sessions.sessions.items) |session| try encodeSessionMetadata(&enc, session);
            try enc.int(u32, @intCast(daemon.display.items.items.len));
            for (daemon.display.items.items) |item| try protocol.encodeDisplayItem(&enc, item);
            try protocol.writeFrame(fd, .session_list, enc.slice());
        },
        .create => {
            const request = try protocol.decodeCreateRequest(&dec);
            const session = createSessionWhileAccepting(
                request.cols,
                request.rows,
                request.cwd,
                .single,
            ) catch |err| switch (err) {
                error.DaemonDraining => return sendProtocolError(fd, "daemon is draining"),
                else => return err,
            };
            defer session.release();
            var enc = protocol.Encoder.init(daemon.gpa);
            defer enc.deinit();
            try encodeSessionMetadata(&enc, session);
            try protocol.writeFrame(fd, .metadata, enc.slice());
            broadcast(session.id, .{
                .grid = true,
                .metadata = true,
                .lifecycle = true,
                .registry = true,
            });
        },
        .create_beside => {
            const request = try protocol.decodeCreateBesideRequest(&dec);
            const session = createSessionWhileAccepting(
                request.create.cols,
                request.create.rows,
                request.create.cwd,
                .{ .beside = request.existing_id },
            ) catch |err| return sendProtocolError(fd, switch (err) {
                error.DaemonDraining => "daemon is draining",
                else => "session cannot be created beside target",
            });
            defer session.release();
            var enc = protocol.Encoder.init(daemon.gpa);
            defer enc.deinit();
            try encodeSessionMetadata(&enc, session);
            try protocol.writeFrame(fd, .metadata, enc.slice());
            broadcast(session.id, .{
                .grid = true,
                .metadata = true,
                .lifecycle = true,
                .registry = true,
            });
        },
        .snapshot => {
            const id = try dec.int(u64);
            try dec.finish();
            const session = acquireSession(id) orelse return sendProtocolError(fd, "unknown session");
            defer session.release();
            var snapshot = try captureSnapshot(session);
            defer snapshot.deinit(daemon.gpa);
            var enc = protocol.Encoder.init(daemon.gpa);
            defer enc.deinit();
            try snapshot.encode(&enc);
            try protocol.writeFrame(fd, .snapshot_result, enc.slice());
        },
        .search => {
            const request = try protocol.decodeSearchRequest(&dec);
            const session = acquireSession(request.id) orelse
                return sendProtocolError(fd, "unknown session");
            defer session.release();
            var result = try searchSession(session, request);
            defer result.deinit(daemon.gpa);
            var enc = protocol.Encoder.init(daemon.gpa);
            defer enc.deinit();
            try result.encode(&enc);
            try protocol.writeFrame(fd, .search_result, enc.slice());
        },
        .image => {
            const session = acquireSession(try dec.int(u64)) orelse
                return sendProtocolError(fd, "unknown session");
            defer session.release();
            const image_id = try dec.int(u32);
            const generation = try dec.int(u64);
            try dec.finish();
            var enc = protocol.Encoder.init(daemon.gpa);
            defer enc.deinit();
            session.mutex.lockUncancelable(session.io);
            const render = session.graphics_store.renderByGeneration(image_id, generation) orelse {
                session.mutex.unlock(session.io);
                return sendProtocolError(fd, "stale image resource");
            };
            protocol.encodeImage(&enc, .{
                .id = render.id,
                .generation = render.frame.generation,
                .width = render.width,
                .height = render.height,
                .rgba = render.frame.rgba,
            }) catch |err| {
                session.mutex.unlock(session.io);
                return err;
            };
            session.mutex.unlock(session.io);
            try protocol.writeFrame(fd, .image_result, enc.slice());
        },
        .stage_image => {
            const pool = graphics_pool orelse return sendProtocolError(fd, "graphics not negotiated");
            try stageImage(fd, pool, &dec);
        },
        .release_staged_image => {
            const pool = graphics_pool orelse return sendProtocolError(fd, "graphics not negotiated");
            const slot_index = try dec.byte();
            const lease_token = try dec.int(u64);
            try dec.finish();
            if (slot_index >= graphics_slot_count or lease_token == 0)
                return sendProtocolError(fd, "invalid staging lease");
            const slot = &pool.slots[slot_index];
            if (!slot.leased or slot.lease_token != lease_token)
                return sendProtocolError(fd, "stale staging lease");
            slot.leased = false;
            try sendOk(fd);
        },
        .graphics_attach => return sendProtocolError(fd, "graphics already negotiated"),
        .write => {
            const session = acquireSession(try dec.int(u64)) orelse
                return sendProtocolError(fd, "unknown session");
            defer session.release();
            const bytes = try dec.slice(try dec.int(u32));
            try dec.finish();
            if (!session.exited.load(.acquire)) {
                session.queueInput(bytes) catch |err| switch (err) {
                    error.InputQueueFull => return sendProtocolError(fd, "input queue full"),
                    error.SessionExited => return sendProtocolError(fd, "session exited"),
                    else => return err,
                };
                session.mutex.lockUncancelable(session.io);
                session.v.term.viewportToBottom();
                session.v.term.selectionClear();
                session.mutex.unlock(session.io);
            }
            try sendOk(fd);
            broadcast(session.id, .{ .grid = true });
        },
        .paste => {
            const session = acquireSession(try dec.int(u64)) orelse
                return sendProtocolError(fd, "unknown session");
            defer session.release();
            const bytes = try dec.slice(try dec.int(u32));
            try dec.finish();
            session.queuePaste(bytes) catch |err| switch (err) {
                error.InputQueueFull => return sendProtocolError(fd, "input queue full"),
                error.SessionExited => return sendProtocolError(fd, "session exited"),
                else => return err,
            };
            session.mutex.lockUncancelable(session.io);
            session.v.term.viewportToBottom();
            session.v.term.selectionClear();
            session.mutex.unlock(session.io);
            try sendOk(fd);
            broadcast(session.id, .{ .grid = true });
        },
        .resize => {
            const session = acquireSession(try dec.int(u64)) orelse
                return sendProtocolError(fd, "unknown session");
            defer session.release();
            const cols = try dec.int(u16);
            const rows = try dec.int(u16);
            const px_w = try dec.int(u16);
            const px_h = try dec.int(u16);
            try dec.finish();
            if (cols < 2 or rows < 1) return sendProtocolError(fd, "invalid terminal size");
            session.mutex.lockUncancelable(session.io);
            session.v.term.forceEndSynchronizedOutput();
            session.v.term.resize(cols, rows) catch {
                session.mutex.unlock(session.io);
                return sendProtocolError(fd, "terminal resize failed");
            };
            session.v.term.setPixelSize(px_w, px_h);
            session.mutex.unlock(session.io);
            session.pty.resize(cols, rows, px_w, px_h);
            try sendOk(fd);
            broadcast(session.id, .{ .grid = true });
        },
        .focus => {
            const id = try dec.int(u64);
            const focused = try dec.boolean();
            try dec.finish();
            if (!setFocus(fd, id, focused)) return sendProtocolError(fd, "unknown session");
            try sendOk(fd);
            broadcast(id, .{ .metadata = true, .registry = focused });
        },
        .mouse => {
            const session = acquireSession(try dec.int(u64)) orelse
                return sendProtocolError(fd, "unknown session");
            defer session.release();
            const event = try protocol.decodeMouseEvent(&dec);
            const handled = session.queueMouse(event) catch |err| switch (err) {
                error.InputQueueFull => return sendProtocolError(fd, "input queue full"),
                error.SessionExited => return sendProtocolError(fd, "session exited"),
                else => return err,
            };
            try protocol.writeFrame(fd, .bool_result, &.{@intFromBool(handled)});
        },
        .key => {
            const session = acquireSession(try dec.int(u64)) orelse
                return sendProtocolError(fd, "unknown session");
            defer session.release();
            const event = try protocol.decodeKeyEvent(&dec);
            session.queueKey(event) catch |err| switch (err) {
                error.InputQueueFull => return sendProtocolError(fd, "input queue full"),
                error.SessionExited => return sendProtocolError(fd, "session exited"),
                else => return err,
            };
            try sendOk(fd);
        },
        .close => {
            const id = try dec.int(u64);
            try dec.finish();
            closeSession(id) catch return sendProtocolError(fd, "unknown session");
            try sendOk(fd);
            broadcast(id, .{ .metadata = true, .lifecycle = true, .registry = true });
        },
        .pair => {
            const left = try dec.int(u64);
            const right = try dec.int(u64);
            try dec.finish();
            daemon.registry_mutex.lockUncancelable(daemon.io);
            const focused = daemon.focused_session_id;
            daemon.display.pair(left, right, focused) catch {
                daemon.registry_mutex.unlock(daemon.io);
                return sendProtocolError(fd, "sessions cannot be paired");
            };
            daemon.registry_mutex.unlock(daemon.io);
            try sendOk(fd);
            broadcast(0, .{ .registry = true });
        },
        .separate => {
            const member = try dec.int(u64);
            try dec.finish();
            daemon.registry_mutex.lockUncancelable(daemon.io);
            daemon.display.separate(member) catch {
                daemon.registry_mutex.unlock(daemon.io);
                return sendProtocolError(fd, "session is not paired");
            };
            daemon.registry_mutex.unlock(daemon.io);
            try sendOk(fd);
            broadcast(0, .{ .registry = true });
        },
        .display_focus => {
            const member = try dec.int(u64);
            try dec.finish();
            daemon.registry_mutex.lockUncancelable(daemon.io);
            daemon.display.rememberFocus(member) catch {
                daemon.registry_mutex.unlock(daemon.io);
                return sendProtocolError(fd, "session is not paired");
            };
            daemon.registry_mutex.unlock(daemon.io);
            try sendOk(fd);
            broadcast(0, .{ .registry = true });
        },
        .display_ratio => {
            const member = try dec.int(u64);
            const ratio = try dec.int(u16);
            try dec.finish();
            daemon.registry_mutex.lockUncancelable(daemon.io);
            daemon.display.setRatio(member, ratio) catch {
                daemon.registry_mutex.unlock(daemon.io);
                return sendProtocolError(fd, "invalid pair ratio");
            };
            daemon.registry_mutex.unlock(daemon.io);
            try sendOk(fd);
            broadcast(0, .{ .registry = true });
        },
        .display_zoom => {
            const member = try dec.int(u64);
            const zoomed = try dec.boolean();
            try dec.finish();
            daemon.registry_mutex.lockUncancelable(daemon.io);
            daemon.display.setZoom(member, zoomed) catch {
                daemon.registry_mutex.unlock(daemon.io);
                return sendProtocolError(fd, "session is not paired");
            };
            daemon.registry_mutex.unlock(daemon.io);
            try sendOk(fd);
            broadcast(0, .{ .registry = true });
        },
        .display_move => {
            const member = try dec.int(u64);
            const destination = try dec.int(u32);
            try dec.finish();
            daemon.registry_mutex.lockUncancelable(daemon.io);
            daemon.display.move(member, destination) catch {
                daemon.registry_mutex.unlock(daemon.io);
                return sendProtocolError(fd, "invalid display move");
            };
            daemon.registry_mutex.unlock(daemon.io);
            try sendOk(fd);
            broadcast(0, .{ .registry = true });
        },
        .display_swap => {
            const member = try dec.int(u64);
            try dec.finish();
            daemon.registry_mutex.lockUncancelable(daemon.io);
            daemon.display.swap(member) catch {
                daemon.registry_mutex.unlock(daemon.io);
                return sendProtocolError(fd, "session is not paired");
            };
            daemon.registry_mutex.unlock(daemon.io);
            try sendOk(fd);
            broadcast(0, .{ .registry = true });
        },
        .display_transfer => {
            const member = try dec.int(u64);
            const target = try dec.int(u64);
            const member_on_left = try dec.boolean();
            try dec.finish();
            daemon.registry_mutex.lockUncancelable(daemon.io);
            const focused = daemon.focused_session_id;
            daemon.display.transferMember(member, target, member_on_left, focused) catch {
                daemon.registry_mutex.unlock(daemon.io);
                return sendProtocolError(fd, "invalid pair member transfer");
            };
            daemon.registry_mutex.unlock(daemon.io);
            try sendOk(fd);
            broadcast(0, .{ .registry = true });
        },
        .display_extract => {
            const member = try dec.int(u64);
            const destination = try dec.int(u32);
            try dec.finish();
            daemon.registry_mutex.lockUncancelable(daemon.io);
            daemon.display.extractMember(member, destination) catch {
                daemon.registry_mutex.unlock(daemon.io);
                return sendProtocolError(fd, "invalid pair member extraction");
            };
            daemon.registry_mutex.unlock(daemon.io);
            try sendOk(fd);
            broadcast(0, .{ .registry = true });
        },
        .foreground => {
            const session = acquireSession(try dec.int(u64)) orelse
                return sendProtocolError(fd, "unknown session");
            defer session.release();
            try dec.finish();
            const foreground = !session.exited.load(.acquire) and session.pty.hasForegroundJob();
            try protocol.writeFrame(fd, .bool_result, &.{@intFromBool(foreground)});
        },
        .clear_scrollback => {
            const session = acquireSession(try dec.int(u64)) orelse
                return sendProtocolError(fd, "unknown session");
            defer session.release();
            try dec.finish();
            session.mutex.lockUncancelable(session.io);
            session.v.term.clearScrollback();
            session.mutex.unlock(session.io);
            try sendOk(fd);
            broadcast(session.id, .{ .grid = true });
        },
        .force_sync => {
            const session = acquireSession(try dec.int(u64)) orelse
                return sendProtocolError(fd, "unknown session");
            defer session.release();
            try dec.finish();
            session.mutex.lockUncancelable(session.io);
            session.v.term.forceEndSynchronizedOutput();
            session.mutex.unlock(session.io);
            try sendOk(fd);
            broadcast(session.id, .{ .grid = true });
        },
        .scroll => {
            const session = acquireSession(try dec.int(u64)) orelse
                return sendProtocolError(fd, "unknown session");
            defer session.release();
            const delta: i64 = @bitCast(try dec.int(u64));
            try dec.finish();
            session.mutex.lockUncancelable(session.io);
            const before = session.v.term.viewportOffset();
            session.v.term.scrollViewport(delta);
            const moved = session.v.term.viewportOffset() != before;
            session.mutex.unlock(session.io);
            try protocol.writeFrame(fd, .bool_result, &.{@intFromBool(moved)});
            if (moved) broadcast(session.id, .{ .grid = true });
        },
        .selection_start => {
            const session = acquireSession(try dec.int(u64)) orelse
                return sendProtocolError(fd, "unknown session");
            defer session.release();
            const mode = std.enums.fromInt(vt.terminal.SelectionMode, try dec.byte()) orelse
                return error.InvalidSelectionMode;
            const row = try dec.int(u16);
            const col = try dec.int(u16);
            try dec.finish();
            session.mutex.lockUncancelable(session.io);
            session.v.term.selectionStart(row, col, mode);
            session.mutex.unlock(session.io);
            try sendOk(fd);
            broadcast(session.id, .{ .grid = true });
        },
        .selection_drag => {
            const session = acquireSession(try dec.int(u64)) orelse
                return sendProtocolError(fd, "unknown session");
            defer session.release();
            const row = try dec.int(u16);
            const col = try dec.int(u16);
            try dec.finish();
            session.mutex.lockUncancelable(session.io);
            session.v.term.selectionDrag(row, col);
            session.mutex.unlock(session.io);
            try sendOk(fd);
            broadcast(session.id, .{ .grid = true });
        },
        .selection_clear => {
            const session = acquireSession(try dec.int(u64)) orelse
                return sendProtocolError(fd, "unknown session");
            defer session.release();
            try dec.finish();
            session.mutex.lockUncancelable(session.io);
            session.v.term.selectionClear();
            session.mutex.unlock(session.io);
            try sendOk(fd);
            broadcast(session.id, .{ .grid = true });
        },
        .selection_text => {
            const session = acquireSession(try dec.int(u64)) orelse
                return sendProtocolError(fd, "unknown session");
            defer session.release();
            try dec.finish();
            session.mutex.lockUncancelable(session.io);
            const text = session.v.term.selectionText(daemon.gpa) catch null;
            session.mutex.unlock(session.io);
            defer if (text) |bytes| daemon.gpa.free(bytes);
            var enc = protocol.Encoder.init(daemon.gpa);
            defer enc.deinit();
            try enc.boolean(text != null);
            if (text) |bytes| try enc.bytes(bytes);
            try protocol.writeFrame(fd, .bytes_result, enc.slice());
        },
        else => return sendProtocolError(fd, "invalid command tag"),
    }
}

const CreatePlacement = union(enum) {
    single,
    beside: u64,
};

/// Serialize session publication with the destructive lifecycle transition.
/// A create that enters first is visible to terminateAll's ordinary close
/// loop; a create that enters after draining begins is rejected.
fn createSessionWhileAccepting(
    cols: u16,
    rows: u16,
    requested_cwd: ?[]const u8,
    placement: CreatePlacement,
) !*session_mod.Session {
    daemon.lifecycle_mutex.lockUncancelable(daemon.io);
    defer daemon.lifecycle_mutex.unlock(daemon.io);
    if (daemon.draining.load(.acquire)) return error.DaemonDraining;
    return createSession(cols, rows, requested_cwd, placement);
}

fn createSession(
    cols: u16,
    rows: u16,
    requested_cwd: ?[]const u8,
    placement: CreatePlacement,
) !*session_mod.Session {
    daemon.registry_mutex.lockUncancelable(daemon.io);
    const id = daemon.next_session_id;
    daemon.next_session_id += 1;
    daemon.registry_mutex.unlock(daemon.io);

    var cwd_buf: [pty_mod.max_path_len]u8 = undefined;
    const cwd_source_id: ?u64 = switch (placement) {
        .single => null,
        .beside => |existing_id| existing_id,
    };
    const cwd = requested_cwd orelse
        inheritedWorkingDirectory(&cwd_buf, cwd_source_id) orelse
        daemon.env.get("HOME");

    const session = try session_mod.Session.create(
        daemon.gpa,
        daemon.io,
        daemon.env,
        id,
        cols,
        rows,
        cwd,
    );
    errdefer session.destroyUnstarted();
    var registered = false;
    errdefer if (registered) {
        daemon.registry_mutex.lockUncancelable(daemon.io);
        if (findSessionIndexLocked(id)) |index| _ = daemon.sessions.remove(index);
        daemon.display.removeSession(id) catch unreachable;
        daemon.registry_mutex.unlock(daemon.io);
    };
    daemon.registry_mutex.lockUncancelable(daemon.io);
    _ = daemon.sessions.append(session) catch |err| {
        daemon.registry_mutex.unlock(daemon.io);
        return err;
    };
    (switch (placement) {
        .single => daemon.display.appendSingle(id),
        .beside => |existing_id| daemon.display.appendBeside(existing_id, id),
    }) catch |err| {
        _ = daemon.sessions.remove(daemon.sessions.sessions.items.len - 1);
        daemon.registry_mutex.unlock(daemon.io);
        return err;
    };
    registered = true;
    daemon.registry_mutex.unlock(daemon.io);
    session.retain();
    errdefer session.release();
    try session.startReader(daemonSessionChanged);
    return session;
}

fn closeSession(id: u64) !void {
    daemon.registry_mutex.lockUncancelable(daemon.io);
    const index = findSessionIndexLocked(id) orelse {
        daemon.registry_mutex.unlock(daemon.io);
        return error.UnknownSession;
    };
    const session = daemon.sessions.remove(index).?;
    daemon.display.removeSession(id) catch unreachable;
    daemon.registry_mutex.unlock(daemon.io);
    if (!session.exited.load(.acquire)) {
        session.pty.hangup();
        session.retain();
        const escalation = std.Thread.spawn(.{}, closeAfterGrace, .{session}) catch {
            session.release();
            session.pty.kill();
            session.release();
            return;
        };
        escalation.detach();
    }
    session.release();
}

fn closeAfterGrace(session: *session_mod.Session) void {
    defer session.release();
    session.io.sleep(.fromSeconds(2), .awake) catch {};
    if (!session.exited.load(.acquire)) session.pty.kill();
}

fn acquireSession(id: u64) ?*session_mod.Session {
    daemon.registry_mutex.lockUncancelable(daemon.io);
    defer daemon.registry_mutex.unlock(daemon.io);
    for (daemon.sessions.sessions.items) |session| {
        if (session.id == id) {
            session.retain();
            return session;
        }
    }
    return null;
}

fn findSessionIndexLocked(id: u64) ?usize {
    for (daemon.sessions.sessions.items, 0..) |session, index| {
        if (session.id == id) return index;
    }
    return null;
}

fn setFocus(fd: c.fd_t, id: u64, focused: bool) bool {
    daemon.registry_mutex.lockUncancelable(daemon.io);
    defer daemon.registry_mutex.unlock(daemon.io);
    if (focused) {
        var exists = false;
        for (daemon.sessions.sessions.items) |session| {
            if (session.id == id) {
                exists = true;
                break;
            }
        }
        if (!exists) return false;
        daemon.display.rememberFocus(id) catch |err| switch (err) {
            error.NotPaired => {},
            else => unreachable,
        };
    } else if (daemon.focus_owner_fd != fd) return true;
    daemon.focus_owner_fd = if (focused) fd else -1;
    daemon.focused_session_id = if (focused) id else null;
    for (daemon.sessions.sessions.items) |session| {
        session.setFocused(focused and session.id == id);
    }
    return true;
}

fn clearFocusFor(fd: c.fd_t) void {
    daemon.registry_mutex.lockUncancelable(daemon.io);
    defer daemon.registry_mutex.unlock(daemon.io);
    if (daemon.focus_owner_fd != fd) return;
    daemon.focus_owner_fd = -1;
    daemon.focused_session_id = null;
    for (daemon.sessions.sessions.items) |session| session.setFocused(false);
}

fn inheritedWorkingDirectory(out: *[pty_mod.max_path_len]u8, preferred_id: ?u64) ?[]const u8 {
    daemon.registry_mutex.lockUncancelable(daemon.io);
    const focused_id = preferred_id orelse daemon.focused_session_id orelse {
        daemon.registry_mutex.unlock(daemon.io);
        return null;
    };
    const session = blk: {
        for (daemon.sessions.sessions.items) |candidate| {
            if (candidate.id == focused_id) {
                candidate.retain();
                break :blk candidate;
            }
        }
        daemon.registry_mutex.unlock(daemon.io);
        return null;
    };
    daemon.registry_mutex.unlock(daemon.io);
    defer session.release();
    if (session.copyWorkingDirectorySnapshot(out)) |reported|
        if (working_directory.isDirectory(daemon.io, reported)) return reported;
    return session.pty.foregroundWorkingDirectory(out);
}

fn encodeSessionMetadata(enc: *protocol.Encoder, session: *session_mod.Session) !void {
    var title_buf: [512]u8 = undefined;
    var cwd_buf: [pty_mod.max_path_len]u8 = undefined;
    const title = session.copyTitleSnapshot(&title_buf);
    const cwd = session.copyWorkingDirectorySnapshot(&cwd_buf);
    try protocol.encodeMetadata(enc, .{
        .id = session.id,
        .title = @constCast(title),
        .exited = session.exited.load(.acquire),
        .working = session.working.load(.acquire),
        .attention = session.needsAttention(),
        .cwd = if (cwd) |path| @constCast(path) else null,
    });
}

fn searchSession(
    session: *session_mod.Session,
    request: protocol.SearchRequest,
) !protocol.SearchResult {
    // The terminal mutex protects only the bounded detach/reveal phases.
    // Canonical normalization and matching run after the corpus is owned by
    // this command thread, never on the PTY kqueue thread (RFC 0016).
    var attempt: u8 = 0;
    while (attempt < 3) : (attempt += 1) {
        var corpus = captureSearchCorpus(session) catch |err| switch (err) {
            error.SearchCorpusChanged => continue,
            else => return err,
        };
        defer corpus.deinit(daemon.gpa);

        var found = try corpus.find(daemon.gpa, request.query);
        defer found.deinit(daemon.gpa);
        const count = @as(usize, corpus.cols) * corpus.screen_rows;
        const match_cells = try daemon.gpa.alloc(bool, count);
        errdefer daemon.gpa.free(match_cells);
        const selected_cells = try daemon.gpa.alloc(bool, count);
        errdefer daemon.gpa.free(selected_cells);
        @memset(match_cells, false);
        @memset(selected_cells, false);

        session.mutex.lockUncancelable(session.io);
        const term = session.v.term;
        if (term.state_epoch != corpus.state_epoch or
            term.cols != corpus.cols or term.rows != corpus.screen_rows or
            term.on_alt != corpus.on_alt)
        {
            session.mutex.unlock(session.io);
            daemon.gpa.free(match_cells);
            daemon.gpa.free(selected_cells);
            continue;
        }

        var selected_index = chooseSearchIndex(
            found.matches,
            request.operation,
            request.current,
            term.searchViewTopId(),
        );
        if (selected_index != null and request.operation != .refresh and
            !term.revealSearchMatch(found.matches[selected_index.?]))
        {
            session.mutex.unlock(session.io);
            daemon.gpa.free(match_cells);
            daemon.gpa.free(selected_cells);
            continue;
        }
        if (selected_index) |index| {
            if (!term.searchMatchLive(found.matches[index])) selected_index = null;
        }

        const top_id = term.searchViewTopId();
        markVisibleSearchMatches(term, found.matches, top_id, match_cells);
        if (selected_index) |index|
            markVisibleSearchMatches(term, found.matches[index .. index + 1], top_id, selected_cells);
        const grid_epoch = term.state_epoch;
        session.mutex.unlock(session.io);

        return .{
            .cols = corpus.cols,
            .rows = corpus.screen_rows,
            .grid_epoch = grid_epoch,
            .total = @intCast(found.matches.len),
            .truncated = found.truncated,
            .selected_index = if (selected_index) |index| @intCast(index) else null,
            .selected = if (selected_index) |index| found.matches[index] else null,
            .matches = match_cells,
            .selected_cells = selected_cells,
        };
    }
    return unavailableSearchResult(session);
}

/// Continuous output is expected, not a protocol failure. If three bounded
/// capture attempts all race grid mutation, return a deliberately stale
/// generation. The viewer still fetches and presents the current snapshot,
/// discards these masks, and retries the viewer-local search on the next
/// invalidation instead of freezing terminal refresh behind a search error.
fn unavailableSearchResult(session: *session_mod.Session) !protocol.SearchResult {
    session.mutex.lockUncancelable(session.io);
    const cols = session.v.term.cols;
    const rows = session.v.term.rows;
    session.mutex.unlock(session.io);
    const count = @as(usize, cols) * rows;
    const matches = try daemon.gpa.alloc(bool, count);
    errdefer daemon.gpa.free(matches);
    const selected_cells = try daemon.gpa.alloc(bool, count);
    @memset(matches, false);
    @memset(selected_cells, false);
    return .{
        .cols = cols,
        .rows = rows,
        .grid_epoch = 0,
        .total = 0,
        .truncated = false,
        .selected_index = null,
        .selected = null,
        .matches = matches,
        .selected_cells = selected_cells,
    };
}

fn captureSearchCorpus(session: *session_mod.Session) !vt.search.Corpus {
    session.mutex.lockUncancelable(session.io);
    const descriptor = session.v.term.searchCorpusDescriptor();
    session.mutex.unlock(session.io);

    var corpus = try vt.search.Corpus.init(daemon.gpa, descriptor);
    errdefer corpus.deinit(daemon.gpa);

    session.mutex.lockUncancelable(session.io);
    const copied_graphemes = session.v.term.copySearchCorpusGraphemes(
        descriptor,
        corpus.graphemes,
    );
    session.mutex.unlock(session.io);
    if (!copied_graphemes) return error.SearchCorpusChanged;

    const rows_per_batch: usize = 64;
    var start: usize = 0;
    while (start < descriptor.row_count) : (start += rows_per_batch) {
        const count = @min(rows_per_batch, descriptor.row_count - start);
        session.mutex.lockUncancelable(session.io);
        const copied = session.v.term.copySearchCorpusRows(
            descriptor,
            &corpus,
            start,
            count,
        );
        session.mutex.unlock(session.io);
        if (!copied) return error.SearchCorpusChanged;
    }
    return corpus;
}

fn chooseSearchIndex(
    matches: []const vt.search.Match,
    operation: protocol.SearchOperation,
    current: ?vt.search.Match,
    view_top: u64,
) ?usize {
    if (matches.len == 0) return null;
    var current_index: ?usize = null;
    if (current) |needle| {
        for (matches, 0..) |candidate, index| {
            if (searchMatchEqual(candidate, needle)) {
                current_index = index;
                break;
            }
        }
    }
    if (operation == .refresh) return current_index;
    if (current_index) |index| return switch (operation) {
        .next => (index + 1) % matches.len,
        .previous => if (index == 0) matches.len - 1 else index - 1,
        .initial => index,
        .refresh => unreachable,
    };

    var first_visible: usize = 0;
    for (matches, 0..) |candidate, index| {
        if (candidate.start.row_id >= view_top) {
            first_visible = index;
            break;
        }
    }
    return if (operation == .previous)
        (if (first_visible == 0) matches.len - 1 else first_visible - 1)
    else
        first_visible;
}

fn searchMatchEqual(a: vt.search.Match, b: vt.search.Match) bool {
    return a.start.row_id == b.start.row_id and a.start.col == b.start.col and
        a.end.row_id == b.end.row_id and a.end.col == b.end.col;
}

fn markVisibleSearchMatches(
    term: *const vt.Terminal,
    matches: []const vt.search.Match,
    top_id: u64,
    mask: []bool,
) void {
    const bottom_id = top_id + term.rows - 1;
    for (matches) |match| {
        if (match.end.row_id < top_id or match.start.row_id > bottom_id) continue;
        var row_id = @max(match.start.row_id, top_id);
        const end_row = @min(match.end.row_id, bottom_id);
        while (row_id <= end_row) : (row_id += 1) {
            const row: u16 = @intCast(row_id - top_id);
            const from: u16 = if (row_id == match.start.row_id) match.start.col else 0;
            const to: u16 = if (row_id == match.end.row_id) match.end.col else term.cols - 1;
            if (from >= term.cols) continue;
            var col = from;
            while (col <= @min(to, term.cols - 1)) : (col += 1)
                mask[@as(usize, row) * term.cols + col] = true;
        }
    }
    // A wide spacer has no searchable text, but highlighting only its head
    // would paint half a glyph cell.
    var row: u16 = 0;
    while (row < term.rows) : (row += 1) {
        var col: u16 = 1;
        while (col < term.cols) : (col += 1) {
            const index = @as(usize, row) * term.cols + col;
            if (term.viewCellAt(row, col).flags.wide_spacer and mask[index - 1])
                mask[index] = true;
        }
    }
}

fn captureSnapshot(session: *session_mod.Session) !protocol.Snapshot {
    session.mutex.lockUncancelable(session.io);
    defer session.mutex.unlock(session.io);
    const term = session.v.term;
    const count = @as(usize, term.cols) * term.rows;
    const cells = try daemon.gpa.alloc(vt.Cell, count);
    errdefer daemon.gpa.free(cells);
    var graphemes: std.ArrayList(u21) = .empty;
    errdefer graphemes.deinit(daemon.gpa);
    var hyperlinks: std.ArrayList(protocol.Hyperlink) = .empty;
    errdefer {
        for (hyperlinks.items) |*link| link.deinit(daemon.gpa);
        hyperlinks.deinit(daemon.gpa);
    }
    var hyperlink_ids: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer hyperlink_ids.deinit(daemon.gpa);
    const selected = try daemon.gpa.alloc(bool, count);
    errdefer daemon.gpa.free(selected);
    var images: std.ArrayList(protocol.ImageRef) = .empty;
    errdefer images.deinit(daemon.gpa);
    var placements: std.ArrayList(protocol.Placement) = .empty;
    errdefer placements.deinit(daemon.gpa);
    var row: u16 = 0;
    while (row < term.rows) : (row += 1) {
        var col: u16 = 0;
        while (col < term.cols) : (col += 1) {
            const index = @as(usize, row) * term.cols + col;
            var cell = term.viewCellAt(row, col);
            if (cell.hasGrapheme()) {
                const suffix = term.viewCellGrapheme(cell);
                cell.grapheme_offset = @intCast(graphemes.items.len);
                try graphemes.appendSlice(daemon.gpa, suffix);
            }
            if (cell.hyperlink_id != 0) {
                const entry = try hyperlink_ids.getOrPut(daemon.gpa, cell.hyperlink_id);
                if (!entry.found_existing) {
                    const source = term.hyperlink(cell.hyperlink_id) orelse {
                        entry.value_ptr.* = 0;
                        cell.hyperlink_id = 0;
                        cells[index] = cell;
                        selected[index] = term.viewCellSelected(row, col);
                        continue;
                    };
                    const explicit_id = try daemon.gpa.dupe(u8, source.explicit_id);
                    errdefer daemon.gpa.free(explicit_id);
                    const uri = try daemon.gpa.dupe(u8, source.uri);
                    errdefer daemon.gpa.free(uri);
                    try hyperlinks.append(daemon.gpa, .{
                        .explicit_id = explicit_id,
                        .uri = uri,
                    });
                    entry.value_ptr.* = @intCast(hyperlinks.items.len);
                }
                cell.hyperlink_id = entry.value_ptr.*;
            }
            cells[index] = cell;
            selected[index] = term.viewCellSelected(row, col);
        }
    }
    var title_buf: [512]u8 = undefined;
    const title = try daemon.gpa.dupe(u8, session.copyTitleSnapshot(&title_buf));
    errdefer daemon.gpa.free(title);
    const grapheme_slice = try graphemes.toOwnedSlice(daemon.gpa);
    errdefer daemon.gpa.free(grapheme_slice);
    const hyperlink_slice = try hyperlinks.toOwnedSlice(daemon.gpa);
    errdefer {
        for (hyperlink_slice) |*link| link.deinit(daemon.gpa);
        daemon.gpa.free(hyperlink_slice);
    }
    var anchors: std.ArrayList(GraphicsAnchor) = .empty;
    defer anchors.deinit(daemon.gpa);
    for (term.graphicsPlacements()) |placement| {
        if (placement.virtual or placement.parent_internal_id != 0) continue;
        const view_row = term.graphicsPlacementViewRow(placement) orelse continue;
        try anchors.append(daemon.gpa, .{
            .internal_id = placement.internal_id,
            .row = view_row,
            .col = placement.col,
        });
        try appendPhysicalPlacement(session, term, placement, view_row, placement.col, &images, &placements);
    }
    try appendVirtualPlacements(
        session,
        term,
        cells,
        grapheme_slice,
        &images,
        &placements,
        &anchors,
    );
    var depth: usize = 0;
    while (depth < vt.graphics.max_parent_depth) : (depth += 1) {
        var progressed = false;
        for (term.graphicsPlacements()) |placement| {
            if (placement.parent_internal_id == 0 or findGraphicsAnchor(anchors.items, placement.internal_id) != null)
                continue;
            const parent = findGraphicsAnchor(anchors.items, placement.parent_internal_id) orelse continue;
            const anchor_row = std.math.add(i64, parent.row, placement.parent_offset_y) catch continue;
            const anchor_col = std.math.add(i64, parent.col, placement.parent_offset_x) catch continue;
            try anchors.append(daemon.gpa, .{
                .internal_id = placement.internal_id,
                .row = anchor_row,
                .col = anchor_col,
            });
            try appendPhysicalPlacement(session, term, placement, anchor_row, anchor_col, &images, &placements);
            progressed = true;
        }
        if (!progressed) break;
    }
    const image_slice = try images.toOwnedSlice(daemon.gpa);
    errdefer daemon.gpa.free(image_slice);
    const placement_slice = try placements.toOwnedSlice(daemon.gpa);
    errdefer daemon.gpa.free(placement_slice);
    return .{
        .id = session.id,
        .cols = term.cols,
        .rows = term.rows,
        .col = term.col,
        .row = term.row,
        .viewport_offset = term.viewportOffset(),
        .sync_output_epoch = term.sync_output_epoch,
        .grid_epoch = term.state_epoch,
        .modes = .{
            .on_alt = term.on_alt,
            .cursor_visible = term.modes.cursor_visible,
            .synchronized_output = term.modes.synchronized_output,
            .grapheme_cluster = term.modes.grapheme_cluster,
            .focus_reporting = term.modes.focus_reporting,
            .mouse_reporting = term.modes.mouse_tracking != .none,
            .pointer_shape = term.pointer_shape,
        },
        .exited = session.exited.load(.acquire),
        .working = session.working.load(.acquire),
        .attention = session.needsAttention(),
        .title = title,
        .cells = cells,
        .graphemes = grapheme_slice,
        .hyperlinks = hyperlink_slice,
        .selected = selected,
        .images = image_slice,
        .placements = placement_slice,
    };
}

const GraphicsAnchor = struct {
    internal_id: u64,
    row: i64,
    col: i64,
};

fn findGraphicsAnchor(anchors: []const GraphicsAnchor, internal_id: u64) ?GraphicsAnchor {
    for (anchors) |anchor| if (anchor.internal_id == internal_id) return anchor;
    return null;
}

fn appendImageRef(images: *std.ArrayList(protocol.ImageRef), render: graphics_mod.RenderView) !void {
    for (images.items) |existing| {
        if (existing.id == render.id and existing.generation == render.frame.generation) return;
    }
    try images.append(daemon.gpa, .{
        .id = render.id,
        .generation = render.frame.generation,
        .width = render.width,
        .height = render.height,
    });
}

fn appendPhysicalPlacement(
    session: *session_mod.Session,
    term: *const vt.Terminal,
    placement: vt.graphics.Placement,
    view_row: i64,
    view_col: i64,
    images: *std.ArrayList(protocol.ImageRef),
    placements: *std.ArrayList(protocol.Placement),
) !void {
    var geometry = term.graphicsPlacementGeometry(placement) catch return;
    if (geometry.source_width == 0 or geometry.source_height == 0 or
        geometry.dest_width == 0 or geometry.dest_height == 0 or
        geometry.grid_cols == 0 or geometry.grid_rows == 0)
        return;
    const bottom_row = view_row +| geometry.grid_rows;
    if (bottom_row <= 0 or view_row >= term.rows) return;
    const render = session.graphics_store.currentRender(placement.image_id, placement.generation) orelse return;

    var render_col = view_col;
    var cell_offset_x = placement.cell_offset_x;
    if (render_col < 0) {
        if (term.cols == 0 or term.pixel_width < term.cols) return;
        const cell_width = term.pixel_width / term.cols;
        const origin_x = std.math.mul(i64, render_col, cell_width) catch return;
        const shifted_origin = std.math.add(i64, origin_x, cell_offset_x) catch return;
        if (shifted_origin < 0) {
            const hidden: u64 = @intCast(-shifted_origin);
            if (hidden >= geometry.dest_width) return;
            const source_hidden: u32 = @intCast(
                (@as(u64, geometry.source_width) * hidden) / geometry.dest_width,
            );
            geometry.source_x +|= source_hidden;
            geometry.source_width -= source_hidden;
            geometry.dest_width -= @intCast(hidden);
        }
        render_col = 0;
        cell_offset_x = 0;
    }
    if (render_col >= term.cols) return;
    const row_i32 = std.math.cast(i32, view_row) orelse return;
    const col_u16 = std.math.cast(u16, render_col) orelse return;
    try appendImageRef(images, render);
    try placements.append(daemon.gpa, .{
        .image_id = placement.image_id,
        .generation = render.frame.generation,
        .placement_id = placement.placement_id,
        .row = row_i32,
        .col = col_u16,
        .cell_offset_x = cell_offset_x,
        .cell_offset_y = placement.cell_offset_y,
        .source_x = geometry.source_x,
        .source_y = geometry.source_y,
        .source_width = geometry.source_width,
        .source_height = geometry.source_height,
        .dest_width = geometry.dest_width,
        .dest_height = geometry.dest_height,
        .z = placement.z,
    });
}

fn appendVirtualPlacements(
    session: *session_mod.Session,
    term: *const vt.Terminal,
    cells: []const vt.Cell,
    graphemes: []const u21,
    images: *std.ArrayList(protocol.ImageRef),
    placements: *std.ArrayList(protocol.Placement),
    anchors: *std.ArrayList(GraphicsAnchor),
) !void {
    var row: u16 = 0;
    while (row < term.rows) : (row += 1) {
        var builder: ?vt.graphics.unicode.Builder = null;
        var col: u16 = 0;
        while (col < term.cols) : (col += 1) {
            const cell = cells[@as(usize, row) * term.cols + col];
            if (cell.cp != vt.graphics.unicode_placeholder) {
                if (builder) |value| try appendVirtualRun(session, term, value.complete(), images, placements, anchors);
                builder = null;
                continue;
            }
            const suffix: []const u21 = if (cell.grapheme_len == 0)
                &.{}
            else
                graphemes[@as(usize, cell.grapheme_offset)..][0..cell.grapheme_len];
            const decoded = vt.graphics.unicode.decode(cell, suffix);
            if (builder) |*current| {
                if (current.append(decoded)) continue;
                try appendVirtualRun(session, term, current.complete(), images, placements, anchors);
            }
            builder = vt.graphics.unicode.Builder.init(decoded, row, col);
        }
        if (builder) |value| try appendVirtualRun(session, term, value.complete(), images, placements, anchors);
    }
}

fn appendVirtualRun(
    session: *session_mod.Session,
    term: *const vt.Terminal,
    placeholder_run: vt.graphics.unicode.Run,
    images: *std.ArrayList(protocol.ImageRef),
    placements: *std.ArrayList(protocol.Placement),
    anchors: *std.ArrayList(GraphicsAnchor),
) !void {
    if (placeholder_run.image_id == 0) return;
    const prototype = term.graphicsVirtualPlacement(
        placeholder_run.image_id,
        placeholder_run.placement_id,
    ) orelse return;
    if (findGraphicsAnchor(anchors.items, prototype.internal_id)) |existing| {
        for (anchors.items) |*anchor| {
            if (anchor.internal_id != prototype.internal_id) continue;
            anchor.row = @min(anchor.row, placeholder_run.screen_row);
            anchor.col = @min(anchor.col, placeholder_run.screen_col);
            break;
        }
        _ = existing;
    } else {
        try anchors.append(daemon.gpa, .{
            .internal_id = prototype.internal_id,
            .row = placeholder_run.screen_row,
            .col = placeholder_run.screen_col,
        });
    }
    const render = session.graphics_store.currentRender(prototype.image_id, prototype.generation) orelse return;
    if (term.cols == 0 or term.rows == 0 or term.pixel_width < term.cols or term.pixel_height < term.rows)
        return;
    const cell_width = term.pixel_width / term.cols;
    const cell_height = term.pixel_height / term.rows;
    const geometry = vt.graphics.unicode.renderGeometry(
        placeholder_run,
        render.width,
        render.height,
        prototype.columns,
        prototype.rows,
        cell_width,
        cell_height,
    ) orelse return;
    const screen_col = @as(u32, placeholder_run.screen_col) + geometry.col_advance;
    if (screen_col >= term.cols) return;

    try appendImageRef(images, render);
    try placements.append(daemon.gpa, .{
        .image_id = render.id,
        .generation = render.frame.generation,
        .placement_id = prototype.placement_id,
        .row = placeholder_run.screen_row,
        .col = @intCast(screen_col),
        .cell_offset_x = geometry.cell_offset_x,
        .cell_offset_y = geometry.cell_offset_y,
        .source_x = geometry.source_x,
        .source_y = geometry.source_y,
        .source_width = geometry.source_width,
        .source_height = geometry.source_height,
        .dest_width = geometry.dest_width,
        .dest_height = geometry.dest_height,
        .z = -1,
    });
}

fn sendOk(fd: c.fd_t) !void {
    try protocol.writeFrame(fd, .ok, &.{});
}

fn sendProtocolError(fd: c.fd_t, message: []const u8) !void {
    try protocol.writeFrame(fd, .protocol_error, message);
}
