//! Daemon-owned PTY/VT session state. Each Session is address-stable because
//! its detached PTY reader holds a pointer to it. The generic Manager owns only
//! an ordered pointer registry and is also reused for GUI-side remote handles.

const std = @import("std");
const vt = @import("../vt.zig");
const pty_mod = @import("pty.zig");
const title_mod = @import("title.zig");
const graphics_mod = @import("graphics.zig");
const working_directory = @import("working_directory.zig");
const c = std.c;

pub const WakeFn = *const fn (*Session) void;
pub const input_queue_capacity: usize = 8 * 1024 * 1024;
const reply_queue_capacity: usize = 64 * 1024;
const wake_event_ident: usize = 1;
const animation_event_ident: usize = 2;

fn resourceFromResult(result: graphics_mod.Result) vt.graphics.Resource {
    return .{
        .image_id = result.image_id,
        .image_number = result.image_number,
        .generation = result.generation,
        .width = result.width,
        .height = result.height,
    };
}

fn placementError(err: vt.graphics.CommitError) []const u8 {
    return switch (err) {
        error.InvalidPlacement => "EINVAL:invalid placement",
        error.PlacementQuota => "ENOSPC:placement quota exhausted",
        error.ParentNotFound => "ENOPARENT:parent placement not found",
        error.ParentCycle => "ECYCLE:relative placement cycle",
        error.ParentTooDeep => "ETOODEEP:relative placement chain too deep",
    };
}

