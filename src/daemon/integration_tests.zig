const std = @import("std");
const protocol = @import("protocol.zig");
const lifecycle = @import("lifecycle.zig");
const daemon_client = @import("../shell/daemon_client.zig");
const session_mod = @import("../shell/session.zig");
const vt = @import("../vt.zig");
const test_options = @import("test_options");
const c = std.c;

const EventState = struct {
    invalidations: std.atomic.Value(usize) = .init(0),
    events: std.atomic.Value(usize) = .init(0),
};

fn recordEvent(context: ?*anyopaque, id: u64, _: protocol.EventFlags) void {
    const state: *EventState = @ptrCast(@alignCast(context.?));
    if (id == 0) {
        _ = state.invalidations.fetchAdd(1, .acq_rel);
    } else {
        _ = state.events.fetchAdd(1, .acq_rel);
    }
}

fn freeMetadata(alloc: std.mem.Allocator, entries: []protocol.Metadata) void {
    for (entries) |*entry| entry.deinit(alloc);
    alloc.free(entries);
}

fn snapshotContains(snapshot: *const protocol.Snapshot, needle: []const u8) bool {
    var matched: usize = 0;
    for (snapshot.cells) |cell| {
        if (cell.cp == needle[matched]) {
            matched += 1;
            if (matched == needle.len) return true;
        } else {
            matched = @intFromBool(cell.cp == needle[0]);
        }
    }
    return false;
}

fn expectReadinessMarkerHidden(command: []const u8, marker: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, command, marker) == null);
}

fn snapshotContainsAcuteE(snapshot: *const protocol.Snapshot) bool {
    for (snapshot.cells) |cell| {
        if (cell.cp != 'e' or !cell.hasGrapheme()) continue;
        if (std.mem.eql(u21, snapshot.viewCellGrapheme(cell), &.{0x0301})) return true;
    }
    return false;
}

fn acceptStagedImage(
    context: ?*anyopaque,
    image: *const daemon_client.StagedFetch,
) anyerror!*daemon_client.StagedUpload {
    const count: *usize = @ptrCast(@alignCast(context.?));
    const active_row = @as(usize, image.metadata.width) * 4;
    if (image.metadata.bytes_per_row < active_row or
        image.mapping_length < image.metadata.byte_length)
        return error.InvalidStagedTestImage;
    count.* += 1;
    const upload = try daemon_client.StagedUpload.create(
        std.testing.allocator,
        .{
            .session_id = image.session_id,
            .image_id = image.metadata.id,
            .generation = image.metadata.generation,
        },
        image.staging_key,
        image.metadata.width,
        image.metadata.height,
        image.metadata.bytes_per_row,
        null,
        null,
        image.release_context,
        image.release_fn,
    );
    // This integration helper has no Metal renderer. Model a successfully
    // retired frame so the real daemon release worker and slot reuse remain
    // under test without weakening the product ownership assertion.
    try upload.markSubmitted();
    try upload.finish(true);
    return upload;
}

const IdleStopRace = struct {
    const StopResult = enum(u8) { pending, stopped, busy, failed };
    const CreateResult = enum(u8) { pending, created, rejected, failed };

    io: std.Io,
    address: std.Io.net.UnixAddress,
    go: std.atomic.Value(bool) = .init(false),
    stop_ready: std.atomic.Value(bool) = .init(false),
    create_ready: std.atomic.Value(bool) = .init(false),
    stop_done: std.atomic.Value(bool) = .init(false),
    release_create: std.atomic.Value(bool) = .init(false),
    stop_result: std.atomic.Value(StopResult) = .init(.pending),
    create_result: std.atomic.Value(CreateResult) = .init(.pending),
    created_id: std.atomic.Value(u64) = .init(0),

    fn stop(self: *IdleStopRace) void {
        var stream = self.address.connect(self.io) catch {
            self.stop_result.store(.failed, .release);
            self.stop_ready.store(true, .release);
            self.stop_done.store(true, .release);
            return;
        };
        defer stream.close(self.io);
        self.stop_ready.store(true, .release);
        while (!self.go.load(.acquire)) std.atomic.spinLoopHint();
        lifecycle.writeFrame(stream.socket.handle, .stop_if_idle, &.{}) catch {
            self.stop_result.store(.failed, .release);
            self.stop_done.store(true, .release);
            return;
        };
        var response = lifecycle.readFrame(stream.socket.handle, std.heap.page_allocator) catch {
            self.stop_result.store(.failed, .release);
            self.stop_done.store(true, .release);
            return;
        };
        defer response.deinit(std.heap.page_allocator);
        const result: StopResult = if (response.payload.len != 0)
            .failed
        else switch (response.tag) {
            .ok => .stopped,
            .busy => .busy,
            else => .failed,
        };
        self.stop_result.store(result, .release);
        self.stop_done.store(true, .release);
    }

    fn create(self: *IdleStopRace) void {
        var stream = self.address.connect(self.io) catch {
            self.create_result.store(.failed, .release);
            self.create_ready.store(true, .release);
            return;
        };
        defer stream.close(self.io);
        self.create_ready.store(true, .release);
        var enc = protocol.Encoder.init(std.heap.page_allocator);
        defer enc.deinit();
        protocol.encodeCreateRequest(&enc, .{ .cols = 80, .rows = 24, .cwd = null }) catch {
            self.create_result.store(.failed, .release);
            return;
        };
        while (!self.go.load(.acquire)) std.atomic.spinLoopHint();
        protocol.writeFrame(stream.socket.handle, .create, enc.slice()) catch {
            self.create_result.store(.rejected, .release);
            return;
        };
        var response = protocol.readFrame(stream.socket.handle, std.heap.page_allocator) catch {
            self.create_result.store(.rejected, .release);
            return;
        };
        defer response.deinit(std.heap.page_allocator);
        if (response.tag != .metadata) {
            self.create_result.store(.failed, .release);
            return;
        }
        var dec: protocol.Decoder = .{ .bytes = response.payload };
        var metadata = protocol.decodeMetadata(&dec, std.heap.page_allocator) catch {
            self.create_result.store(.failed, .release);
            return;
        };
        defer metadata.deinit(std.heap.page_allocator);
        dec.finish() catch {
            self.create_result.store(.failed, .release);
            return;
        };
        self.created_id.store(metadata.id, .release);
        self.create_result.store(.created, .release);
        // Keep beginAttach's count live until the competing stop has made its
        // decision. This excludes a meaningless created-then-disconnected gap.
        while (!self.release_create.load(.acquire)) std.atomic.spinLoopHint();
    }
};

const TerminateCreateRace = struct {
    const TerminateResult = enum(u8) { pending, stopped, failed };
    const CreateResult = enum(u8) { pending, created, rejected, failed };

    io: std.Io,
    address: std.Io.net.UnixAddress,
    go: std.atomic.Value(bool) = .init(false),
    terminate_ready: std.atomic.Value(bool) = .init(false),
    create_ready: std.atomic.Value(bool) = .init(false),
    terminate_result: std.atomic.Value(TerminateResult) = .init(.pending),
    create_result: std.atomic.Value(CreateResult) = .init(.pending),

    fn terminate(self: *TerminateCreateRace) void {
        var stream = self.address.connect(self.io) catch {
            self.terminate_result.store(.failed, .release);
            self.terminate_ready.store(true, .release);
            return;
        };
        defer stream.close(self.io);
        self.terminate_ready.store(true, .release);
        while (!self.go.load(.acquire)) std.atomic.spinLoopHint();
        lifecycle.writeFrame(stream.socket.handle, .terminate_all, &.{}) catch {
            self.terminate_result.store(.failed, .release);
            return;
        };
        var response = lifecycle.readFrame(stream.socket.handle, std.heap.page_allocator) catch {
            self.terminate_result.store(.failed, .release);
            return;
        };
        defer response.deinit(std.heap.page_allocator);
        self.terminate_result.store(
            if (response.tag == .ok and response.payload.len == 0) .stopped else .failed,
            .release,
        );
    }

    fn create(self: *TerminateCreateRace) void {
        var stream = self.address.connect(self.io) catch {
            self.create_result.store(.failed, .release);
            self.create_ready.store(true, .release);
            return;
        };
        defer stream.close(self.io);
        self.create_ready.store(true, .release);
        var enc = protocol.Encoder.init(std.heap.page_allocator);
        defer enc.deinit();
        protocol.encodeCreateRequest(&enc, .{ .cols = 80, .rows = 24, .cwd = null }) catch {
            self.create_result.store(.failed, .release);
            return;
        };
        while (!self.go.load(.acquire)) std.atomic.spinLoopHint();
        protocol.writeFrame(stream.socket.handle, .create, enc.slice()) catch {
            self.create_result.store(.rejected, .release);
            return;
        };
        var response = protocol.readFrame(stream.socket.handle, std.heap.page_allocator) catch {
            self.create_result.store(.rejected, .release);
            return;
        };
        defer response.deinit(std.heap.page_allocator);
        if (response.tag == .protocol_error) {
            self.create_result.store(.rejected, .release);
            return;
        }
        if (response.tag != .metadata) {
            self.create_result.store(.failed, .release);
            return;
        }
        var dec: protocol.Decoder = .{ .bytes = response.payload };
        var metadata = protocol.decodeMetadata(&dec, std.heap.page_allocator) catch {
            self.create_result.store(.failed, .release);
            return;
        };
        defer metadata.deinit(std.heap.page_allocator);
        dec.finish() catch {
            self.create_result.store(.failed, .release);
            return;
        };
        self.create_result.store(.created, .release);
    }
};