const InputQueue = struct {
    bytes: std.ArrayList(u8) = .empty,
    head: usize = 0,

    fn pending(self: *const InputQueue) usize {
        return self.bytes.items.len - self.head;
    }

    fn enqueue(
        self: *InputQueue,
        alloc: std.mem.Allocator,
        data: []const u8,
        capacity: usize,
    ) !void {
        const queued = self.pending();
        if (data.len > capacity - queued) return error.InputQueueFull;
        if (self.head > 0 and self.bytes.capacity - self.bytes.items.len < data.len) {
            std.mem.copyForwards(u8, self.bytes.items[0..queued], self.bytes.items[self.head..]);
            self.bytes.items.len = queued;
            self.head = 0;
        }
        try self.bytes.appendSlice(alloc, data);
    }

    fn readable(self: *const InputQueue) []const u8 {
        return self.bytes.items[self.head..];
    }

    fn consume(self: *InputQueue, count: usize) void {
        std.debug.assert(count <= self.pending());
        self.head += count;
        if (self.head == self.bytes.items.len) {
            self.bytes.clearRetainingCapacity();
            self.head = 0;
        }
    }

    fn deinit(self: *InputQueue, alloc: std.mem.Allocator) void {
        self.bytes.deinit(alloc);
        self.* = .{};
    }
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    id: u64,
    v: vt.Vt,
    graphics_store: graphics_mod.Store = .{},
    pty: pty_mod.Pty,
    refs: std.atomic.Value(usize) = .init(1),
    kq: std.atomic.Value(c.fd_t) = .init(-1),
    animation_timer_armed: bool = false,

    input_mutex: std.Io.Mutex = .init,
    viewer_input: InputQueue = .{},
    terminal_replies: InputQueue = .{},

    mutex: std.Io.Mutex = .init,
    bell_pending: std.atomic.Value(bool) = .init(false),
    exited: std.atomic.Value(bool) = .init(false),
    focused: std.atomic.Value(bool) = .init(false),
    working: std.atomic.Value(bool) = .init(false),
    attention_pending: std.atomic.Value(bool) = .init(false),

    title_mutex: std.Io.Mutex = .init,
    title_buf: [512]u8 = undefined,
    title_len: usize = 0,
    cwd_mutex: std.Io.Mutex = .init,
    cwd_buf: [pty_mod.max_path_len]u8 = undefined,
    cwd_len: usize = 0,
    metadata_dirty: std.atomic.Value(bool) = .init(false),

    pub fn create(
        gpa: std.mem.Allocator,
        io: std.Io,
        env: *const std.process.Environ.Map,
        id: u64,
        cols: u16,
        rows: u16,
        cwd: ?[]const u8,
    ) !*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);

        var v = try vt.Vt.init(gpa, cols, rows);
        errdefer v.deinit();
        const pty = try pty_mod.Pty.spawn(gpa, .{
            .env = env,
            .cwd = cwd,
            .cols = cols,
            .rows = rows,
        });

        self.* = .{
            .gpa = gpa,
            .io = io,
            .id = id,
            .v = v,
            .graphics_store = .{ .temporary_directory = env.get("TMPDIR") },
            .pty = pty,
        };
        self.setTitle("Boring Terminal");
        return self;
    }

    /// Only for error cleanup before a reader thread has been detached.
    pub fn destroyUnstarted(self: *Session) void {
        // No registered session can observe or recover this child. Do not use
        // the user-facing close grace period here: a login shell may ignore
        // SIGHUP while waiting on startup files, which would block the command
        // connection that is rolling the failed creation back.
        self.pty.hangup();
        self.pty.kill();
        self.pty.wait();
        self.pty.closeFd();
        self.deinitInputQueues();
        self.graphics_store.deinit(self.gpa);
        self.v.deinit();
        self.gpa.destroy(self);
    }

    pub fn startReader(self: *Session, wake: WakeFn) !void {
        try self.pty.setNonBlocking();
        const kq = c.kqueue();
        if (kq < 0) return error.KqueueFailed;
        errdefer _ = c.close(kq);
        if (c.fcntl(kq, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return error.FcntlFailed;
        const changes = [_]c.Kevent{
            makeKevent(@intCast(self.pty.master), c.EVFILT.READ, c.EV.ADD | c.EV.ENABLE | c.EV.CLEAR, 0),
            makeKevent(@intCast(self.pty.master), c.EVFILT.WRITE, c.EV.ADD | c.EV.DISABLE | c.EV.CLEAR, 0),
            makeKevent(wake_event_ident, c.EVFILT.USER, c.EV.ADD | c.EV.ENABLE | c.EV.CLEAR, 0),
        };
        if (!submitKevents(kq, &changes)) return error.KqueueFailed;
        self.kq.store(kq, .release);
        errdefer self.kq.store(-1, .release);
        self.retain();
        errdefer self.release();
        const reader = try std.Thread.spawn(.{}, ioLoop, .{ self, wake });
        reader.detach();
    }

    pub fn queueInput(self: *Session, bytes: []const u8) !void {
        if (self.exited.load(.acquire)) return error.SessionExited;
        {
            self.input_mutex.lockUncancelable(self.io);
            defer self.input_mutex.unlock(self.io);
            try self.viewer_input.enqueue(self.gpa, bytes, input_queue_capacity);
        }
        self.triggerWriter();
    }

    /// Encode a complete paste against authoritative mode-2004 state and
    /// admit it to the viewer-input queue as one all-or-nothing operation.
    pub fn queuePaste(self: *Session, bytes: []const u8) !void {
        if (self.exited.load(.acquire)) return error.SessionExited;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const bracketed = self.v.term.modes.bracketed_paste;
        const encoded_len = try vt.paste.encodedLen(bytes.len, bracketed);
        if (encoded_len > input_queue_capacity) return error.InputQueueFull;
        const encoded = try self.gpa.alloc(u8, encoded_len);
        defer self.gpa.free(encoded);
        const result = try vt.paste.encode(encoded, bytes, bracketed);
        try self.queueInput(result);
    }

    /// Translate a viewer semantic event under the authoritative VT modes.
    /// Returns whether mouse reporting owned the event, even when legacy
    /// coordinate limits or tracking policy intentionally suppress bytes.
    pub fn queueMouse(self: *Session, source: vt.mouse.Event) !bool {
        if (self.exited.load(.acquire)) return error.SessionExited;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const term = self.v.term;
        if (term.modes.mouse_tracking == .none) return false;
        if (!term.on_alt and term.viewportOffset() != 0) return false;

        var event = source;
        event.col = @min(event.col, term.cols - 1);
        event.row = @min(event.row, term.rows - 1);
        event.pixel_x = if (term.pixel_width == 0)
            0
        else
            @min(event.pixel_x, term.pixel_width - 1);
        event.pixel_y = if (term.pixel_height == 0)
            0
        else
            @min(event.pixel_y, term.pixel_height - 1);
        var encoded_buf: [64]u8 = undefined;
        const encoded = try vt.mouse.encode(
            &encoded_buf,
            term.modes.mouse_tracking,
            term.modes.mouse_encoding,
            event,
        );
        if (encoded) |bytes| try self.queueInput(bytes);
        return true;
    }

    /// Encode a native semantic key against the active screen's authoritative
    /// keyboard modes. Releases/text-lane events may intentionally emit no
    /// bytes; they are still valid events rather than protocol errors.
    pub fn queueKey(self: *Session, event: vt.keyboard.Event) !void {
        if (self.exited.load(.acquire)) return error.SessionExited;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // Decimal Unicode scalar lists can expand the bounded 4 KiB semantic
        // text payload substantially. Keep encoding atomic under the terminal
        // lock, then admit the complete sequence to the existing input queue.
        var encoded_buf: [64 * 1024]u8 = undefined;
        const encoded = try vt.keyboard.encode(
            &encoded_buf,
            self.v.term.keyboardFlags(),
            self.v.term.modes.cursor_keys,
            event,
        );
        if (encoded) |bytes| try self.queueInput(bytes);
    }

    pub fn retain(self: *Session) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *Session) void {
        const previous = self.refs.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous != 1) return;
        self.deinitInputQueues();
        self.graphics_store.deinit(self.gpa);
        self.v.deinit();
        self.gpa.destroy(self);
    }

    fn deinitInputQueues(self: *Session) void {
        self.viewer_input.deinit(self.gpa);
        self.terminal_replies.deinit(self.gpa);
    }

    pub fn setFocused(self: *Session, focused: bool) void {
        const previous = self.focused.swap(focused, .acq_rel);
        if (focused) _ = self.attention_pending.swap(false, .acq_rel);
        if (previous == focused) return;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.v.term.modes.focus_reporting) {
            // Terminal-originated events use the bounded priority queue: a
            // full paste must not make a real focus transition disappear.
            self.queueReply(if (focused) "\x1b[I" else "\x1b[O");
        }
    }

    pub fn needsAttention(self: *const Session) bool {
        return self.attention_pending.load(.acquire);
    }

    fn requestAttention(self: *Session) void {
        if (self.focused.load(.acquire)) return;
        self.attention_pending.store(true, .release);
        self.metadata_dirty.store(true, .release);
    }

    fn handlePromptMark(self: *Session, mark: vt.terminal.PromptMark) void {
        switch (mark) {
            .prompt_start => self.working.store(false, .release),
            .command_start => {},
            .command_executed => self.working.store(true, .release),
            .command_finished => |exit_code| {
                self.working.store(false, .release);
                if (exit_code != null and exit_code.? != 0) self.requestAttention();
            },
        }
        self.metadata_dirty.store(true, .release);
    }

    pub fn copyTitleSnapshot(self: *Session, out: []u8) []const u8 {
        self.title_mutex.lockUncancelable(self.io);
        defer self.title_mutex.unlock(self.io);
        const n = @min(out.len, self.title_len);
        @memcpy(out[0..n], self.title_buf[0..n]);
        return out[0..n];
    }

    pub fn copyWorkingDirectorySnapshot(self: *Session, out: []u8) ?[]const u8 {
        self.cwd_mutex.lockUncancelable(self.io);
        defer self.cwd_mutex.unlock(self.io);
        if (self.cwd_len == 0) return null;
        if (out.len < self.cwd_len) return null;
        @memcpy(out[0..self.cwd_len], self.cwd_buf[0..self.cwd_len]);
        return out[0..self.cwd_len];
    }

    fn applyWorkingDirectoryReport(self: *Session, uri: []const u8) void {
        if (uri.len == 0) {
            self.setWorkingDirectory(null);
            return;
        }
        var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = std.posix.gethostname(&hostname_buf) catch return;
        var path_buf: [pty_mod.max_path_len]u8 = undefined;
        switch (working_directory.decode(uri, hostname, &path_buf)) {
            .invalid => return,
            .clear => self.setWorkingDirectory(null),
            .path => |path| self.setWorkingDirectory(path),
        }
    }

    fn setWorkingDirectory(self: *Session, path: ?[]const u8) void {
        self.cwd_mutex.lockUncancelable(self.io);
        defer self.cwd_mutex.unlock(self.io);
        const next = path orelse "";
        if (std.mem.eql(u8, self.cwd_buf[0..self.cwd_len], next)) return;
        std.debug.assert(next.len <= self.cwd_buf.len);
        @memcpy(self.cwd_buf[0..next.len], next);
        self.cwd_len = next.len;
        self.metadata_dirty.store(true, .release);
    }

    fn setTitle(self: *Session, title: []const u8) void {
        self.title_mutex.lockUncancelable(self.io);
        defer self.title_mutex.unlock(self.io);
        self.title_len = title_mod.sanitizeUtf8Into(title, &self.title_buf).len;
        self.metadata_dirty.store(true, .release);
    }

    fn setExitedTitle(self: *Session) void {
        self.title_mutex.lockUncancelable(self.io);
        defer self.title_mutex.unlock(self.io);
        const suffix = " — [exited]";
        const available = self.title_buf.len - self.title_len;
        const n = @min(suffix.len, available);
        @memcpy(self.title_buf[self.title_len..][0..n], suffix[0..n]);
        self.title_len += n;
        self.metadata_dirty.store(true, .release);
    }

    const DrainResult = enum { empty, pending, closed };

    fn triggerWriter(self: *Session) void {
        const kq = self.kq.load(.acquire);
        if (kq < 0) return;
        const change = [_]c.Kevent{
            makeKevent(wake_event_ident, c.EVFILT.USER, 0, c.NOTE.TRIGGER),
        };
        _ = submitKevents(kq, &change);
    }

    fn queueReply(self: *Session, bytes: []const u8) void {
        if (bytes.len == 0) return;
        {
            self.input_mutex.lockUncancelable(self.io);
            defer self.input_mutex.unlock(self.io);
            self.terminal_replies.enqueue(self.gpa, bytes, reply_queue_capacity) catch return;
        }
        self.triggerWriter();
    }

    fn setWriteInterest(self: *Session, enabled: bool) bool {
        const kq = self.kq.load(.acquire);
        if (kq < 0) return false;
        const change = [_]c.Kevent{
            makeKevent(
                @intCast(self.pty.master),
                c.EVFILT.WRITE,
                if (enabled) c.EV.ENABLE else c.EV.DISABLE,
                0,
            ),
        };
        return submitKevents(kq, &change);
    }

    fn drainInput(self: *Session) DrainResult {
        self.input_mutex.lockUncancelable(self.io);
        defer self.input_mutex.unlock(self.io);
        while (true) {
            const queue = if (self.terminal_replies.pending() > 0)
                &self.terminal_replies
            else if (self.viewer_input.pending() > 0)
                &self.viewer_input
            else
                return .empty;
            switch (self.pty.writeNonBlocking(queue.readable())) {
                .bytes => |count| queue.consume(count),
                .would_block => return .pending,
                .closed => return .closed,
            }
        }
    }

    fn handleOutput(self: *Session, bytes: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // Graphics placement can depend on host-decoded dimensions and can
        // move the cursor. Stop the parser only at those action boundaries;
        // ordinary actions remain batched instead of forcing one host call per
        // byte (RFC 0013 phase 2e).
        var offset: usize = 0;
        while (offset < bytes.len) {
            offset += self.v.feedUntilGraphicsAction(bytes[offset..]);
            if (self.v.term.drainActions().len != 0) self.handleActions();
        }
        self.reconcileGraphicsResources();
    }

    fn reconcileGraphicsResources(self: *Session) void {
        self.graphics_store.syncPlacements(self.v.term.graphicsPlacements());
        const orphans = self.v.term.graphicsDrainPendingOrphans();
        self.graphics_store.freeOrphans(self.gpa, orphans.orphanItems());
    }

    fn handleActions(self: *Session) void {
        for (self.v.term.drainActions()) |action| switch (action) {
            .bell => {
                self.bell_pending.store(true, .release);
                self.requestAttention();
            },
            .set_title => |title| self.setTitle(title),
            .cwd_report => |uri| self.applyWorkingDirectoryReport(uri),
            .notify => self.requestAttention(),
            .prompt_mark => |mark| self.handlePromptMark(mark),
            // Replies outrank viewer input so a child waiting for CPR/DA
            // cannot deadlock behind a paste filling the user queue.
            .pty_write => |reply| self.queueReply(reply),
            .graphics => |command| self.handleGraphics(command),
            // The PTY never resizes the window (RFC 0002 policy).
            .resize_request => {},
        };
        self.v.term.clearActions();
    }

    fn handleGraphics(self: *Session, command: vt.graphics.Command) void {
        switch (command) {
            .load => |load| {
                self.graphics_store.syncPlacements(self.v.term.graphicsPlacements());
                var result = self.graphics_store.load(self.gpa, &load);
                if (result.ok and !load.query) {
                    self.v.term.graphicsCommitLoad(&load, resourceFromResult(result)) catch |err| {
                        result.ok = false;
                        result.message = placementError(err);
                    };
                    self.graphics_store.syncPlacements(self.v.term.graphicsPlacements());
                }
                self.graphicsReply(
                    result,
                    load.image_id,
                    load.image_number,
                    if (load.display) load.placement_id else 0,
                    load.quiet,
                );
            },
            .put => |put| {
                var result = self.graphics_store.put(&put);
                if (result.ok) {
                    self.v.term.graphicsCommitPut(&put, resourceFromResult(result)) catch |err| {
                        result.ok = false;
                        result.message = placementError(err);
                    };
                    self.graphics_store.syncPlacements(self.v.term.graphicsPlacements());
                }
                self.graphicsReply(
                    result,
                    put.image_id,
                    put.image_number,
                    put.placement_id,
                    put.quiet,
                );
            },
            .delete => |delete| {
                if (delete.selector == .animation_frames) {
                    const result = self.graphics_store.deleteFrame(self.gpa, delete);
                    if (result.removed_image) {
                        _ = self.v.term.graphicsRemoveImagePlacements(result.image_id);
                        self.reconcileGraphicsResources();
                    }
                    self.armAnimationTimer(nowMilliseconds(self.io));
                    return;
                }
                const resolved = self.graphics_store.resolveDelete(delete);
                const removed = self.v.term.graphicsDelete(delete, resolved);
                self.graphics_store.syncPlacements(self.v.term.graphicsPlacements());
                self.graphics_store.freeDeleted(self.gpa, delete, resolved, removed.items());
            },
            .frame_load => |load| {
                const result = self.graphics_store.loadFrame(self.gpa, &load);
                self.graphicsReply(result, load.image_id, load.image_number, 0, load.quiet);
                self.armAnimationTimer(nowMilliseconds(self.io));
            },
            .animation => |animation| {
                const now_ms = nowMilliseconds(self.io);
                const result = self.graphics_store.controlAnimation(animation, now_ms);
                self.graphicsReply(
                    result,
                    animation.image_id,
                    animation.image_number,
                    0,
                    animation.quiet,
                );
                self.armAnimationTimer(now_ms);
            },
            .frame_compose => |compose| {
                const result = self.graphics_store.composeFrame(self.gpa, compose);
                self.graphicsReply(result, compose.image_id, compose.image_number, 0, compose.quiet);
            },
        }
    }

    /// Called with the terminal mutex held. The one-shot timer lives on the
    /// existing PTY kqueue so animation never depends on an AppKit run loop.
    fn armAnimationTimer(self: *Session, now_ms: i64) void {
        const kq = self.kq.load(.acquire);
        if (kq < 0) return;
        if (self.graphics_store.nextAnimationDelayMs(now_ms)) |delay| {
            const change = [_]c.Kevent{.{
                .ident = animation_event_ident,
                .filter = c.EVFILT.TIMER,
                .flags = c.EV.ADD | c.EV.ENABLE | c.EV.ONESHOT,
                // Darwin EVFILT_TIMER uses milliseconds when no NOTE unit
                // flag is supplied.
                .fflags = 0,
                .data = @intCast(@max(delay, 1)),
                .udata = 0,
            }};
            if (submitKevents(kq, &change)) self.animation_timer_armed = true;
        } else if (self.animation_timer_armed) {
            const change = [_]c.Kevent{.{
                .ident = animation_event_ident,
                .filter = c.EVFILT.TIMER,
                .flags = c.EV.DELETE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            }};
            _ = submitKevents(kq, &change);
            self.animation_timer_armed = false;
        }
    }

    fn graphicsReply(
        self: *Session,
        result: graphics_mod.Result,
        requested_id: u32,
        image_number: u32,
        placement_id: u32,
        quiet: u2,
    ) void {
        if (quiet == 2 or (result.ok and quiet == 1) or result.implicit_id) return;
        const image_id = if (result.image_id != 0) result.image_id else requested_id;
        if (image_id == 0 and image_number == 0) return;
        var reply: [320]u8 = undefined;
        var controls: [128]u8 = undefined;
        var controls_len: usize = 0;
        if (image_id != 0) controls_len += (std.fmt.bufPrint(
            controls[controls_len..],
            "i={d}",
            .{image_id},
        ) catch return).len;
        if (image_number != 0) controls_len += (std.fmt.bufPrint(
            controls[controls_len..],
            "{s}I={d}",
            .{ if (controls_len == 0) "" else ",", image_number },
        ) catch return).len;
        if (placement_id != 0) controls_len += (std.fmt.bufPrint(
            controls[controls_len..],
            "{s}p={d}",
            .{ if (controls_len == 0) "" else ",", placement_id },
        ) catch return).len;
        const bytes = std.fmt.bufPrint(
            &reply,
            "\x1b_G{s};{s}\x1b\\",
            .{ controls[0..controls_len], result.message },
        ) catch return;
        self.queueReply(bytes);
    }

    fn drainOutput(self: *Session, wake: WakeFn, eof_hint: bool) bool {
        var buf: [65536]u8 = undefined;
        while (true) switch (self.pty.readNonBlocking(&buf)) {
            .bytes => |count| {
                self.handleOutput(buf[0..count]);
                wake(self);
            },
            .would_block => return eof_hint,
            .eof => return true,
        };
    }

    fn ioLoop(self: *Session, wake: WakeFn) void {
        defer self.release();
        const kq = self.kq.load(.acquire);
        var events: [4]c.Kevent = undefined;
        var normal_eof = false;
        event_loop: while (true) {
            const count = waitKevents(kq, &events) orelse break;
            for (events[0..count]) |event| {
                if (event.flags & c.EV.ERROR != 0) break :event_loop;
                switch (event.filter) {
                    c.EVFILT.READ => {
                        if (self.drainOutput(wake, event.flags & c.EV.EOF != 0)) {
                            normal_eof = true;
                            break :event_loop;
                        }
                    },
                    c.EVFILT.USER, c.EVFILT.WRITE => switch (self.drainInput()) {
                        .empty => if (!self.setWriteInterest(false)) break :event_loop,
                        .pending => if (!self.setWriteInterest(true)) break :event_loop,
                        .closed => break :event_loop,
                    },
                    c.EVFILT.TIMER => if (event.ident == animation_event_ident) {
                        self.mutex.lockUncancelable(self.io);
                        self.animation_timer_armed = false;
                        const now_ms = nowMilliseconds(self.io);
                        const changed = self.graphics_store.advanceAnimations(now_ms);
                        self.armAnimationTimer(now_ms);
                        self.mutex.unlock(self.io);
                        if (changed) wake(self);
                    },
                    else => {},
                }
            }
        }

        if (!normal_eof) self.pty.hangup();
        self.exited.store(true, .release);
        self.working.store(false, .release);
        self.mutex.lockUncancelable(self.io);
        self.v.term.forceEndSynchronizedOutput();
        self.mutex.unlock(self.io);
        self.setExitedTitle();
        const owned_kq = self.kq.swap(-1, .acq_rel);
        if (owned_kq >= 0) _ = c.close(owned_kq);
        self.pty.wait();
        self.pty.closeFd();
        wake(self);
    }
};

fn nowMilliseconds(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

fn makeKevent(ident: usize, filter: i16, flags: u16, fflags: u32) c.Kevent {
    return .{
        .ident = ident,
        .filter = filter,
        .flags = flags,
        .fflags = fflags,
        .data = 0,
        .udata = 0,
    };
}

fn submitKevents(kq: c.fd_t, changes: []const c.Kevent) bool {
    var ignored: [1]c.Kevent = undefined;
    while (true) {
        const rc = c.kevent(kq, changes.ptr, @intCast(changes.len), &ignored, 0, null);
        if (rc >= 0) return true;
        if (c.errno(rc) != .INTR) return false;
    }
}

fn waitKevents(kq: c.fd_t, events: []c.Kevent) ?usize {
    var ignored: [1]c.Kevent = undefined;
    while (true) {
        const rc = c.kevent(kq, &ignored, 0, events.ptr, @intCast(events.len), null);
        if (rc >= 0) return @intCast(rc);
        if (c.errno(rc) != .INTR) return null;
    }
}

test "bounded input queue preserves unread bytes across compaction" {
    const alloc = std.testing.allocator;
    var queue: InputQueue = .{};
    defer queue.deinit(alloc);

    try queue.enqueue(alloc, "abcd", 4);
    try std.testing.expectError(error.InputQueueFull, queue.enqueue(alloc, "e", 4));
    try std.testing.expectEqualStrings("abcd", queue.readable());
    queue.consume(2);
    try queue.enqueue(alloc, "ef", 4);
    try std.testing.expectEqualStrings("cdef", queue.readable());
    queue.consume(4);
    try std.testing.expectEqual(@as(usize, 0), queue.pending());
}

/// Generic so registry semantics stay headless-testable without constructing
/// a PTY-backed Session.
pub fn Manager(comptime SessionType: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        sessions: std.ArrayList(*SessionType) = .empty,
        active_index: usize = 0,

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *Self) void {
            self.sessions.deinit(self.gpa);
        }

        pub fn append(self: *Self, session: *SessionType) !usize {
            try self.sessions.append(self.gpa, session);
            return self.sessions.items.len - 1;
        }

        /// Remove one session while preserving order and select the nearest
        /// surviving row. Returns null for an invalid index.
        pub fn remove(self: *Self, index: usize) ?*SessionType {
            if (index >= self.sessions.items.len) return null;
            const removed = self.sessions.items[index];
            const old_len = self.sessions.items.len;
            std.mem.copyForwards(
                *SessionType,
                self.sessions.items[index .. old_len - 1],
                self.sessions.items[index + 1 .. old_len],
            );
            self.sessions.items.len = old_len - 1;
            if (self.sessions.items.len == 0) {
                self.active_index = 0;
            } else if (index < self.active_index) {
                self.active_index -= 1;
            } else if (self.active_index >= self.sessions.items.len) {
                self.active_index = self.sessions.items.len - 1;
            }
            return removed;
        }

        pub fn active(self: *const Self) ?*SessionType {
            if (self.sessions.items.len == 0) return null;
            return self.sessions.items[self.active_index];
        }

        pub fn select(self: *Self, index: usize) bool {
            if (index >= self.sessions.items.len) return false;
            self.active_index = index;
            return true;
        }

        pub fn next(self: *Self) bool {
            if (self.sessions.items.len < 2) return false;
            self.active_index = (self.active_index + 1) % self.sessions.items.len;
            return true;
        }

        pub fn previous(self: *Self) bool {
            if (self.sessions.items.len < 2) return false;
            self.active_index = if (self.active_index == 0)
                self.sessions.items.len - 1
            else
                self.active_index - 1;
            return true;
        }
    };
}