test "lifecycle reports attachments and stops only when idle" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    var home_buf: [64]u8 = undefined;
    const home = try std.fmt.bufPrint(
        &home_buf,
        "/tmp/btl-{x}",
        .{std.mem.readInt(u64, &random_bytes, .little)},
    );
    try std.Io.Dir.createDirAbsolute(io, home, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    var env = try std.process.Environ.createMap(std.testing.environ, alloc);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("TMPDIR", home);

    var daemon_process = try std.process.spawn(io, .{
        .argv = &.{test_options.daemon_path},
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
    var daemon_running = true;
    defer if (daemon_running) daemon_process.kill(io);

    const socket_path = try protocol.socketPath(alloc, &env);
    defer alloc.free(socket_path);
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (address.connect(io)) |stream| {
            stream.close(io);
            break;
        } else |_| try io.sleep(.fromMilliseconds(20), .awake);
    } else return error.DaemonStartTimeout;

    var client = try daemon_client.Client.init(alloc, io, &env);
    try std.testing.expect(client.daemonIdentity().lifecycle_supported);
    try std.testing.expectEqual(protocol.version, client.attachDialect());
    // No session exists yet: the viewer's attach lanes alone must prevent a
    // lifecycle client from draining the daemon underneath it.
    try std.testing.expect(!(try client.stopDaemonIfIdle()));
    var created = try client.create(80, 24, null);
    const created_id = created.id;
    created.deinit(alloc);
    client.deinit();

    const lifecycle_stream = try address.connect(io);
    const lifecycle_fd = lifecycle_stream.socket.handle;
    try lifecycle.writeFrame(lifecycle_fd, .status, &.{});
    var status_frame = try lifecycle.readFrame(lifecycle_fd, alloc);
    defer status_frame.deinit(alloc);
    try std.testing.expectEqual(lifecycle.Tag.status_result, status_frame.tag);
    const status = try lifecycle.decodeStatus(status_frame.payload);
    try std.testing.expectEqual(@as(u32, 1), status.session_count);
    try std.testing.expectEqual(@as(u32, 0), status.attach_connection_count);
    try std.testing.expectEqualSlices(u16, &.{protocol.version}, status.supportedDialects());
    lifecycle_stream.close(io);

    // A daemon-owned session is independently sufficient to reject idle
    // shutdown after every viewer has detached.
    const busy_stream = try address.connect(io);
    try lifecycle.writeFrame(busy_stream.socket.handle, .stop_if_idle, &.{});
    var busy_frame = try lifecycle.readFrame(busy_stream.socket.handle, alloc);
    defer busy_frame.deinit(alloc);
    try std.testing.expectEqual(lifecycle.Tag.busy, busy_frame.tag);
    busy_stream.close(io);

    var cleanup_client = try daemon_client.Client.init(alloc, io, &env);
    try cleanup_client.closeSession(created_id);
    cleanup_client.deinit();

    const stop_stream = try address.connect(io);
    try lifecycle.writeFrame(stop_stream.socket.handle, .stop_if_idle, &.{});
    var stop_frame = try lifecycle.readFrame(stop_stream.socket.handle, alloc);
    defer stop_frame.deinit(alloc);
    try std.testing.expectEqual(lifecycle.Tag.ok, stop_frame.tag);
    stop_stream.close(io);
    _ = try daemon_process.wait(io);
    daemon_running = false;
}

test "create racing stop_if_idle has one authoritative winner" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    var home_buf: [64]u8 = undefined;
    const home = try std.fmt.bufPrint(
        &home_buf,
        "/tmp/btl-race-{x}",
        .{std.mem.readInt(u64, &random_bytes, .little)},
    );
    try std.Io.Dir.createDirAbsolute(io, home, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    var env = try std.process.Environ.createMap(std.testing.environ, alloc);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("TMPDIR", home);
    var daemon_process = try std.process.spawn(io, .{
        .argv = &.{test_options.daemon_path},
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
    var daemon_running = true;
    defer if (daemon_running) daemon_process.kill(io);
    const socket_path = try protocol.socketPath(alloc, &env);
    defer alloc.free(socket_path);
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (address.connect(io)) |stream| {
            stream.close(io);
            break;
        } else |_| try io.sleep(.fromMilliseconds(20), .awake);
    } else return error.DaemonStartTimeout;

    var race: IdleStopRace = .{ .io = io, .address = address };
    const stop_thread = try std.Thread.spawn(.{}, IdleStopRace.stop, .{&race});
    const create_thread = try std.Thread.spawn(.{}, IdleStopRace.create, .{&race});
    while (!race.stop_ready.load(.acquire) or !race.create_ready.load(.acquire))
        std.atomic.spinLoopHint();
    race.go.store(true, .release);
    while (!race.stop_done.load(.acquire)) std.atomic.spinLoopHint();
    race.release_create.store(true, .release);
    stop_thread.join();
    create_thread.join();

    switch (race.stop_result.load(.acquire)) {
        .stopped => {
            try std.testing.expectEqual(IdleStopRace.CreateResult.rejected, race.create_result.load(.acquire));
            _ = try daemon_process.wait(io);
            daemon_running = false;
        },
        .busy => {
            try std.testing.expectEqual(IdleStopRace.CreateResult.created, race.create_result.load(.acquire));
            const created_id = race.created_id.load(.acquire);
            try std.testing.expect(created_id != 0);
            var client = try daemon_client.Client.init(alloc, io, &env);
            try client.closeSession(created_id);
            client.deinit();
            const stop_stream = try address.connect(io);
            try lifecycle.writeFrame(stop_stream.socket.handle, .stop_if_idle, &.{});
            var response = try lifecycle.readFrame(stop_stream.socket.handle, alloc);
            defer response.deinit(alloc);
            try std.testing.expectEqual(lifecycle.Tag.ok, response.tag);
            stop_stream.close(io);
            _ = try daemon_process.wait(io);
            daemon_running = false;
        },
        else => return error.InvalidIdleStopRaceOutcome,
    }
}

test "create racing terminate_all cannot publish after teardown" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    var home_buf: [64]u8 = undefined;
    const home = try std.fmt.bufPrint(
        &home_buf,
        "/tmp/btl-terminate-race-{x}",
        .{std.mem.readInt(u64, &random_bytes, .little)},
    );
    try std.Io.Dir.createDirAbsolute(io, home, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    var env = try std.process.Environ.createMap(std.testing.environ, alloc);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("TMPDIR", home);
    var daemon_process = try std.process.spawn(io, .{
        .argv = &.{test_options.daemon_path},
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
    var daemon_running = true;
    defer if (daemon_running) daemon_process.kill(io);
    const socket_path = try protocol.socketPath(alloc, &env);
    defer alloc.free(socket_path);
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (address.connect(io)) |stream| {
            stream.close(io);
            break;
        } else |_| try io.sleep(.fromMilliseconds(20), .awake);
    } else return error.DaemonStartTimeout;

    var race: TerminateCreateRace = .{ .io = io, .address = address };
    const terminate_thread = try std.Thread.spawn(.{}, TerminateCreateRace.terminate, .{&race});
    const create_thread = try std.Thread.spawn(.{}, TerminateCreateRace.create, .{&race});
    while (!race.terminate_ready.load(.acquire) or !race.create_ready.load(.acquire))
        std.atomic.spinLoopHint();
    race.go.store(true, .release);
    terminate_thread.join();
    create_thread.join();

    try std.testing.expectEqual(
        TerminateCreateRace.TerminateResult.stopped,
        race.terminate_result.load(.acquire),
    );
    switch (race.create_result.load(.acquire)) {
        .created, .rejected => {},
        else => return error.InvalidTerminateCreateRaceOutcome,
    }
    _ = try daemon_process.wait(io);
    daemon_running = false;
    if (address.connect(io)) |stream| {
        stream.close(io);
        return error.DaemonStillAcceptingAfterTerminate;
    } else |_| {}
}

test "daemon command and event connections survive subscription replacement" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    var home_buf: [64]u8 = undefined;
    const home = try std.fmt.bufPrint(
        &home_buf,
        "/tmp/bt-{x}",
        .{std.mem.readInt(u64, &random_bytes, .little)},
    );
    try std.Io.Dir.createDirAbsolute(io, home, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    const osc7_cwd = try std.fs.path.join(alloc, &.{ home, "osc7-target" });
    defer alloc.free(osc7_cwd);
    try std.Io.Dir.createDirAbsolute(io, osc7_cwd, .default_dir);

    var env = try std.process.Environ.createMap(std.testing.environ, alloc);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("TMPDIR", home);

    var daemon_process = try std.process.spawn(io, .{
        .argv = &.{test_options.daemon_path},
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
    defer daemon_process.kill(io);

    const socket_path = try protocol.socketPath(alloc, &env);
    defer alloc.free(socket_path);
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var connected = false;
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (address.connect(io)) |stream| {
            stream.close(io);
            connected = true;
            break;
        } else |_| {
            try io.sleep(.fromMilliseconds(20), .awake);
        }
    }
    try std.testing.expect(connected);

    var client = try daemon_client.Client.init(alloc, io, &env);
    defer client.deinit();
    const initial = try client.list();
    defer freeMetadata(alloc, initial);
    try std.testing.expectEqual(@as(usize, 0), initial.len);

    var event_state: EventState = .{};
    try client.startEvents(&event_state, recordEvent);
    const first_event_fd = client.event_fd.load(.acquire);
    try std.testing.expect(first_event_fd >= 0);
    _ = c.shutdown(first_event_fd, c.SHUT.RDWR);
    attempts = 0;
    while (event_state.invalidations.load(.acquire) < 2 and attempts < 100) : (attempts += 1) {
        try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(event_state.invalidations.load(.acquire) >= 2);
    try std.testing.expect(!client.isDisconnected());

    var beside_base = try client.create(80, 24, home);
    defer beside_base.deinit(alloc);
    var beside_created = try client.createBeside(beside_base.id, 40, 24, home);
    defer beside_created.deinit(alloc);
    var beside_registry = try client.listRegistry();
    try std.testing.expectEqual(@as(usize, 2), beside_registry.sessions.len);
    try std.testing.expectEqual(@as(usize, 1), beside_registry.display_items.len);
    try std.testing.expectEqual(beside_base.id, beside_registry.display_items[0].pair.left);
    try std.testing.expectEqual(beside_created.id, beside_registry.display_items[0].pair.right);
    try std.testing.expectEqual(beside_created.id, beside_registry.display_items[0].pair.focusedId());
    beside_registry.deinit(alloc);
    try std.testing.expectError(
        error.RemoteError,
        client.createBeside(beside_base.id, 40, 24, home),
    );
    var rejected_beside_registry = try client.listRegistry();
    try std.testing.expectEqual(@as(usize, 2), rejected_beside_registry.sessions.len);
    try std.testing.expectEqual(@as(usize, 1), rejected_beside_registry.display_items.len);
    rejected_beside_registry.deinit(alloc);
    try client.closeSession(beside_created.id);
    try client.closeSession(beside_base.id);

    var created = try client.create(80, 24, home);
    defer created.deinit(alloc);
    try std.testing.expectEqualStrings("Boring Terminal", created.title);
    try std.testing.expect(created.cwd == null);

    const osc7_command = try std.fmt.allocPrint(
        alloc,
        "printf '\\033]7;file://localhost{s}\\033\\\\'; sleep 0.1\n",
        .{osc7_cwd},
    );
    defer alloc.free(osc7_command);
    try client.writeInput(created.id, osc7_command);
    var saw_reported_cwd = false;
    attempts = 0;
    while (!saw_reported_cwd and attempts < 100) : (attempts += 1) {
        const entries = try client.list();
        defer freeMetadata(alloc, entries);
        for (entries) |entry| if (entry.id == created.id and entry.cwd != null and
            std.mem.eql(u8, entry.cwd.?, osc7_cwd))
        {
            saw_reported_cwd = true;
            break;
        };
        if (!saw_reported_cwd) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(saw_reported_cwd);

    // A remote authority is ignored without erasing the last trustworthy cwd.
    try client.writeInput(
        created.id,
        "printf '\\033]7;file://remote.invalid/tmp\\033\\\\'; sleep 0.1\n",
    );
    try io.sleep(.fromMilliseconds(150), .awake);
    const after_remote = try client.list();
    defer freeMetadata(alloc, after_remote);
    var found_after_remote = false;
    for (after_remote) |entry| if (entry.id == created.id) {
        try std.testing.expectEqualStrings(osc7_cwd, entry.cwd.?);
        found_after_remote = true;
        break;
    };
    try std.testing.expect(found_after_remote);

    var inherited = try client.createBeside(created.id, 80, 24, null);
    defer inherited.deinit(alloc);
    try client.writeInput(inherited.id, "pwd\n");
    var inherited_reported_cwd = false;
    attempts = 0;
    while (!inherited_reported_cwd and attempts < 100) : (attempts += 1) {
        var cwd_snapshot = try client.snapshot(inherited.id);
        defer cwd_snapshot.deinit(alloc);
        inherited_reported_cwd = snapshotContains(&cwd_snapshot, osc7_cwd);
        if (!inherited_reported_cwd) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(inherited_reported_cwd);
    try client.closeSession(inherited.id);

    // Empty OSC 7 explicitly restores the process-inspection fallback.
    try client.writeInput(created.id, "printf '\\033]7;\\033\\\\'; sleep 0.1\n");
    var saw_cwd_clear = false;
    attempts = 0;
    while (!saw_cwd_clear and attempts < 100) : (attempts += 1) {
        const entries = try client.list();
        defer freeMetadata(alloc, entries);
        for (entries) |entry| if (entry.id == created.id and entry.cwd == null) {
            saw_cwd_clear = true;
            break;
        };
        if (!saw_cwd_clear) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(saw_cwd_clear);

    var partner = try client.create(80, 24, home);
    defer partner.deinit(alloc);
    try client.pairSessions(created.id, partner.id);
    try client.rememberPairFocus(partner.id);
    try client.setPairRatio(partner.id, 40000);
    try client.setPairZoom(partner.id, true);
    var paired_registry = try client.listRegistry();
    try std.testing.expectEqual(@as(usize, 2), paired_registry.sessions.len);
    try std.testing.expectEqual(@as(usize, 1), paired_registry.display_items.len);
    try std.testing.expectEqual(created.id, paired_registry.display_items[0].pair.left);
    try std.testing.expectEqual(partner.id, paired_registry.display_items[0].pair.focusedId());
    try std.testing.expectEqual(@as(u16, 40000), paired_registry.display_items[0].pair.ratio);
    try std.testing.expect(paired_registry.display_items[0].pair.zoomed);
    paired_registry.deinit(alloc);
    var reattached_client = try daemon_client.Client.init(alloc, io, &env);
    var reattached_registry = try reattached_client.listRegistry();
    try std.testing.expectEqual(@as(usize, 1), reattached_registry.display_items.len);
    try std.testing.expectEqual(partner.id, reattached_registry.display_items[0].pair.focusedId());
    try std.testing.expectEqual(@as(u16, 40000), reattached_registry.display_items[0].pair.ratio);
    try std.testing.expect(reattached_registry.display_items[0].pair.zoomed);
    reattached_registry.deinit(alloc);
    reattached_client.deinit();
    try std.testing.expectError(error.RemoteError, client.pairSessions(created.id, partner.id));

    try client.swapPairSides(created.id);
    var swapped_registry = try client.listRegistry();
    try std.testing.expectEqual(partner.id, swapped_registry.display_items[0].pair.left);
    try std.testing.expectEqual(partner.id, swapped_registry.display_items[0].pair.focusedId());
    try std.testing.expect(swapped_registry.display_items[0].pair.zoomed);
    swapped_registry.deinit(alloc);
    try client.swapPairSides(created.id);

    var transfer_target = try client.create(80, 24, home);
    defer transfer_target.deinit(alloc);
    try client.transferPairMember(partner.id, transfer_target.id, false);
    var transferred_registry = try client.listRegistry();
    try std.testing.expectEqual(created.id, transferred_registry.display_items[0].single);
    try std.testing.expectEqual(transfer_target.id, transferred_registry.display_items[1].pair.left);
    try std.testing.expectEqual(partner.id, transferred_registry.display_items[1].pair.right);
    try std.testing.expect(!transferred_registry.display_items[1].pair.zoomed);
    transferred_registry.deinit(alloc);
    try client.transferPairMember(partner.id, created.id, false);
    try client.extractPairMember(partner.id, 1);
    var extracted_registry = try client.listRegistry();
    try std.testing.expectEqual(created.id, extracted_registry.display_items[0].single);
    try std.testing.expectEqual(partner.id, extracted_registry.display_items[1].single);
    try std.testing.expectEqual(transfer_target.id, extracted_registry.display_items[2].single);
    extracted_registry.deinit(alloc);
    try client.pairSessions(created.id, partner.id);
    try client.closeSession(transfer_target.id);

    try client.separateSessions(created.id);
    try client.moveDisplayItem(partner.id, 0);
    try client.pairSessions(created.id, partner.id);
    // Same-grid resize must still populate PTY/VT backing-pixel geometry.
    try client.resize(created.id, 80, 24, 800, 480);
    attempts = 0;
    while (event_state.events.load(.acquire) == 0 and attempts < 100) : (attempts += 1) {
        try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(event_state.events.load(.acquire) > 0);

    const oversized = try alloc.alloc(u8, session_mod.input_queue_capacity + 1);
    defer alloc.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.RemoteError, client.writeInput(created.id, oversized));
    try std.testing.expect(!client.isDisconnected());

    // Paste is semantic rather than a raw write: the daemon consults current
    // mode 2004 state. Outside bracketed mode it maps LF to Return and filters
    // controls before admitting the complete byte sequence.
    const raw_paste_path = try std.fs.path.join(alloc, &.{ home, "paste.raw" });
    defer alloc.free(raw_paste_path);
    const raw_paste_command = try std.fmt.allocPrint(
        alloc,
        // Encode the marker so the shell's echoed command line cannot satisfy
        // readiness before stty and DEC mode 2004 have taken effect.
        "stty raw -echo -icrnl -inlcr; printf '\\033[?2004l\\120\\101\\123\\124\\105\\137\\122\\101\\127\\137\\122\\105\\101\\104\\131\\r\\n'; " ++
            "dd bs=1 count=6 2>/dev/null | od -An -tx1 | tr -d ' \\n' > '{s}'; " ++
            "stty sane; printf 'PASTE_RAW_DONE\n'\n",
        .{raw_paste_path},
    );
    defer alloc.free(raw_paste_command);
    try expectReadinessMarkerHidden(raw_paste_command, "PASTE_RAW_READY");
    try client.writeInput(created.id, raw_paste_command);
    var paste_raw_ready = false;
    attempts = 0;
    while (!paste_raw_ready and attempts < 250) : (attempts += 1) {
        var paste_snapshot = try client.snapshot(created.id);
        defer paste_snapshot.deinit(alloc);
        paste_raw_ready = snapshotContains(&paste_snapshot, "PASTE_RAW_READY");
        if (!paste_raw_ready) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(paste_raw_ready);
    try client.paste(created.id, "a\nb\x1bc\x03");
    var saw_raw_paste = false;
    var observed_raw_paste: [64]u8 = @splat(0);
    var observed_raw_paste_len: usize = 0;
    attempts = 0;
    while (!saw_raw_paste and attempts < 250) : (attempts += 1) {
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            io,
            raw_paste_path,
            alloc,
            .limited(64),
        ) catch {
            try io.sleep(.fromMilliseconds(20), .awake);
            continue;
        };
        defer alloc.free(bytes);
        const trimmed = std.mem.trim(u8, bytes, " \r\n");
        observed_raw_paste_len = @min(trimmed.len, observed_raw_paste.len);
        @memcpy(observed_raw_paste[0..observed_raw_paste_len], trimmed[0..observed_raw_paste_len]);
        saw_raw_paste = std.mem.eql(u8, trimmed, "610d62206320");
        if (!saw_raw_paste) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expectEqualStrings("610d62206320", observed_raw_paste[0..observed_raw_paste_len]);

    // One request substantially larger than a typical PTY kernel buffer must
    // retain both framing delimiters and drain completely without per-line
    // pacing or a blocking daemon command thread.
    const large_paste_len = 256 * 1024;
    const large_encoded_len = large_paste_len + vt.paste.begin.len + vt.paste.end.len;
    const large_command = try std.fmt.allocPrint(
        alloc,
        "stty raw -echo; printf '\\033[?2004h\\120\\101\\123\\124\\105\\137\\114\\101\\122\\107\\105\\137\\122\\105\\101\\104\\131\\r\\n'; " ++
            "pasted=$(/usr/bin/head -c {d} | wc -c | tr -d ' '); " ++
            "printf '\\033[?2004l'; stty sane; printf 'PASTE_LARGE:%s\n' \"$pasted\"\n",
        .{large_encoded_len},
    );
    defer alloc.free(large_command);
    try expectReadinessMarkerHidden(large_command, "PASTE_LARGE_READY");
    try client.writeInput(created.id, large_command);
    var paste_large_ready = false;
    attempts = 0;
    while (!paste_large_ready and attempts < 250) : (attempts += 1) {
        var paste_snapshot = try client.snapshot(created.id);
        defer paste_snapshot.deinit(alloc);
        paste_large_ready = snapshotContains(&paste_snapshot, "PASTE_LARGE_READY");
        if (!paste_large_ready) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(paste_large_ready);
    const large_paste = try alloc.alloc(u8, large_paste_len);
    defer alloc.free(large_paste);
    @memset(large_paste, 'x');
    var line_end: usize = 79;
    while (line_end < large_paste.len) : (line_end += 80) large_paste[line_end] = '\n';
    try client.paste(created.id, large_paste);
    const large_result = try std.fmt.allocPrint(alloc, "PASTE_LARGE:{d}", .{large_encoded_len});
    defer alloc.free(large_result);
    var saw_large_paste = false;
    attempts = 0;
    while (!saw_large_paste and attempts < 250) : (attempts += 1) {
        var paste_snapshot = try client.snapshot(created.id);
        defer paste_snapshot.deinit(alloc);
        saw_large_paste = snapshotContains(&paste_snapshot, large_result);
        if (!saw_large_paste) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(saw_large_paste);

    try client.writeInput(
        created.id,
        "stty -echo -icanon min 1 time 0; printf '\\033[16t'; " ++
            "pixels=$(dd bs=1 count=10 2>/dev/null | od -An -tx1 | tr -d ' \\n'); " ++
            "stty sane; printf 'PIXELS:%s\\n' \"$pixels\"\n",
    );
    var saw_pixel_reply = false;
    attempts = 0;
    while (!saw_pixel_reply and attempts < 100) : (attempts += 1) {
        var pixel_snapshot = try client.snapshot(created.id);
        defer pixel_snapshot.deinit(alloc);
        saw_pixel_reply = snapshotContains(&pixel_snapshot, "PIXELS:1b5b363b32303b313074");
        if (!saw_pixel_reply) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(saw_pixel_reply);

    try client.writeInput(
        created.id,
        "printf '\\033[6n'; IFS= read -r -d R reply; printf 'CPR_OK\\n'\n",
    );
    var saw_cpr_reply = false;
    attempts = 0;
    while (!saw_cpr_reply and attempts < 100) : (attempts += 1) {
        var snapshot = try client.snapshot(created.id);
        defer snapshot.deinit(alloc);
        saw_cpr_reply = snapshotContains(&snapshot, "CPR_OK");
        if (!saw_cpr_reply) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(saw_cpr_reply);

    // RFC 0018 metadata remains daemon-owned and crosses the real v13
    // snapshot boundary as a dense, visible-cell table.
    try client.writeInput(
        created.id,
        "printf '\\033]8;id=daemon-link;https://example.com/daemon\\033\\\\DAEMON_LINK" ++
            "\\033]8;;\\033\\\\\\n'\n",
    );
    var saw_hyperlink = false;
    attempts = 0;
    while (!saw_hyperlink and attempts < 100) : (attempts += 1) {
        var link_snapshot = try client.snapshot(created.id);
        defer link_snapshot.deinit(alloc);
        for (link_snapshot.cells) |cell| {
            const link = link_snapshot.viewCellHyperlink(cell) orelse continue;
            if (std.mem.eql(u8, link.explicit_id, "daemon-link") and
                std.mem.eql(u8, link.uri, "https://example.com/daemon"))
            {
                saw_hyperlink = true;
                break;
            }
        }
        if (!saw_hyperlink) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(saw_hyperlink);

    // RFC 0002 / attach dialect 18 keeps OSC 22 as daemon-owned terminal
    // state, including when the sequence paints no cells.
    try client.writeInput(created.id, "printf '\\033]22;pointer\\033\\\\'\n");
    var saw_pointer_shape = false;
    attempts = 0;
    while (!saw_pointer_shape and attempts < 100) : (attempts += 1) {
        var pointer_snapshot = try client.snapshot(created.id);
        defer pointer_snapshot.deinit(alloc);
        saw_pointer_shape = pointer_snapshot.modes.pointer_shape == .pointer;
        if (!saw_pointer_shape) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(saw_pointer_shape);

    // Protocol v11 search stays semantic: the daemon searches retained text,
    // reveals a pinned result, and returns only visible highlight masks.
    var search_result = try client.search(created.id, .initial, "cpr_ok", null);
    defer search_result.deinit(alloc);
    try std.testing.expect(search_result.total >= 1);
    try std.testing.expect(search_result.selected != null);
    try std.testing.expect(search_result.selected_index != null);
    try std.testing.expect(std.mem.indexOfScalar(bool, search_result.matches, true) != null);
    try std.testing.expect(std.mem.indexOfScalar(bool, search_result.selected_cells, true) != null);

    // terminal-browser v0.5.4's exact capability probe must receive the
    // direct-transport OK response through the PTY input channel.
    try client.writeInput(
        created.id,
        "stty -echo -icanon min 1 time 0; " ++
            "printf '\\033_Gi=4207,a=q,t=d,f=24,s=1,v=1;AAAA\\033\\\\'; " ++
            "graphics=$(dd bs=1 count=14 2>/dev/null | od -An -tx1 | tr -d ' \\n'); " ++
            "stty sane; printf 'GRAPHICS:%s\\n' \"$graphics\"\n",
    );
    var saw_graphics_reply = false;
    attempts = 0;
    while (!saw_graphics_reply and attempts < 100) : (attempts += 1) {
        var graphics_snapshot = try client.snapshot(created.id);
        defer graphics_snapshot.deinit(alloc);
        saw_graphics_reply = snapshotContains(
            &graphics_snapshot,
            "GRAPHICS:1b5f47693d343230373b4f4b1b5c",
        );
        if (!saw_graphics_reply) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(saw_graphics_reply);

    // Its direct renderer uses zlib-compressed RGBA split across APC chunks.
    // The daemon owns decoded pixels. Protocol v8 retains v6's descriptor-only
    // immutable descriptor; the viewer fetches that generation separately.
    try client.writeInput(
        created.id,
        "printf '\\033_Ga=T,f=32,o=z,s=1,v=1,t=d,i=7,p=1,C=1,q=2,m=1;eJ\\033\\\\'; " ++
            "printf '\\033_Gm=0;xjYGBgAAAABAAB\\033\\\\'\n",
    );
    var saw_graphics_frame = false;
    var direct_generation: u64 = 0;
    attempts = 0;
    while (!saw_graphics_frame and attempts < 100) : (attempts += 1) {
        var graphics_snapshot = try client.snapshot(created.id);
        defer graphics_snapshot.deinit(alloc);
        if (graphics_snapshot.images.len == 1 and graphics_snapshot.placements.len == 1) {
            const image = graphics_snapshot.images[0];
            const placement = graphics_snapshot.placements[0];
            if (image.id == 7 and image.width == 1 and image.height == 1 and
                placement.image_id == image.id and placement.generation == image.generation)
            {
                var resource = try client.image(created.id, image.id, image.generation);
                defer resource.deinit(alloc);
                saw_graphics_frame = resource.width == image.width and
                    resource.height == image.height and
                    std.mem.eql(u8, resource.rgba, &.{ 0, 0, 0, 0 });
                if (saw_graphics_frame) direct_generation = image.generation;
            }
        }
        if (!saw_graphics_frame) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(saw_graphics_frame);

    // RFC 0015 negotiates on a disposable v10 bulk connection. The first
    // lease carries one daemon-owned shared-memory descriptor; after release,
    // the same mapped slot is reused with metadata only.
    var graphics_stream = try address.connect(io);
    defer graphics_stream.close(io);
    const graphics_fd = graphics_stream.socket.handle;
    try protocol.writeFrame(graphics_fd, .graphics_attach, &.{});
    var graphics_ready = try protocol.readFrame(graphics_fd, alloc);
    defer graphics_ready.deinit(alloc);
    try std.testing.expectEqual(protocol.Tag.graphics_ready, graphics_ready.tag);
    try std.testing.expectEqual(@as(usize, 0), graphics_ready.payload.len);
    var staged_mapping: ?*anyopaque = null;
    var staged_capacity: usize = 0;
    defer {
        if (staged_mapping) |mapping|
            _ = c.munmap(@ptrCast(@alignCast(mapping)), staged_capacity);
    }

    // A live-video snapshot can lose a race with the next replacement before
    // its fetch arrives. The empty envelope keeps the staged lane framed, and
    // the following valid request proves the connection was not sacrificed.
    {
        var stale_request = protocol.Encoder.init(alloc);
        defer stale_request.deinit();
        try stale_request.int(u64, created.id);
        try stale_request.int(u32, 7);
        try stale_request.int(u64, std.math.maxInt(u64));
        try stale_request.int(u32, 256);
        try protocol.writeFrame(graphics_fd, .stage_image, stale_request.slice());
        try std.testing.expect(try protocol.readDescriptorEnvelope(graphics_fd) == null);
        var stale_response = try protocol.readFrame(graphics_fd, alloc);
        defer stale_response.deinit(alloc);
        try std.testing.expectEqual(protocol.Tag.protocol_error, stale_response.tag);
    }

    var staged_iteration: usize = 0;
    while (staged_iteration < 2) : (staged_iteration += 1) {
        var stage_request = protocol.Encoder.init(alloc);
        defer stage_request.deinit();
        try stage_request.int(u64, created.id);
        try stage_request.int(u32, 7);
        try stage_request.int(u64, direct_generation);
        try stage_request.int(u32, 256);
        try protocol.writeFrame(graphics_fd, .stage_image, stage_request.slice());
        const staged_fd = try protocol.readDescriptorEnvelope(graphics_fd);
        defer {
            if (staged_fd) |received| _ = c.close(received);
        }
        var staged_frame = try protocol.readFrame(graphics_fd, alloc);
        defer staged_frame.deinit(alloc);
        try std.testing.expectEqual(protocol.Tag.staged_image, staged_frame.tag);
        var staged_dec: protocol.Decoder = .{ .bytes = staged_frame.payload };
        const staged = try protocol.decodeStagedImage(&staged_dec);
        try staged_dec.finish();
        try std.testing.expectEqual(@as(u32, 256), staged.bytes_per_row);
        try std.testing.expectEqual(@as(u64, 256), staged.byte_length);
        if (staged_iteration == 0) {
            try std.testing.expect(staged_fd != null);
            var stat: c.Stat = undefined;
            try std.testing.expectEqual(@as(c_int, 0), c.fstat(staged_fd.?, &stat));
            staged_capacity = @intCast(stat.size);
            staged_mapping = c.mmap(
                null,
                staged_capacity,
                c.PROT{ .READ = true },
                c.MAP{ .TYPE = .SHARED },
                staged_fd.?,
                0,
            );
            try std.testing.expect(staged_mapping != c.MAP_FAILED);
        } else {
            try std.testing.expect(staged_fd == null);
        }
        const staged_bytes: [*]const u8 = @ptrCast(staged_mapping.?);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, staged_bytes[0..4]);
        var release = protocol.Encoder.init(alloc);
        defer release.deinit();
        try release.byte(staged.slot_index);
        try release.int(u64, staged.lease_token);
        try protocol.writeFrame(graphics_fd, .release_staged_image, release.slice());
        var released = try protocol.readFrame(graphics_fd, alloc);
        defer released.deinit(alloc);
        try std.testing.expectEqual(protocol.Tag.ok, released.tag);
    }

    // RFC 0023's transport backpressure is the three exact staging leases,
    // not an unbounded queue. Hold all three, observe busy, retire one exact
    // capability as a delayed GPU completion would, and prove that slot alone
    // becomes reusable.
    var held: [3]protocol.StagedImage = undefined;
    for (&held) |*held_image| {
        var request = protocol.Encoder.init(alloc);
        defer request.deinit();
        try request.int(u64, created.id);
        try request.int(u32, 7);
        try request.int(u64, direct_generation);
        try request.int(u32, 256);
        try protocol.writeFrame(graphics_fd, .stage_image, request.slice());
        const descriptor = try protocol.readDescriptorEnvelope(graphics_fd);
        if (descriptor) |received| _ = c.close(received);
        var frame = try protocol.readFrame(graphics_fd, alloc);
        defer frame.deinit(alloc);
        try std.testing.expectEqual(protocol.Tag.staged_image, frame.tag);
        var decoder: protocol.Decoder = .{ .bytes = frame.payload };
        held_image.* = try protocol.decodeStagedImage(&decoder);
        try decoder.finish();
    }
    {
        var request = protocol.Encoder.init(alloc);
        defer request.deinit();
        try request.int(u64, created.id);
        try request.int(u32, 7);
        try request.int(u64, direct_generation);
        try request.int(u32, 256);
        try protocol.writeFrame(graphics_fd, .stage_image, request.slice());
        try std.testing.expect(try protocol.readDescriptorEnvelope(graphics_fd) == null);
        var busy = try protocol.readFrame(graphics_fd, alloc);
        defer busy.deinit(alloc);
        try std.testing.expectEqual(protocol.Tag.graphics_busy, busy.tag);
        try std.testing.expectEqual(@as(usize, 0), busy.payload.len);
    }
    const retired = held[1];
    {
        var release = protocol.Encoder.init(alloc);
        defer release.deinit();
        try release.byte(retired.slot_index);
        try release.int(u64, retired.lease_token);
        try protocol.writeFrame(graphics_fd, .release_staged_image, release.slice());
        var released = try protocol.readFrame(graphics_fd, alloc);
        defer released.deinit(alloc);
        try std.testing.expectEqual(protocol.Tag.ok, released.tag);
    }
    var replacement_staged: protocol.StagedImage = undefined;
    {
        var request = protocol.Encoder.init(alloc);
        defer request.deinit();
        try request.int(u64, created.id);
        try request.int(u32, 7);
        try request.int(u64, direct_generation);
        try request.int(u32, 256);
        try protocol.writeFrame(graphics_fd, .stage_image, request.slice());
        const descriptor = try protocol.readDescriptorEnvelope(graphics_fd);
        if (descriptor) |received| _ = c.close(received);
        var frame = try protocol.readFrame(graphics_fd, alloc);
        defer frame.deinit(alloc);
        try std.testing.expectEqual(protocol.Tag.staged_image, frame.tag);
        var decoder: protocol.Decoder = .{ .bytes = frame.payload };
        replacement_staged = try protocol.decodeStagedImage(&decoder);
        try decoder.finish();
        try std.testing.expectEqual(retired.slot_index, replacement_staged.slot_index);
        try std.testing.expect(replacement_staged.lease_token != retired.lease_token);
    }
    for ([_]protocol.StagedImage{ held[0], held[2], replacement_staged }) |leased| {
        var release = protocol.Encoder.init(alloc);
        defer release.deinit();
        try release.byte(leased.slot_index);
        try release.int(u64, leased.lease_token);
        try protocol.writeFrame(graphics_fd, .release_staged_image, release.slice());
        var released = try protocol.readFrame(graphics_fd, alloc);
        defer released.deinit(alloc);
        try std.testing.expectEqual(protocol.Tag.ok, released.tag);
    }

    // Required PNG format is host-decoded after the pure VT assembles direct
    // chunks. PNG dimensions override deliberately incorrect s/v controls.
    try client.writeInput(
        created.id,
        "printf '\\033_Ga=T,f=100,s=99,v=88,t=d,i=10,p=1,C=1,q=2,m=1;" ++
            "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFUlEQVR4\\033\\\\'; " ++
            "printf '\\033_Gm=0;nGP4z8Dwn+EEQwMDkAYDAEI+CUGYxtFzAAAAAElFTkSuQmCC\\033\\\\'\n",
    );
    var saw_png_frame = false;
    attempts = 0;
    while (!saw_png_frame and attempts < 100) : (attempts += 1) {
        var graphics_snapshot = try client.snapshot(created.id);
        defer graphics_snapshot.deinit(alloc);
        for (graphics_snapshot.images) |image| {
            if (image.id != 10 or image.width != 2 or image.height != 2) continue;
            var resource = try client.image(created.id, image.id, image.generation);
            defer resource.deinit(alloc);
            saw_png_frame = std.mem.eql(u8, resource.rgba[0..4], &.{ 255, 0, 0, 255 });
            if (saw_png_frame) break;
        }
        if (!saw_png_frame) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(saw_png_frame);

    // Retained transmit + image-number put must commit cursor movement before
    // the following printable byte from the same PTY read is parsed.
    try client.writeInput(
        created.id,
        "printf '\\033_Ga=t,f=32,s=1,v=1,t=d,I=55,q=2;/wAA/w==\\033\\\\" ++ "\\033[10;10H\\033_Ga=p,I=55,p=9,c=2,r=2,q=2\\033\\\\X'\n",
    );
    var saw_numbered_placement = false;
    attempts = 0;
    while (!saw_numbered_placement and attempts < 100) : (attempts += 1) {
        var graphics_snapshot = try client.snapshot(created.id);
        defer graphics_snapshot.deinit(alloc);
        for (graphics_snapshot.placements) |placement| {
            if (placement.placement_id != 9) continue;
            saw_numbered_placement =
                placement.row == 9 and placement.col == 9 and
                placement.dest_width == 20 and placement.dest_height == 40 and
                graphics_snapshot.viewCellAt(11, 11).cp == 'X';
            if (saw_numbered_placement) break;
        }
        if (!saw_numbered_placement) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(saw_numbered_placement);

    // Protocol v8 derives a renderer placement from ordinary U+10EEEE cells
    // and their colors/diacritics while retaining the invisible prototype.
    try client.writeInput(
        created.id,
        "printf '\\033_Ga=p,U=1,i=10,p=77,c=2,r=2,q=2\\033\\\\'; " ++
            "printf '\\033[15;5H\\033[38;5;10;58;5;77m\u{10EEEE}\u{0305}\u{0305}" ++
            "\u{10EEEE}\u{0305}\u{030D}\\033[0m'\n",
    );
    var saw_virtual_placement = false;
    attempts = 0;
    while (!saw_virtual_placement and attempts < 100) : (attempts += 1) {
        var graphics_snapshot = try client.snapshot(created.id);
        defer graphics_snapshot.deinit(alloc);
        for (graphics_snapshot.placements) |placement| {
            if (placement.placement_id != 77) continue;
            const placeholder = graphics_snapshot.viewCellAt(14, 4);
            saw_virtual_placement = placement.image_id == 10 and
                placement.row == 14 and placement.col == 4 and placement.z == -1 and
                placeholder.cp == vt.graphics.unicode_placeholder and
                std.meta.eql(placeholder.underline_color, vt.Color{ .indexed = 77 });
            if (saw_virtual_placement) break;
        }
        if (!saw_virtual_placement) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(saw_virtual_placement);

    // A one-pixel resource spanning two placeholder rows must produce two
    // non-empty source rectangles rather than dropping the lower half.
    try client.writeInput(
        created.id,
        "printf '\\033_Ga=p,U=1,i=7,p=78,c=2,r=2,q=2\\033\\\\'; " ++
            "printf '\\033[17;5H\\033[38;5;7;58;5;78m\u{10EEEE}\u{0305}\u{0305}" ++
            "\u{10EEEE}\u{0305}\u{030D}\\033[18;5H" ++
            "\u{10EEEE}\u{030D}\u{0305}\u{10EEEE}\u{030D}\u{030D}\\033[0m'\n",
    );
    var saw_tiny_virtual_rows = false;
    attempts = 0;
    while (!saw_tiny_virtual_rows and attempts < 100) : (attempts += 1) {
        var graphics_snapshot = try client.snapshot(created.id);
        defer graphics_snapshot.deinit(alloc);
        var tiny_rows: u32 = 0;
        for (graphics_snapshot.placements) |placement| {
            if (placement.placement_id != 78) continue;
            if (placement.image_id == 7 and placement.source_x == 0 and
                placement.source_y == 0 and placement.source_width == 1 and
                placement.source_height == 1 and placement.dest_width == 20 and
                placement.dest_height == 10 and
                (placement.row == 16 or placement.row == 17))
            {
                tiny_rows += 1;
            }
        }
        saw_tiny_virtual_rows = tiny_rows == 2;
        if (!saw_tiny_virtual_rows) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(saw_tiny_virtual_rows);

    // The viewer-side refresh path negotiates the same lane, materializes
    // every missing visible generation from its mapped slot, and releases
    // each lease before requesting the next one.
    try client.startGraphicsReleaseWorker();
    client.enableSharedGraphics(256);
    try std.testing.expect(client.sharedGraphicsEnabled());
    const staged_viewer = try daemon_client.Session.create(alloc, io, &client, created);
    defer staged_viewer.destroy();
    var staged_prepare_count: usize = 0;
    staged_viewer.visible.store(true, .release);
    staged_viewer.image_context = &staged_prepare_count;
    staged_viewer.prepare_staged_image_fn = acceptStagedImage;
    try staged_viewer.refresh();
    try std.testing.expect(staged_prepare_count > 0);
    for (staged_viewer.graphics_images.items) |image|
        try std.testing.expect(image.staged);

    // The real viewer cache fetches a generation on first refresh and keeps
    // the same owned bytes across an unchanged snapshot.
    const cached_viewer = try daemon_client.Session.create(alloc, io, &client, created);
    defer cached_viewer.destroy();
    try cached_viewer.refresh();
    var cached_direct_ptr: ?[*]u8 = null;
    for (cached_viewer.graphics_images.items) |image| {
        if (image.id == 7 and image.generation == direct_generation) cached_direct_ptr = image.rgba.ptr;
    }
    try std.testing.expect(cached_direct_ptr != null);
    try cached_viewer.refresh();
    var reused_direct = false;
    for (cached_viewer.graphics_images.items) |image| {
        if (image.id == 7 and image.generation == direct_generation) {
            reused_direct = image.rgba.ptr == cached_direct_ptr.?;
        }
    }
    try std.testing.expect(reused_direct);

    // Animation remains daemon-owned when no viewer drives frames. A single
    // placed resource publishes alternating render generations through the
    // ordinary snapshot/image path as its kqueue timer advances.
    try client.writeInput(
        created.id,
        "printf '\\033_Ga=T,f=32,s=1,v=1,t=d,i=70,p=1,C=1,q=2;/wAA/w==\\033\\\\'; " ++
            "printf '\\033_Ga=f,f=32,s=1,v=1,t=d,i=70,z=30,q=2;AP8A/w==\\033\\\\'; " ++
            "printf '\\033_Ga=a,i=70,r=1,z=30,s=3,v=10,q=2\\033\\\\'\n",
    );
    var saw_red_animation_frame = false;
    var saw_green_animation_frame = false;
    var red_animation_generation: u64 = 0;
    var green_animation_generation: u64 = 0;
    attempts = 0;
    while (!(saw_red_animation_frame and saw_green_animation_frame) and attempts < 100) : (attempts += 1) {
        var animation_snapshot = try client.snapshot(created.id);
        defer animation_snapshot.deinit(alloc);
        for (animation_snapshot.images) |image| {
            if (image.id != 70) continue;
            var resource = try client.image(created.id, image.id, image.generation);
            defer resource.deinit(alloc);
            if (std.mem.eql(u8, resource.rgba, &.{ 255, 0, 0, 255 })) {
                saw_red_animation_frame = true;
                red_animation_generation = image.generation;
            } else if (std.mem.eql(u8, resource.rgba, &.{ 0, 255, 0, 255 })) {
                saw_green_animation_frame = true;
                green_animation_generation = image.generation;
            }
        }
        if (!(saw_red_animation_frame and saw_green_animation_frame))
            try io.sleep(.fromMilliseconds(10), .awake);
    }
    try std.testing.expect(saw_red_animation_frame and saw_green_animation_frame);
    try std.testing.expect(red_animation_generation != green_animation_generation);
    try client.writeInput(created.id, "printf '\\033_Ga=a,i=70,s=1,q=2\\033\\\\'\n");

    // Relative placements resolve from the exact retained parent and carry
    // their accumulated signed cell offset into the daemon snapshot.
    try client.writeInput(
        created.id,
        "printf '\\033_Ga=T,f=32,s=1,v=1,t=d,i=71,p=11,C=1,q=2;/wAA/w==\\033\\\\'; " ++
            "printf '\\033_Ga=T,f=32,s=1,v=1,t=d,i=72,p=12,P=71,Q=11,H=2,V=-1,C=1,q=2;AP8A/w==\\033\\\\'\n",
    );
    var saw_relative_placement = false;
    attempts = 0;
    while (!saw_relative_placement and attempts < 100) : (attempts += 1) {
        var relative_snapshot = try client.snapshot(created.id);
        defer relative_snapshot.deinit(alloc);
        var parent: ?protocol.Placement = null;
        var child: ?protocol.Placement = null;
        for (relative_snapshot.placements) |placement| {
            if (placement.image_id == 71 and placement.placement_id == 11) parent = placement;
            if (placement.image_id == 72 and placement.placement_id == 12) child = placement;
        }
        if (parent != null and child != null) {
            saw_relative_placement = child.?.row == parent.?.row - 1 and
                child.?.col == parent.?.col + 2;
        }
        if (!saw_relative_placement) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(saw_relative_placement);

    // terminal-browser's preferred fast path transmits the POSIX shared-memory
    // name through the APC and leaves the terminal responsible for opening and
    // unlinking it. Exercise that ownership transfer through the real daemon,
    // then ensure its decoded resource crosses the snapshot boundary.
    var shm_name_buf: [96]u8 = undefined;
    const shm_name = try std.fmt.bufPrintZ(
        &shm_name_buf,
        "/bt-it-{x}",
        .{std.mem.readInt(u64, &random_bytes, .little)},
    );
    _ = c.shm_unlink(shm_name.ptr);
    const shm_fd = c.shm_open(shm_name.ptr, @bitCast(c.O{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .EXCL = true,
    }), @as(c.mode_t, 0o600));
    if (shm_fd < 0) return error.SharedMemoryCreateFailed;
    defer _ = c.close(shm_fd);
    defer _ = c.shm_unlink(shm_name.ptr);
    if (c.ftruncate(shm_fd, 4) < 0) return error.SharedMemoryCreateFailed;
    const shm_mapping = c.mmap(
        null,
        4,
        c.PROT{ .READ = true, .WRITE = true },
        c.MAP{ .TYPE = .SHARED },
        shm_fd,
        0,
    );
    if (shm_mapping == c.MAP_FAILED) return error.SharedMemoryCreateFailed;
    const shared_pixel = [_]u8{ 11, 22, 33, 255 };
    const shared_bytes: [*]u8 = @ptrCast(shm_mapping);
    @memcpy(shared_bytes[0..shared_pixel.len], &shared_pixel);
    _ = c.munmap(@ptrCast(@alignCast(shm_mapping)), 4);

    var encoded_name_buf: [160]u8 = undefined;
    const encoded_name_len = std.base64.standard.Encoder.calcSize(shm_name.len);
    const encoded_name = std.base64.standard.Encoder.encode(
        encoded_name_buf[0..encoded_name_len],
        shm_name,
    );
    const shared_command = try std.fmt.allocPrint(
        alloc,
        "printf '\\033_Ga=T,f=32,s=1,v=1,t=s,i=8,p=1,C=1,q=2;{s}\\033\\\\'\n",
        .{encoded_name},
    );
    defer alloc.free(shared_command);
    try client.writeInput(created.id, shared_command);
    var saw_shared_frame = false;
    attempts = 0;
    while (!saw_shared_frame and attempts < 100) : (attempts += 1) {
        var graphics_snapshot = try client.snapshot(created.id);
        defer graphics_snapshot.deinit(alloc);
        for (graphics_snapshot.images) |image| {
            if (image.id != 8 or image.width != 1 or image.height != 1) continue;
            var resource = try client.image(created.id, image.id, image.generation);
            defer resource.deinit(alloc);
            saw_shared_frame = std.mem.eql(u8, resource.rgba, &shared_pixel);
            if (saw_shared_frame) break;
        }
        if (!saw_shared_frame) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(saw_shared_frame);
    const reopened_shm = c.shm_open(
        shm_name.ptr,
        @bitCast(c.O{ .ACCMODE = .RDONLY }),
    );
    if (reopened_shm >= 0) {
        _ = c.close(reopened_shm);
        return error.SharedMemoryWasNotUnlinked;
    }

    // Temporary-file transport validates the descriptor's canonical path
    // against TMPDIR and the protocol marker, reads the pixels, and transfers
    // cleanup ownership to the daemon.
    const temporary_name = "tty-graphics-protocol-integration.rgba";
    var home_dir = try std.Io.Dir.openDirAbsolute(io, home, .{});
    defer home_dir.close(io);
    const file_pixel = [_]u8{ 44, 55, 66, 255 };
    try home_dir.writeFile(io, .{ .sub_path = temporary_name, .data = &file_pixel });
    const temporary_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ home, temporary_name });
    defer alloc.free(temporary_path);
    var encoded_path_buf: [256]u8 = undefined;
    const encoded_path_len = std.base64.standard.Encoder.calcSize(temporary_path.len);
    const encoded_path = std.base64.standard.Encoder.encode(
        encoded_path_buf[0..encoded_path_len],
        temporary_path,
    );
    const file_command = try std.fmt.allocPrint(
        alloc,
        "printf '\\033_Ga=T,f=32,s=1,v=1,t=t,i=9,p=1,C=1,q=2;{s}\\033\\\\'\n",
        .{encoded_path},
    );
    defer alloc.free(file_command);
    try client.writeInput(created.id, file_command);
    var saw_file_frame = false;
    attempts = 0;
    while (!saw_file_frame and attempts < 100) : (attempts += 1) {
        var graphics_snapshot = try client.snapshot(created.id);
        defer graphics_snapshot.deinit(alloc);
        for (graphics_snapshot.images) |image| {
            if (image.id != 9 or image.width != 1 or image.height != 1) continue;
            var resource = try client.image(created.id, image.id, image.generation);
            defer resource.deinit(alloc);
            saw_file_frame = std.mem.eql(u8, resource.rgba, &file_pixel);
            if (saw_file_frame) break;
        }
        if (!saw_file_frame) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(saw_file_frame);
    try std.testing.expectError(
        error.FileNotFound,
        home_dir.access(io, temporary_name, .{}),
    );

    // Replacing an image id invalidates only its old generation. A stale
    // fetch fails explicitly without poisoning the command connection, while
    // the new descriptor/resource pair remains available.
    try client.writeInput(
        created.id,
        "printf '\\033_Ga=T,f=32,s=1,v=1,t=d,i=7,p=1,C=1,q=2;AQIDBA==\\033\\\\'\n",
    );
    var replacement_ref: ?protocol.ImageRef = null;
    attempts = 0;
    while (replacement_ref == null and attempts < 100) : (attempts += 1) {
        var graphics_snapshot = try client.snapshot(created.id);
        defer graphics_snapshot.deinit(alloc);
        for (graphics_snapshot.images) |image| {
            if (image.id == 7 and image.generation != direct_generation) {
                replacement_ref = image;
                break;
            }
        }
        if (replacement_ref == null) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(replacement_ref != null);
    try std.testing.expectError(
        error.RemoteError,
        client.image(created.id, 7, direct_generation),
    );
    try std.testing.expect(!client.isDisconnected());
    var replacement = try client.image(created.id, 7, replacement_ref.?.generation);
    defer replacement.deinit(alloc);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, replacement.rgba);
    try cached_viewer.refresh();
    var cached_replacement = false;
    for (cached_viewer.graphics_images.items) |image| {
        try std.testing.expect(image.generation != direct_generation or image.id != 7);
        if (image.id == 7 and image.generation == replacement_ref.?.generation) {
            cached_replacement = std.mem.eql(u8, image.rgba, &.{ 1, 2, 3, 4 });
        }
    }
    try std.testing.expect(cached_replacement);

    // Mode 1004 is daemon-owned: AppKit reports only logical focus, then the
    // daemon consults the VT mode and injects xterm's exact focus bytes. Wait
    // until the child has enabled the mode and entered its six-byte read so
    // this is an ordering test rather than a timing guess. Readiness markers
    // in this section are octal-encoded so the shell's echoed command line
    // cannot satisfy the snapshot poll before stty and the terminal mode take
    // effect.
    const focus_command =
        "stty -echo -icanon min 1 time 0; printf '\\033[?1004h\\106\\117\\103\\125\\123\\137\\122\\105\\101\\104\\131\\n'; " ++
        "focus=$(dd bs=1 count=6 2>/dev/null | od -An -tx1 | tr -d ' \\n'); " ++
        "stty sane; printf 'FOCUS:%s\\n' \"$focus\"\n";
    try expectReadinessMarkerHidden(focus_command, "FOCUS_READY");
    try client.writeInput(created.id, focus_command);
    var focus_ready = false;
    attempts = 0;
    while (!focus_ready and attempts < 100) : (attempts += 1) {
        var focus_snapshot = try client.snapshot(created.id);
        defer focus_snapshot.deinit(alloc);
        focus_ready = focus_snapshot.modes.focus_reporting and
            snapshotContains(&focus_snapshot, "FOCUS_READY");
        if (!focus_ready) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(focus_ready);
    try client.setFocus(created.id, true);
    try client.setFocus(created.id, true); // duplicate state emits nothing
    try client.setFocus(created.id, false);
    try client.setFocus(created.id, false); // duplicate state emits nothing
    var saw_focus_reports = false;
    attempts = 0;
    while (!saw_focus_reports and attempts < 100) : (attempts += 1) {
        var focus_snapshot = try client.snapshot(created.id);
        defer focus_snapshot.deinit(alloc);
        saw_focus_reports = snapshotContains(&focus_snapshot, "FOCUS:1b5b491b5b4f");
        if (!saw_focus_reports) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(saw_focus_reports);

    const expected_mouse = "\x1b[<28;5;3M" ++
        "\x1b[<10;5;3m" ++
        "\x1b[<65;2;4M";
    const mouse_command = try std.fmt.allocPrint(
        alloc,
        "stty -echo -icanon min 1 time 0; " ++
            "printf '\\033[?1000h\\033[?1006h\\115\\117\\125\\123\\105\\137\\122\\105\\101\\104\\131\\n'; " ++
            "mouse=$(dd bs=1 count={d} 2>/dev/null | od -An -tx1 | tr -d ' \\n'); " ++
            "stty sane; printf 'MOUSE:%s\\n' \"$mouse\"\n",
        .{expected_mouse.len},
    );
    defer alloc.free(mouse_command);
    try expectReadinessMarkerHidden(mouse_command, "MOUSE_READY");
    try client.writeInput(created.id, mouse_command);
    var mouse_ready = false;
    attempts = 0;
    while (!mouse_ready and attempts < 100) : (attempts += 1) {
        var mouse_snapshot = try client.snapshot(created.id);
        defer mouse_snapshot.deinit(alloc);
        mouse_ready = mouse_snapshot.modes.mouse_reporting and
            snapshotContains(&mouse_snapshot, "MOUSE_READY");
        if (!mouse_ready) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(mouse_ready);
    try std.testing.expect(try client.mouseEvent(created.id, .{
        .kind = .press,
        .button = .left,
        .modifiers = .{ .shift = true, .alt = true, .control = true },
        .col = 4,
        .row = 2,
    }));
    // Normal tracking owns but suppresses motion; it must contribute no bytes.
    try std.testing.expect(try client.mouseEvent(created.id, .{
        .kind = .motion,
        .button = .left,
        .col = 5,
        .row = 2,
    }));
    try std.testing.expect(try client.mouseEvent(created.id, .{
        .kind = .release,
        .button = .right,
        .modifiers = .{ .alt = true },
        .col = 4,
        .row = 2,
    }));
    try std.testing.expect(try client.mouseEvent(created.id, .{
        .kind = .wheel_down,
        .col = 1,
        .row = 3,
    }));
    var saw_mouse_reports = false;
    attempts = 0;
    while (!saw_mouse_reports and attempts < 100) : (attempts += 1) {
        var mouse_snapshot = try client.snapshot(created.id);
        defer mouse_snapshot.deinit(alloc);
        saw_mouse_reports = snapshotContains(
            &mouse_snapshot,
            "MOUSE:1b5b3c32383b353b334d1b5b3c31303b353b336d1b5b3c36353b323b344d",
        );
        if (!saw_mouse_reports) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(saw_mouse_reports);

    const expected_pixel_mouse = "\x1b[<0;43;18M";
    const pixel_mouse_command = try std.fmt.allocPrint(
        alloc,
        "stty -echo -icanon min 1 time 0; " ++
            "printf '\\033[?1000h\\033[?1016h\\120\\111\\130\\105\\114\\137\\122\\105\\101\\104\\131\\n'; " ++
            "mouse=$(dd bs=1 count={d} 2>/dev/null | od -An -tx1 | tr -d ' \\n'); " ++
            "stty sane; printf 'PIXEL_MOUSE:%s\\n' \"$mouse\"\n",
        .{expected_pixel_mouse.len},
    );
    defer alloc.free(pixel_mouse_command);
    try expectReadinessMarkerHidden(pixel_mouse_command, "PIXEL_READY");
    try client.writeInput(created.id, pixel_mouse_command);
    var pixel_mouse_ready = false;
    attempts = 0;
    while (!pixel_mouse_ready and attempts < 100) : (attempts += 1) {
        var pixel_mouse_snapshot = try client.snapshot(created.id);
        defer pixel_mouse_snapshot.deinit(alloc);
        pixel_mouse_ready = snapshotContains(&pixel_mouse_snapshot, "PIXEL_READY");
        if (!pixel_mouse_ready) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(pixel_mouse_ready);
    try std.testing.expect(try client.mouseEvent(created.id, .{
        .kind = .press,
        .button = .left,
        .col = 9,
        .row = 4,
        .pixel_x = 42,
        .pixel_y = 17,
    }));
    var saw_pixel_mouse_report = false;
    attempts = 0;
    while (!saw_pixel_mouse_report and attempts < 100) : (attempts += 1) {
        var pixel_mouse_snapshot = try client.snapshot(created.id);
        defer pixel_mouse_snapshot.deinit(alloc);
        saw_pixel_mouse_report = snapshotContains(
            &pixel_mouse_snapshot,
            "PIXEL_MOUSE:1b5b3c303b34333b31384d",
        );
        if (!saw_pixel_mouse_report) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(saw_pixel_mouse_report);

    const expected_keys = "\x1b[13;2u" ++ "\x1b[1;1:2A" ++ "\x1b[99;5:3u";
    const key_command = try std.fmt.allocPrint(
        alloc,
        "stty -echo -icanon min 1 time 0; " ++
            "printf '\\033[>3u\\113\\105\\131\\137\\122\\105\\101\\104\\131\\n'; " ++
            "keys=$(dd bs=1 count={d} 2>/dev/null | od -An -tx1 | tr -d ' \\n'); " ++
            "stty sane; printf 'KEY:%s\\n' \"$keys\"\n",
        .{expected_keys.len},
    );
    defer alloc.free(key_command);
    try expectReadinessMarkerHidden(key_command, "KEY_READY");
    try client.writeInput(created.id, key_command);
    var key_ready = false;
    attempts = 0;
    while (!key_ready and attempts < 100) : (attempts += 1) {
        var key_snapshot = try client.snapshot(created.id);
        defer key_snapshot.deinit(alloc);
        key_ready = snapshotContains(&key_snapshot, "KEY_READY");
        if (!key_ready) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(key_ready);
    try client.keyEvent(created.id, .{ .code = .enter, .modifiers = .{ .shift = true } });
    try client.keyEvent(created.id, .{ .code = .up, .action = .repeat });
    try client.keyEvent(created.id, .{
        .code = .codepoint,
        .codepoint = 'c',
        .modifiers = .{ .control = true },
        .action = .release,
    });
    // Recovery keys do not report releases until report-all (phase 2).
    try client.keyEvent(created.id, .{ .code = .enter, .action = .release });
    var saw_key_reports = false;
    attempts = 0;
    while (!saw_key_reports and attempts < 100) : (attempts += 1) {
        var key_snapshot = try client.snapshot(created.id);
        defer key_snapshot.deinit(alloc);
        saw_key_reports = snapshotContains(
            &key_snapshot,
            "KEY:1b5b31333b32751b5b313b313a32411b5b39393b353a3375",
        );
        if (!saw_key_reports) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(saw_key_reports);

    const expected_phase_two = "\x1b[61:43;2;43u" ++
        "\x1b[57441;2u" ++
        "\x1b[0;;229u" ++
        "\x1b[13;1:3u";
    const phase_two_command = try std.fmt.allocPrint(
        alloc,
        "stty -echo -icanon min 1 time 0; " ++
            "printf '\\033[>31u\\113\\105\\131\\062\\137\\122\\105\\101\\104\\131\\n'; " ++
            "keys=$(dd bs=1 count={d} 2>/dev/null | od -An -tx1 | tr -d ' \\n'); " ++
            "stty sane; printf 'KEY2:%s\\n' \"$keys\"\n",
        .{expected_phase_two.len},
    );
    defer alloc.free(phase_two_command);
    try expectReadinessMarkerHidden(phase_two_command, "KEY2_READY");
    try client.writeInput(created.id, phase_two_command);
    var key2_ready = false;
    attempts = 0;
    while (!key2_ready and attempts < 100) : (attempts += 1) {
        var key_snapshot = try client.snapshot(created.id);
        defer key_snapshot.deinit(alloc);
        key2_ready = snapshotContains(&key_snapshot, "KEY2_READY");
        if (!key2_ready) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(key2_ready);
    try client.keyEvent(created.id, .{
        .code = .codepoint,
        .codepoint = '=',
        .shifted_codepoint = '+',
        .modifiers = .{ .shift = true },
        .text = "+",
    });
    try client.keyEvent(created.id, .{
        .code = .left_shift,
        .modifiers = .{ .shift = true },
    });
    try client.keyEvent(created.id, .{ .code = .text, .text = "å" });
    try client.keyEvent(created.id, .{ .code = .enter, .action = .release });
    var saw_key2_reports = false;
    attempts = 0;
    while (!saw_key2_reports and attempts < 100) : (attempts += 1) {
        var key_snapshot = try client.snapshot(created.id);
        defer key_snapshot.deinit(alloc);
        saw_key2_reports = snapshotContains(
            &key_snapshot,
            "KEY2:1b5b36313a34333b323b3433751b5b35373434313b32751b5b303b3b323239751b5b31333b313a3375",
        );
        if (!saw_key2_reports) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(saw_key2_reports);

    // Exercise the real daemon snapshot boundary: arena offsets are private
    // to each process, while the scalar sequence and mode survive protocol v3.
    try client.writeInput(created.id, "printf '\\033[?2027hGRAPHEME:e\\314\\201\\n'\n");
    var saw_grapheme = false;
    attempts = 0;
    while (!saw_grapheme and attempts < 100) : (attempts += 1) {
        var grapheme_snapshot = try client.snapshot(created.id);
        defer grapheme_snapshot.deinit(alloc);
        saw_grapheme = grapheme_snapshot.modes.grapheme_cluster and
            snapshotContainsAcuteE(&grapheme_snapshot);
        if (!saw_grapheme) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(saw_grapheme);

    // Input is byte-transparent UTF-8 all the way through the command socket,
    // daemon queue, and PTY. The shell command publishes those exact bytes as
    // an OSC title, which also exercises the snapshot boundary.
    const emoji_title = "EMOJI:😀 👨🏽‍💻 ❤️ 🏳️‍🌈";
    try client.writeInput(
        created.id,
        "printf '\\033]2;" ++ emoji_title ++ "\\007'; sleep 1\n",
    );
    var saw_emoji_title = false;
    attempts = 0;
    while (!saw_emoji_title and attempts < 50) : (attempts += 1) {
        var emoji_snapshot = try client.snapshot(created.id);
        defer emoji_snapshot.deinit(alloc);
        saw_emoji_title = std.mem.eql(u8, emoji_snapshot.title, emoji_title);
        if (!saw_emoji_title) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(saw_emoji_title);

    // OSC is an untrusted byte protocol. A malformed title is made safe at
    // the daemon session boundary instead of becoming a null NSString and
    // aborting the viewer in NSWindow.setTitle:.
    try client.writeInput(created.id, "printf '\\033]2;bad\\377title\\007'; sleep 1\n");
    var saw_safe_title = false;
    attempts = 0;
    while (!saw_safe_title and attempts < 50) : (attempts += 1) {
        var safe_snapshot = try client.snapshot(created.id);
        defer safe_snapshot.deinit(alloc);
        saw_safe_title = std.mem.eql(u8, safe_snapshot.title, "bad�title");
        if (!saw_safe_title) try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(saw_safe_title);

    const pid_path = try std.fs.path.join(alloc, &.{ home, "shell.pid" });
    defer alloc.free(pid_path);
    const command = try std.fmt.allocPrint(
        alloc,
        "trap '' HUP; echo $$ > '{s}'; sleep 30\n",
        .{pid_path},
    );
    defer alloc.free(command);
    try client.writeInput(created.id, command);
    var shell_pid: ?c.pid_t = null;
    attempts = 0;
    while (shell_pid == null and attempts < 100) : (attempts += 1) {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, pid_path, alloc, .limited(64)) catch {
            try io.sleep(.fromMilliseconds(20), .awake);
            continue;
        };
        defer alloc.free(bytes);
        shell_pid = std.fmt.parseInt(c.pid_t, std.mem.trim(u8, bytes, " \r\n"), 10) catch null;
    }
    try std.testing.expect(shell_pid != null);

    try client.closeSession(created.id);
    try std.testing.expectError(error.RemoteError, client.closeSession(created.id));
    try std.testing.expect(!client.isDisconnected());
    var collapsed_registry = try client.listRegistry();
    try std.testing.expectEqual(@as(usize, 1), collapsed_registry.sessions.len);
    try std.testing.expectEqual(@as(usize, 1), collapsed_registry.display_items.len);
    try std.testing.expectEqual(partner.id, collapsed_registry.display_items[0].single);
    collapsed_registry.deinit(alloc);
    var child_gone = false;
    attempts = 0;
    while (attempts < 175) : (attempts += 1) {
        const rc = c.kill(shell_pid.?, @enumFromInt(0));
        if (rc < 0 and c.errno(rc) == .SRCH) {
            child_gone = true;
            break;
        }
        try io.sleep(.fromMilliseconds(20), .awake);
    }
    try std.testing.expect(child_gone);
    try client.closeSession(partner.id);
    const final = try client.list();
    defer freeMetadata(alloc, final);
    try std.testing.expectEqual(@as(usize, 0), final.len);
}