pub const SessionManager = Manager(Session);

test "session manager preserves order and switches safely" {
    const FakeSession = struct { id: u8 };
    var first: FakeSession = .{ .id = 1 };
    var second: FakeSession = .{ .id = 2 };
    var third: FakeSession = .{ .id = 3 };

    var manager = Manager(FakeSession).init(std.testing.allocator);
    defer manager.deinit();
    try std.testing.expect((try manager.append(&first)) == 0);
    try std.testing.expect((try manager.append(&second)) == 1);
    try std.testing.expect((try manager.append(&third)) == 2);
    try std.testing.expect(manager.active().? == &first);

    try std.testing.expect(manager.select(2));
    try std.testing.expect(manager.active().? == &third);
    try std.testing.expect(manager.next());
    try std.testing.expect(manager.active().? == &first);
    try std.testing.expect(manager.previous());
    try std.testing.expect(manager.active().? == &third);
    try std.testing.expect(!manager.select(3));
    try std.testing.expect(manager.active().? == &third);

    try std.testing.expect(manager.remove(1).? == &second);
    try std.testing.expect(manager.active().? == &third);
    try std.testing.expect(manager.active_index == 1);
    try std.testing.expect(manager.remove(1).? == &third);
    try std.testing.expect(manager.active().? == &first);
    try std.testing.expect(manager.active_index == 0);
    try std.testing.expect(manager.remove(4) == null);
}
