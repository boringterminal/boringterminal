//! The AppKit shell (RFC 0005/0006): one NSApplication, one window, an
//! daemon-backed session registry, and one CAMetalLayer-backed view class built
//! at runtime. Keyboard
//! follows the two-lane rule — specials and ⌃ combos encode directly, all
//! remaining text goes through interpretKeyEvents:/NSTextInputClient so
//! dead keys and IME commits share one ordered semantic transaction.

const std = @import("std");
const config_mod = @import("../config.zig");
const objc = @import("../render/objc.zig");
const renderer_mod = @import("../render/renderer.zig");
const vt = @import("../vt.zig");
const daemon_client = @import("daemon_client.zig");
const daemon_protocol = @import("../daemon/protocol.zig");
const product_version = @import("../version.zig");
const display_registry = @import("../daemon/display_registry.zig");
const input = @import("input.zig");
const key_normalizer = @import("key_normalizer.zig");
const title_mod = @import("title.zig");
const sidebar_layout = @import("sidebar_layout.zig");
const display_model = @import("display_model.zig");
const config_watcher = @import("config_watcher.zig");
const search_bar_mod = @import("search_bar.zig");
const hyperlink_mod = @import("hyperlink.zig");
const path_drop = @import("path_drop.zig");
const font_zoom = @import("font_zoom.zig");

extern "c" fn NSBeep() void;
extern "c" fn CGEventSourceFlagsState(state_id: u32) u64;
extern "c" fn dispatch_async_f(
    queue: *anyopaque,
    context: ?*anyopaque,
    work: *const fn (?*anyopaque) callconv(.c) void,
) void;
const CVDisplayLinkRef = ?*anyopaque;
const CVReturn = i32;
const CVOptionFlags = u64;
extern "c" fn CVDisplayLinkCreateWithActiveCGDisplays(out: *CVDisplayLinkRef) CVReturn;
extern "c" fn CVDisplayLinkSetOutputCallback(
    link: CVDisplayLinkRef,
    callback: *const fn (
        CVDisplayLinkRef,
        *const anyopaque,
        *const anyopaque,
        CVOptionFlags,
        *CVOptionFlags,
        ?*anyopaque,
    ) callconv(.c) CVReturn,
    context: ?*anyopaque,
) CVReturn;
extern "c" fn CVDisplayLinkStart(link: CVDisplayLinkRef) CVReturn;
extern "c" fn CVDisplayLinkStop(link: CVDisplayLinkRef) CVReturn;
extern "c" fn CFRelease(value: ?*const anyopaque) void;
const dispatch_main_q = @extern(*anyopaque, .{ .name = "_dispatch_main_q" });
const ns_run_loop_common_modes = @extern(*objc.Id, .{ .name = "NSRunLoopCommonModes" });
const ut_type_plain_text = @extern(*objc.Id, .{ .name = "UTTypePlainText" });

const initial_cols: u16 = 100;
const initial_rows: u16 = 28;
const sidebar_row_height = sidebar_layout.row_height;
const sidebar_horizontal_padding = sidebar_layout.horizontal_padding;
const sidebar_drag_type = "com.boringterminal.session-display-item";
const ns_drag_operation_none: objc.NSUInteger = 0;
const ns_drag_operation_copy: objc.NSUInteger = 1;
const ns_drag_operation_move: objc.NSUInteger = 16;

const SidebarDrop = union(enum) {
    none,
    reorder: usize,
    pair: struct { target_id: u64, source_on_left: bool },
    swap,
    extract: usize,
    transfer: struct { target_id: u64, member_on_left: bool },
};

const TextCommit = struct {
    offset: u16,
    len: u16,
    replacement_count: u16,
};

const KeyTextTransaction = struct {
    active: bool = false,
    marked_before: bool = false,
    bytes: [vt.keyboard.max_text_bytes]u8 = undefined,
    len: u16 = 0,
    commits: [32]TextCommit = undefined,
    commit_count: u8 = 0,

    fn begin(self: *KeyTextTransaction, marked_before: bool) void {
        self.active = true;
        self.marked_before = marked_before;
        self.len = 0;
        self.commit_count = 0;
    }

    fn end(self: *KeyTextTransaction) void {
        self.active = false;
    }

    fn append(self: *KeyTextTransaction, committed: []const u8, replacement_count: usize) void {
        if (committed.len == 0 or self.commit_count == self.commits.len or
            committed.len > self.bytes.len - self.len)
            return;
        const offset = self.len;
        @memcpy(self.bytes[offset..][0..committed.len], committed);
        self.len += @intCast(committed.len);
        self.commits[self.commit_count] = .{
            .offset = offset,
            .len = @intCast(committed.len),
            .replacement_count = @intCast(@min(replacement_count, std.math.maxInt(u16))),
        };
        self.commit_count += 1;
    }

    fn text(self: *const KeyTextTransaction, commit: TextCommit) []const u8 {
        return self.bytes[commit.offset..][0..commit.len];
    }
};

const PreeditState = struct {
    bytes: [vt.keyboard.max_text_bytes]u8 = undefined,
    len: u16 = 0,
    selected_utf8: u16 = 0,
    selected_utf16: objc.NSRange = .{ .location = 0, .length = 0 },
    marked_utf16_len: u16 = 0,

    fn clear(self: *PreeditState) void {
        self.len = 0;
        self.selected_utf8 = 0;
        self.selected_utf16 = .{ .location = 0, .length = 0 };
        self.marked_utf16_len = 0;
    }

    fn text(self: *const PreeditState) []const u8 {
        return self.bytes[0..self.len];
    }

    fn active(self: *const PreeditState) bool {
        return self.len != 0;
    }
};

const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    client: daemon_client.Client,
    sessions: daemon_client.SessionManager,
    display_items: std.ArrayList(daemon_protocol.DisplayItem) = .empty,
    display_registry_dirty: std.atomic.Value(bool) = .init(false),
    sessions_mutex: std.Io.Mutex = .init,
    active_session_addr: std.atomic.Value(usize) = .init(0),
    renderer: renderer_mod.Renderer,
    config: config_mod.Config,
    font_zoom: font_zoom.State = .{},
    config_path: []u8,
    config_directory: []u8,
    config_watcher: ?*config_watcher.Watcher = null,
    config_reload_queued: std.atomic.Value(bool) = .init(false),

    window: objc.Id = null,
    shortcuts_panel: objc.Id = null,
    root_view: objc.Id = null,
    sidebar: objc.Id = null,
    sidebar_scroll: objc.Id = null,
    sidebar_document: objc.Id = null,
    sidebar_drop_indicator: objc.Id = null,
    sidebar_divider: objc.Id = null,
    sidebar_divider_line: objc.Id = null,
    pair_divider: objc.Id = null,
    pair_divider_line: objc.Id = null,
    pair_resize_active: bool = false,
    search_bar: search_bar_mod.SearchBar = .{},
    search_visible: bool = false,
    search_session_id: ?u64 = null,
    session_buttons: std.ArrayList(objc.Id) = .empty,
    session_shortcut_buttons: std.ArrayList(objc.Id) = .empty,
    session_close_buttons: std.ArrayList(objc.Id) = .empty,
    session_attention_layers: std.ArrayList(objc.Id) = .empty,
    pair_left_buttons: std.ArrayList(objc.Id) = .empty,
    pair_right_buttons: std.ArrayList(objc.Id) = .empty,
    pair_left_shortcut_buttons: std.ArrayList(objc.Id) = .empty,
    pair_right_shortcut_buttons: std.ArrayList(objc.Id) = .empty,
    pair_left_attention_layers: std.ArrayList(objc.Id) = .empty,
    pair_right_attention_layers: std.ArrayList(objc.Id) = .empty,
    pair_left_close_buttons: std.ArrayList(objc.Id) = .empty,
    pair_right_close_buttons: std.ArrayList(objc.Id) = .empty,
    pair_separator_layers: std.ArrayList(objc.Id) = .empty,
    session_context_menus: std.ArrayList(objc.Id) = .empty,
    session_context_items: std.ArrayList(objc.Id) = .empty,
    session_context_swap_items: std.ArrayList(objc.Id) = .empty,
    session_context_zoom_items: std.ArrayList(objc.Id) = .empty,
    sidebar_toggle_button: objc.Id = null,
    titlebar_attention_layer: objc.Id = null,
    session_bar_visible: bool = true,
    sidebar_preferred_width: f32 = sidebar_layout.default_width,
    sidebar_effective_width: f32 = sidebar_layout.default_width,
    sidebar_resize_active: bool = false,
    sidebar_resize_anchor_x: f32 = 0,
    sidebar_resize_start_width: f32 = sidebar_layout.default_width,
    show_session_shortcuts: bool = false,
    hovered_session_index: ?usize = null,
    hovered_pair_member_id: ?u64 = null,
    dragged_display_index: ?usize = null,
    dragged_pair_member_id: ?u64 = null,
    sidebar_drop: SidebarDrop = .none,
    shortcut_hint_timer: objc.Id = null,
    session_row_class: objc.Class = null,
    session_row_cell_class: objc.Class = null,
    pair_segment_class: objc.Class = null,
    pair_segment_cell_class: objc.Class = null,
    window_is_key: bool = false,
    view: objc.Id = null,
    layer: objc.Id = null,
    scale: f32 = 2,
    view_size: [2]f32 = .{ 0, 0 },
    cols: u16 = initial_cols,
    rows: u16 = initial_rows,
    pixel_width: u16 = 0,
    pixel_height: u16 = 0,

    /// Selection gesture state (main thread). A single press stays pending
    /// until it crosses the drag threshold, so a plain click only clears.
    selection_pending: bool = false,
    selection_dragging: bool = false,
    left_mouse_reported: bool = false,
    selection_anchor: CellPoint = .{ .row = 0, .col = 0 },
    selection_press_x: f32 = 0,
    selection_press_y: f32 = 0,
    selection_mode: vt.terminal.SelectionMode = .char,
    selection_scroll_delta: i8 = 0,
    selection_scroll_col: u16 = 0,
    selection_scroll_timer: objc.Id = null,

    /// Viewer-local OSC 8 hover state. Ids are snapshot-local and therefore
    /// always recomputed from the pointer cell before use (RFC 0018).
    hyperlink_command_held: bool = false,
    hovered_hyperlink_session: ?u64 = null,
    hovered_hyperlink_id: u32 = 0,
    hovered_hyperlink_cell: CellPoint = .{ .row = 0, .col = 0 },
    /// Session beneath the pointer. Unlike focus, this distinguishes the two
    /// visible panes and lets a refreshed OSC 22 snapshot update a stationary
    /// native cursor.
    pointer_session_id: ?u64 = null,
    applied_pointer_shape: ?vt.mouse.PointerShape = null,

    /// DEC mode 2026 presentation hold (main thread). The epoch lets a
    /// repeated BSU re-arm the watchdog without coupling time to vt.
    sync_output_timer: objc.Id = null,
    sync_output_timer_epoch: u64 = 0,
    sync_output_timer_session: ?*daemon_client.Session = null,

    render_pending: std.atomic.Value(bool) = .init(false),
    display_tick_queued: std.atomic.Value(bool) = .init(false),
    frame_completion_queued: std.atomic.Value(bool) = .init(false),
    /// Cross-thread shutdown gate. The display link may already have queued a
    /// main-thread frame when AppKit begins termination; that frame must not
    /// observe session caches after the compatibility idle drain destroys them.
    terminating: std.atomic.Value(bool) = .init(false),
    display_link: CVDisplayLinkRef = null,
    key_text: KeyTextTransaction = .{},
    preedit: PreeditState = .{},
    /// Main-thread only: inside a live window resize, frames present
    /// synchronously within the window-server transaction (RFC 0009).
    in_live_resize: bool = false,
};

/// The objc callbacks need a stable process-wide home. PTY/VT state lives in
/// boringterminald; these address-stable objects are viewer-side caches.
var app: *App = undefined;

pub fn run(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !void {
    app = try gpa.create(App);
    errdefer gpa.destroy(app);

    // NSApplication first: Metal/AppKit want an app context.
    const ns_app = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSApplication"),
        objc.sel("sharedApplication"),
    );
    _ = objc.msg(*const fn (objc.Id, objc.Sel, objc.NSInteger) callconv(.c) objc.BOOL)(
        ns_app,
        objc.sel("setActivationPolicy:"),
        0, // NSApplicationActivationPolicyRegular
    );

    const scale: f32 = blk: {
        const screen = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
            objc.cls("NSScreen"),
            objc.sel("mainScreen"),
        );
        if (screen == null) break :blk 2.0;
        break :blk @floatCast(objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGFloat)(
            screen,
            objc.sel("backingScaleFactor"),
        ));
    };

    const config_path = try config_mod.path(gpa, env);
    errdefer gpa.free(config_path);
    const config_directory = try config_mod.supportDirectory(gpa, env);
    errdefer gpa.free(config_directory);
    var config = config_mod.loadPath(gpa, io, config_path) catch |err| blk: {
        std.log.err("ignoring invalid config: {s}", .{@errorName(err)});
        break :blk config_mod.Config{};
    };
    errdefer config.deinit(gpa);

    var client = daemon_client.Client.init(gpa, io, env) catch |err| switch (err) {
        error.DaemonUpgradeRequired => blk: {
            if (!recoverUpgradeRequiredDaemon(gpa, io, env)) return;
            break :blk try daemon_client.Client.init(gpa, io, env);
        },
        else => return err,
    };
    errdefer client.deinit();
    const font_options: renderer_mod.FontOptions = .{
        .family = config.font_family,
        .size = config.font_size,
    };
    var renderer = renderer_mod.Renderer.init(gpa, font_options, scale) catch |err| switch (err) {
        error.FontLoad, error.FontNotMonospaced => if (config.font_family != null) blk: {
            std.log.err("configured font rejected ({s}); using the system monospace default", .{@errorName(err)});
            config.deinit(gpa);
            config = .{};
            break :blk try renderer_mod.Renderer.init(gpa, .{}, scale);
        } else return err,
        else => return err,
    };
    errdefer renderer.deinit();
    app.* = .{
        .gpa = gpa,
        .io = io,
        .env = env,
        .client = client,
        .sessions = daemon_client.SessionManager.init(gpa),
        .renderer = renderer,
        .config = config,
        .config_path = config_path,
        .config_directory = config_directory,
    };
    try app.client.startGraphicsReleaseWorker();
    app.client.enableSharedGraphics(app.renderer.sharedImageRowAlignment());
    app.renderer.setFrameCompletionHandler(app, rendererFrameCompleted);
    app.scale = scale;
    loadSessionBarPreferences();

    const launch_cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(launch_cwd);

    var registry = try app.client.listRegistry();
    defer registry.deinit(gpa);
    if (registry.sessions.len == 0) {
        const preferred_cwd: ?[]const u8 = if (std.mem.eql(u8, launch_cwd, "/")) null else launch_cwd;
        var created = try app.client.create(app.cols, app.rows, preferred_cwd);
        defer created.deinit(gpa);
        var daemon_session_owned = true;
        errdefer if (daemon_session_owned) app.client.closeSession(created.id) catch {};
        const first = try daemon_client.Session.create(gpa, io, &app.client, created);
        errdefer first.destroy();
        _ = try app.sessions.append(first);
        try app.display_items.append(gpa, .{ .single = created.id });
        daemon_session_owned = false;
    } else {
        for (registry.sessions) |entry| {
            const session = try daemon_client.Session.create(gpa, io, &app.client, entry);
            errdefer session.destroy();
            _ = try app.sessions.append(session);
        }
        try app.display_items.appendSlice(gpa, registry.display_items);
    }
    const first_id = display_model.focusedId(app.display_items.items[0]);
    _ = selectSessionId(first_id);
    const first = app.sessions.active().?;
    for (app.sessions.sessions.items) |session| {
        try session.startRefreshWorker(refreshWorkerOptions());
    }
    app.active_session_addr.store(@intFromPtr(first), .release);
    updateSessionVisibility();

    try buildWindow();
    buildMenu(ns_app);
    installDelegate(ns_app);
    startDisplayLink() catch |err|
        std.log.warn("display-link scheduling unavailable ({s}); using main-queue coalescing", .{
            @errorName(err),
        });
    defer stopDisplayLink();
    try app.client.startEvents(app, daemonSessionChanged);
    app.config_watcher = config_watcher.Watcher.create(
        gpa,
        app.config_directory,
        app.config_path,
        app,
        configDirectoryChanged,
    ) catch |err| blk: {
        std.log.err("config hot reload unavailable: {s}", .{@errorName(err)});
        break :blk null;
    };
    app.window_is_key = true;
    updateSessionFocus();

    _ = objc.msg(*const fn (objc.Id, objc.Sel, objc.BOOL) callconv(.c) void)(
        ns_app,
        objc.sel("activateIgnoringOtherApps:"),
        1,
    );
    renderNow();
    objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(ns_app, objc.sel("run"));
}

// -- sessions → render scheduling ------------------------------------------

fn activeSession() *daemon_client.Session {
    return app.sessions.active().?;
}

fn sessionIndexById(id: u64) ?usize {
    for (app.sessions.sessions.items, 0..) |session, index| if (session.id == id) return index;
    return null;
}

fn sessionById(id: u64) ?*daemon_client.Session {
    const index = sessionIndexById(id) orelse return null;
    return app.sessions.sessions.items[index];
}

fn selectSessionId(id: u64) bool {
    const index = sessionIndexById(id) orelse return false;
    return app.sessions.select(index);
}

fn selectSessionAndRememberPair(id: u64) bool {
    const display_index = display_model.itemIndex(app.display_items.items, id);
    if (display_index) |index| switch (app.display_items.items[index]) {
        .single => {},
        .pair => |pair| if (pair.focusedId() != id) {
            app.client.rememberPairFocus(id) catch return false;
            app.display_registry_dirty.store(true, .release);
            syncDisplayRegistry();
        },
    };
    return selectSessionId(id);
}

fn activeDisplayIndex() ?usize {
    return display_model.itemIndex(app.display_items.items, activeSession().id);
}

fn zoomedPairMember(pair: display_registry.Pair) ?u64 {
    return if (pair.zoomed) pair.focusedId() else null;
}

fn allocateSession() !*daemon_client.Session {
    var metadata = try app.client.create(app.cols, app.rows, null);
    defer metadata.deinit(app.gpa);
    var daemon_session_owned = true;
    errdefer if (daemon_session_owned) app.client.closeSession(metadata.id) catch {};
    if (app.pixel_width > 0 and app.pixel_height > 0) {
        try app.client.resize(
            metadata.id,
            app.cols,
            app.rows,
            app.pixel_width,
            app.pixel_height,
        );
    }
    const session = try daemon_client.Session.create(app.gpa, app.io, &app.client, metadata);
    errdefer session.destroy();
    try session.startRefreshWorker(refreshWorkerOptions());
    try app.display_items.ensureUnusedCapacity(app.gpa, 1);
    app.sessions_mutex.lockUncancelable(app.io);
    defer app.sessions_mutex.unlock(app.io);
    _ = try app.sessions.append(session);
    app.display_items.appendAssumeCapacity(.{ .single = metadata.id });
    daemon_session_owned = false;
    return session;
}

fn allocateSessionBeside(existing_id: u64, geometry: display_model.PairGeometry) !*daemon_client.Session {
    var metadata = try app.client.createBeside(
        existing_id,
        geometry.right_cols,
        geometry.rows,
        null,
    );
    defer metadata.deinit(app.gpa);
    var daemon_session_owned = true;
    errdefer if (daemon_session_owned) app.client.closeSession(metadata.id) catch {};
    const session = try daemon_client.Session.create(app.gpa, app.io, &app.client, metadata);
    errdefer session.destroy();
    try session.startRefreshWorker(refreshWorkerOptions());
    app.sessions_mutex.lockUncancelable(app.io);
    defer app.sessions_mutex.unlock(app.io);
    _ = try app.sessions.append(session);
    daemon_session_owned = false;
    return session;
}

fn createSession() void {
    _ = allocateSession() catch {
        NSBeep();
        return;
    };
    _ = app.sessions.select(app.sessions.sessions.items.len - 1);
    activateSelectedSession();
}

fn canCreateSessionBeside() bool {
    if (!app.client.supportsCreateBeside()) return false;
    const display_index = activeDisplayIndex() orelse return false;
    switch (app.display_items.items[display_index]) {
        .single => {},
        .pair => return false,
    }
    const metrics = app.renderer.cellMetrics();
    return display_model.pairGeometry(
        app.view_size[0],
        app.view_size[1],
        display_registry.default_ratio,
        metrics.cell_width,
        metrics.cell_height,
    ) != null;
}

fn createSessionBeside() void {
    if (!canCreateSessionBeside()) return NSBeep();
    const display_index = activeDisplayIndex() orelse return NSBeep();
    const existing_id = switch (app.display_items.items[display_index]) {
        .single => |id| id,
        .pair => unreachable,
    };
    const metrics = app.renderer.cellMetrics();
    const geometry = display_model.pairGeometry(
        app.view_size[0],
        app.view_size[1],
        display_registry.default_ratio,
        metrics.cell_width,
        metrics.cell_height,
    ) orelse return NSBeep();
    const session = allocateSessionBeside(existing_id, geometry) catch return NSBeep();
    app.display_items.items[display_index] = .{ .pair = .{
        .left = existing_id,
        .right = session.id,
        .focused = .right,
        .ratio = display_registry.default_ratio,
    } };
    app.display_registry_dirty.store(true, .release);
    _ = selectSessionId(session.id);
    activateSelectedSession();
}

fn selectDisplayItem(index: usize) void {
    if (index >= app.display_items.items.len) return;
    if (!selectSessionId(display_model.focusedId(app.display_items.items[index]))) return;
    activateSelectedSession();
}

fn selectNextSession() void {
    const id = display_model.adjacentSessionId(
        app.display_items.items,
        activeSession().id,
        .next,
    ) orelse return;
    if (!selectSessionAndRememberPair(id)) return;
    activateSelectedSession();
}

fn selectPreviousSession() void {
    const id = display_model.adjacentSessionId(
        app.display_items.items,
        activeSession().id,
        .previous,
    ) orelse return;
    if (!selectSessionAndRememberPair(id)) return;
    activateSelectedSession();
}

fn pairActiveSession(direction: display_model.Direction) void {
    const display_index = activeDisplayIndex() orelse return NSBeep();
    const candidate = display_model.pairCandidate(
        app.display_items.items,
        display_index,
        direction,
    ) orelse return NSBeep();
    const metrics = app.renderer.cellMetrics();
    if (display_model.pairGeometry(
        app.view_size[0],
        app.view_size[1],
        display_registry.default_ratio,
        metrics.cell_width,
        metrics.cell_height,
    ) == null) return NSBeep();
    const active_id = activeSession().id;
    app.client.pairSessions(candidate.left, candidate.right) catch return NSBeep();
    app.display_registry_dirty.store(true, .release);
    syncDisplayRegistry();
    _ = selectSessionId(active_id);
    activateSelectedSession();
}

fn separateActiveSessions() void {
    const display_index = activeDisplayIndex() orelse return NSBeep();
    switch (app.display_items.items[display_index]) {
        .single => return NSBeep(),
        .pair => {},
    }
    const active_id = activeSession().id;
    app.client.separateSessions(active_id) catch return NSBeep();
    app.display_registry_dirty.store(true, .release);
    syncDisplayRegistry();
    _ = selectSessionId(active_id);
    activateSelectedSession();
}

fn closeSession(index: usize) void {
    if (index >= app.sessions.sessions.items.len) return;
    const selected = app.sessions.sessions.items[index];
    if (!confirmCloseSession(selected)) return;
    app.client.closeSession(selected.id) catch {
        NSBeep();
        return;
    };
    if (app.sessions.sessions.items.len == 1) {
        objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
            app.window,
            objc.sel("performClose:"),
            null,
        );
        return;
    }

    const old_display_index = display_model.itemIndex(app.display_items.items, selected.id) orelse 0;
    var survivor_id: ?u64 = null;
    if (old_display_index < app.display_items.items.len) switch (app.display_items.items[old_display_index]) {
        .single => {},
        .pair => |pair| survivor_id = if (pair.left == selected.id) pair.right else pair.left,
    };
    app.display_registry_dirty.store(true, .release);
    syncDisplayRegistry();
    if (survivor_id) |id| {
        _ = selectSessionId(id);
    } else if (app.display_items.items.len > 0) {
        const next_index = @min(old_display_index, app.display_items.items.len - 1);
        _ = selectSessionId(display_model.focusedId(app.display_items.items[next_index]));
    }
    app.hovered_session_index = null;
    activateSelectedSession();
}

fn confirmCloseSession(session: *daemon_client.Session) bool {
    if (session.exited.load(.acquire)) return true;
    const has_foreground_job = app.client.hasForegroundJob(session.id) catch {
        NSBeep();
        return false;
    };
    if (!has_foreground_job) return true;

    return runDestructiveConfirmation(
        "Close this session?",
        "A foreground process is still running. Closing the session will terminate it.",
        "Close Session",
    );
}

fn runDestructiveConfirmation(
    message: []const u8,
    informative: []const u8,
    destructive_action: []const u8,
) bool {
    const alert = objc.allocInit(objc.cls("NSAlert"));
    if (alert == null) return false;
    defer objc.release(alert);
    const ns_message = objc.nsStringFromBytes(message);
    defer objc.release(ns_message);
    const ns_informative = objc.nsStringFromBytes(informative);
    defer objc.release(ns_informative);
    const ns_action = objc.nsStringFromBytes(destructive_action);
    defer objc.release(ns_action);
    objc.setId(alert, objc.sel("setMessageText:"), ns_message);
    objc.setId(alert, objc.sel("setInformativeText:"), ns_informative);
    objc.setU(alert, objc.sel("setAlertStyle:"), 0); // NSAlertStyleWarning
    _ = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        alert,
        objc.sel("addButtonWithTitle:"),
        objc.nsString("Cancel"),
    );
    _ = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        alert,
        objc.sel("addButtonWithTitle:"),
        ns_action,
    );
    const response = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(
        alert,
        objc.sel("runModal"),
    );
    return response == 1001; // NSAlertSecondButtonReturn; Cancel is default.
}

fn recoverUpgradeRequiredDaemon(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) bool {
    const info = daemon_client.inspectUpgradeRequiredDaemon(gpa, io, env) catch {
        NSBeep();
        return false;
    };
    const running = info.identity.versionText() orelse "another version";
    const informative = std.fmt.allocPrint(
        gpa,
        "The background service is Boring Terminal {s}, which this app cannot attach to. " ++
            "Its {d} session{s} will remain open if you quit.",
        .{
            running,
            info.identity.reported_sessions,
            if (info.identity.reported_sessions == 1) "" else "s",
        },
    ) catch return false;
    defer gpa.free(informative);
    const alert = objc.allocInit(objc.cls("NSAlert"));
    if (alert == null) return false;
    defer objc.release(alert);
    const ns_informative = objc.nsStringFromBytes(informative);
    defer objc.release(ns_informative);
    objc.setId(alert, objc.sel("setMessageText:"), objc.nsString("Boring Terminal update required"));
    objc.setId(alert, objc.sel("setInformativeText:"), ns_informative);
    objc.setU(alert, objc.sel("setAlertStyle:"), 0);
    _ = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        alert,
        objc.sel("addButtonWithTitle:"),
        objc.nsString("Quit"),
    );
    _ = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        alert,
        objc.sel("addButtonWithTitle:"),
        objc.nsString("Restart Background Service…"),
    );
    const response = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(
        alert,
        objc.sel("runModal"),
    );
    if (response != 1001) return false;
    if (info.identity.reported_sessions != 0) {
        const warning = std.fmt.allocPrint(
            gpa,
            "Restarting will terminate {d} session{s}. This cannot be undone.",
            .{
                info.identity.reported_sessions,
                if (info.identity.reported_sessions == 1) "" else "s",
            },
        ) catch return false;
        defer gpa.free(warning);
        if (!runDestructiveConfirmation(
            "Close these sessions and continue?",
            warning,
            "Restart Background Service",
        )) return false;
    }
    daemon_client.terminateUpgradeRequiredDaemon(gpa, io, env) catch {
        NSBeep();
        return false;
    };
    return true;
}

fn clearActiveSession() void {
    resetSelectionGesture();
    const session = activeSession();
    app.client.clearScrollback(session.id) catch {
        NSBeep();
        return;
    };

    // Alacritty's macOS binding pairs ClearHistory with ^L for the same
    // reason: storage is terminal-owned, while mutable-screen repaint must
    // remain synchronized with the foreground application.
    if (!session.exited.load(.acquire)) app.client.writeInput(session.id, "\x0c") catch NSBeep();
    session.grid_dirty.store(true, .release);
    renderNow();
}

fn activateSelectedSession() void {
    if (app.search_visible and app.search_session_id != activeSession().id)
        closeSearch(false);
    clearHyperlinkHover();
    resetSelectionGesture();
    stopSyncOutputTimer();
    app.preedit.clear();
    const session = activeSession();
    app.active_session_addr.store(@intFromPtr(session), .release);
    updateSessionVisibility();
    updateSessionFocus();
    // The renderer's held frame belongs to the previously active session.
    // A switch is therefore a presentation boundary just like a resize.
    app.client.forceEndSynchronizedOutput(session.id) catch NSBeep();
    session.grid_dirty.store(true, .release);
    session.requestTitleRefresh();
    syncSizes();
    // Session selection is a user-visible state transition, not background
    // damage to coalesce. Present it before returning from the menu/click.
    renderNow();
    revealActiveSession();
}

fn updateSessionFocus() void {
    const selected = activeSession();
    if (app.client.isDisconnected()) return;
    app.client.setFocus(selected.id, app.window_is_key) catch {
        NSBeep();
        return;
    };
    if (app.window_is_key) selected.attention_pending.store(false, .release);
}

/// Called by the daemon event reader. Ordinary background output stays
/// GPU-idle; metadata and bells still refresh the switchboard surfaces.
fn daemonSessionChanged(_: ?*anyopaque, id: u64, flags: daemon_protocol.EventFlags) void {
    if (flags.registry) app.display_registry_dirty.store(true, .release);
    if (id == 0) {
        app.sessions_mutex.lockUncancelable(app.io);
        for (app.sessions.sessions.items) |session| session.applyEvent(flags);
        app.sessions_mutex.unlock(app.io);
        scheduleRender();
        return;
    }
    app.sessions_mutex.lockUncancelable(app.io);
    defer app.sessions_mutex.unlock(app.io);
    for (app.sessions.sessions.items) |session| {
        if (session.id != id) continue;
        session.applyEvent(flags);
        const needs_refresh = flags.metadata or flags.lifecycle or
            (flags.grid and session.visible.load(.acquire));
        if (needs_refresh) session.requestRefresh();
        if (flags.bell) scheduleRender();
        return;
    }
}

fn sessionRefreshCompleted(_: ?*anyopaque, _: u64) void {
    scheduleRender();
}

fn prepareSessionImage(
    context: ?*anyopaque,
    image: *const daemon_protocol.Image,
) anyerror!objc.Id {
    const renderer: *renderer_mod.Renderer = @ptrCast(@alignCast(context.?));
    return renderer.prepareImageTexture(image.width, image.height, image.rgba);
}

fn prepareStagedSessionImage(
    context: ?*anyopaque,
    image: *const daemon_client.StagedFetch,
) anyerror!*daemon_client.StagedUpload {
    const renderer: *renderer_mod.Renderer = @ptrCast(@alignCast(context.?));
    return renderer.prepareSharedImageUpload(
        image.session_id,
        image.metadata.id,
        image.metadata.generation,
        image.metadata.width,
        image.metadata.height,
        image.mapping,
        image.mapping_length,
        image.metadata.bytes_per_row,
        image.staging_key,
        image.release_context,
        image.release_fn,
    );
}

fn refreshWorkerOptions() daemon_client.RefreshWorkerOptions {
    return .{
        .callback = sessionRefreshCompleted,
        .image_context = &app.renderer,
        .prepare_image = prepareSessionImage,
        .prepare_staged_image = prepareStagedSessionImage,
    };
}

fn updateSessionVisibility() void {
    const display_index = activeDisplayIndex();
    for (app.sessions.sessions.items) |session| {
        const visible = if (display_index) |index| switch (app.display_items.items[index]) {
            .single => |id| id == session.id,
            .pair => |pair| if (pair.zoomed)
                pair.focusedId() == session.id
            else
                pair.left == session.id or pair.right == session.id,
        } else false;
        session.setVisible(visible);
    }
}

fn syncDisplayRegistry() void {
    if (!app.display_registry_dirty.swap(false, .acq_rel)) return;
    var registry = app.client.listRegistry() catch {
        app.display_registry_dirty.store(true, .release);
        return;
    };
    defer registry.deinit(app.gpa);

    app.sessions_mutex.lockUncancelable(app.io);
    for (registry.sessions) |metadata| {
        var found = false;
        for (app.sessions.sessions.items) |session| {
            if (session.id == metadata.id) {
                found = true;
                break;
            }
        }
        if (found) continue;
        const session = daemon_client.Session.create(app.gpa, app.io, &app.client, metadata) catch {
            app.sessions_mutex.unlock(app.io);
            app.display_registry_dirty.store(true, .release);
            return;
        };
        session.startRefreshWorker(refreshWorkerOptions()) catch {
            session.destroy();
            app.sessions_mutex.unlock(app.io);
            app.display_registry_dirty.store(true, .release);
            return;
        };
        _ = app.sessions.append(session) catch {
            session.destroy();
            app.sessions_mutex.unlock(app.io);
            app.display_registry_dirty.store(true, .release);
            return;
        };
    }
    var index = app.sessions.sessions.items.len;
    while (index > 0) {
        index -= 1;
        const session = app.sessions.sessions.items[index];
        var retained = false;
        for (registry.sessions) |metadata| {
            if (metadata.id == session.id) {
                retained = true;
                break;
            }
        }
        if (retained) continue;
        const removed = app.sessions.remove(index).?;
        removed.destroy();
    }
    app.sessions_mutex.unlock(app.io);

    app.display_items.clearRetainingCapacity();
    app.display_items.appendSlice(app.gpa, registry.display_items) catch {
        app.display_registry_dirty.store(true, .release);
        return;
    };
    if (app.display_items.items.len == 0) return;
    if (display_model.itemIndex(app.display_items.items, activeSession().id) == null) {
        _ = selectSessionId(display_model.focusedId(app.display_items.items[0]));
        app.active_session_addr.store(@intFromPtr(activeSession()), .release);
    }
    updateSessionVisibility();
}

/// Runs on the vnode watcher thread. Coalescing here keeps filesystem bursts
/// off AppKit while ensuring all renderer publication happens on the main
/// queue.
fn configDirectoryChanged(_: ?*anyopaque) void {
    if (app.config_reload_queued.swap(true, .acq_rel)) return;
    dispatch_async_f(dispatch_main_q, null, configReloadTick);
}

fn configReloadTick(_: ?*anyopaque) callconv(.c) void {
    app.config_reload_queued.store(false, .release);
    reloadConfig();
}

fn reloadConfig() void {
    var candidate = config_mod.loadPath(app.gpa, app.io, app.config_path) catch |err| {
        std.log.err("keeping current config; reload rejected: {s}", .{@errorName(err)});
        return;
    };
    var candidate_owned = true;
    defer if (candidate_owned) candidate.deinit(app.gpa);
    if (config_mod.Config.eql(app.config, candidate)) return;

    const size_changed = candidate.font_size != app.config.font_size;
    const effective_size = if (size_changed)
        candidate.font_size
    else
        app.font_zoom.effective(candidate.font_size);
    app.renderer.reconfigureFont(.{
        .family = candidate.font_family,
        .size = effective_size,
    }, app.scale) catch |err| {
        std.log.err("keeping current font; reload rejected: {s}", .{@errorName(err)});
        return;
    };

    var previous = app.config;
    app.config = candidate;
    if (size_changed) app.font_zoom.reset();
    candidate_owned = false;
    previous.deinit(app.gpa);

    // Cell metrics are renderer state: update both native constraints and
    // every daemon-owned grid before presenting the new atlas.
    layoutSessionBar();
    syncSizes();
    scheduleRender();
}

fn effectiveFontSize() f32 {
    return app.font_zoom.effective(app.config.font_size);
}

fn setTemporaryFontSize(size: ?f32) void {
    const target = std.math.clamp(
        size orelse app.config.font_size,
        config_mod.min_font_size,
        config_mod.max_font_size,
    );
    if (target == effectiveFontSize() and ((size == null) == (!app.font_zoom.isOverridden()))) return;
    app.renderer.reconfigureFont(.{
        .family = app.config.font_family,
        .size = target,
    }, app.scale) catch {
        NSBeep();
        return;
    };
    app.font_zoom.set(app.config.font_size, target);
    layoutSessionBar();
    syncSizes();
    scheduleRender();
}

fn adjustTemporaryFontSize(delta: f32) void {
    const target = app.font_zoom.adjusted(app.config.font_size, delta) orelse return NSBeep();
    setTemporaryFontSize(target);
}

fn userDefaults() objc.Id {
    return objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSUserDefaults"),
        objc.sel("standardUserDefaults"),
    );
}

fn loadSessionBarPreferences() void {
    const defaults = userDefaults();
    const visible_key = objc.nsString("BoringTerminalSessionBarVisible");
    const width_key = objc.nsString("BoringTerminalSessionBarWidth");

    const stored_visible = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        defaults,
        objc.sel("objectForKey:"),
        visible_key,
    );
    if (stored_visible != null) {
        app.session_bar_visible = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.BOOL)(
            defaults,
            objc.sel("boolForKey:"),
            visible_key,
        ) != 0;
    }

    const stored_width = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        defaults,
        objc.sel("objectForKey:"),
        width_key,
    );
    if (stored_width != null) {
        const width = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) f64)(
            defaults,
            objc.sel("doubleForKey:"),
            width_key,
        );
        app.sidebar_preferred_width = sidebar_layout.preferredWidth(@floatCast(width));
    }
}

fn saveSessionBarPreferences() void {
    const defaults = userDefaults();
    objc.msg(*const fn (objc.Id, objc.Sel, objc.BOOL, objc.Id) callconv(.c) void)(
        defaults,
        objc.sel("setBool:forKey:"),
        @intFromBool(app.session_bar_visible),
        objc.nsString("BoringTerminalSessionBarVisible"),
    );
    objc.msg(*const fn (objc.Id, objc.Sel, f64, objc.Id) callconv(.c) void)(
        defaults,
        objc.sel("setDouble:forKey:"),
        app.sidebar_preferred_width,
        objc.nsString("BoringTerminalSessionBarWidth"),
    );
}

fn scheduleRender() void {
    if (app.terminating.load(.acquire)) return;
    if (app.render_pending.swap(true, .acq_rel)) return;
    if (app.display_link == null and !app.display_tick_queued.swap(true, .acq_rel)) {
        dispatch_async_f(dispatch_main_q, null, renderTick);
    }
}

fn rendererFrameCompleted(context: ?*anyopaque) callconv(.c) void {
    const application: *App = @ptrCast(@alignCast(context.?));
    if (application.frame_completion_queued.swap(true, .acq_rel)) return;
    dispatch_async_f(dispatch_main_q, application, rendererFrameCompletionTick);
}

fn rendererFrameCompletionTick(context: ?*anyopaque) callconv(.c) void {
    const application: *App = @ptrCast(@alignCast(context.?));
    application.frame_completion_queued.store(false, .release);
    // Orderly termination drains the frame ring synchronously before tearing
    // down sessions and the daemon client. A previously queued main hop must
    // not revisit those owners afterward.
    if (application.terminating.load(.acquire)) return;
    if (!application.renderer.reclaimCompletedFrames()) return;
    for (application.sessions.sessions.items) |session| {
        if (!session.discardFailedStagedImages()) continue;
        session.grid_dirty.store(true, .release);
        session.requestRefresh();
    }
}

fn renderTick(_: ?*anyopaque) callconv(.c) void {
    app.display_tick_queued.store(false, .release);
    if (app.terminating.load(.acquire)) {
        app.render_pending.store(false, .release);
        return;
    }
    if (!app.render_pending.load(.acquire)) return;
    renderNow();
}

fn displayLinkTick(
    _: CVDisplayLinkRef,
    _: *const anyopaque,
    _: *const anyopaque,
    _: CVOptionFlags,
    _: *CVOptionFlags,
    _: ?*anyopaque,
) callconv(.c) CVReturn {
    if (app.terminating.load(.acquire)) return 0;
    if (!app.render_pending.load(.acquire)) return 0;
    if (app.display_tick_queued.swap(true, .acq_rel)) return 0;
    dispatch_async_f(dispatch_main_q, null, renderTick);
    return 0;
}

fn startDisplayLink() !void {
    var link: CVDisplayLinkRef = null;
    if (CVDisplayLinkCreateWithActiveCGDisplays(&link) != 0 or link == null) {
        return error.DisplayLinkCreate;
    }
    errdefer CFRelease(link);
    if (CVDisplayLinkSetOutputCallback(link, displayLinkTick, null) != 0) {
        return error.DisplayLinkCallback;
    }
    if (CVDisplayLinkStart(link) != 0) return error.DisplayLinkStart;
    app.display_link = link;
}

fn stopDisplayLink() void {
    const link = app.display_link orelse return;
    _ = CVDisplayLinkStop(link);
    CFRelease(link);
    app.display_link = null;
}

const sync_output_timeout: objc.CGFloat = 1.0;

fn stopSyncOutputTimer() void {
    if (app.sync_output_timer) |timer| {
        objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(timer, objc.sel("invalidate"));
        app.sync_output_timer = null;
    }
    app.sync_output_timer_session = null;
}

fn armSyncOutputTimer(session: *daemon_client.Session, epoch: u64) void {
    if (app.sync_output_timer != null and
        app.sync_output_timer_session == session and
        app.sync_output_timer_epoch == epoch) return;
    stopSyncOutputTimer();
    app.sync_output_timer_epoch = epoch;
    app.sync_output_timer_session = session;

    const timer = objc.msg(
        *const fn (objc.Class, objc.Sel, objc.CGFloat, objc.Id, objc.Sel, objc.Id, objc.BOOL) callconv(.c) objc.Id,
    )(
        objc.cls("NSTimer"),
        objc.sel("timerWithTimeInterval:target:selector:userInfo:repeats:"),
        sync_output_timeout,
        app.view,
        objc.sel("syncOutputTimeout:"),
        null,
        0,
    );
    if (timer == null) return;
    app.sync_output_timer = timer;
    const run_loop = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSRunLoop"),
        objc.sel("mainRunLoop"),
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id, objc.Id) callconv(.c) void)(
        run_loop,
        objc.sel("addTimer:forMode:"),
        timer,
        ns_run_loop_common_modes.*,
    );
}

fn syncOutputTimeout(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    app.sync_output_timer = null; // one-shot timer has fired
    const session = app.sync_output_timer_session orelse return;
    app.sync_output_timer_session = null;
    app.client.forceEndSynchronizedOutput(session.id) catch NSBeep();
    session.grid_dirty.store(true, .release);
    scheduleRender();
}

fn requestDirtySessionRefreshes() void {
    updateSessionVisibility();
    for (app.sessions.sessions.items) |session| {
        const needs_snapshot = session.metadata_dirty.load(.acquire) or
            (session.visible.load(.acquire) and session.grid_dirty.load(.acquire));
        if (!needs_snapshot) continue;
        session.requestRefresh();
    }
}

/// Main thread only.
fn renderNow() void {
    if (app.terminating.load(.acquire)) return;
    app.render_pending.store(false, .release);

    syncDisplayRegistry();
    requestDirtySessionRefreshes();
    refreshSidebar();
    updateSearchCount();
    applyTrackedPointerShape();

    var should_beep = false;
    for (app.sessions.sessions.items) |session| {
        if (session.bell_pending.swap(false, .acq_rel)) should_beep = true;
    }
    if (should_beep) NSBeep();

    const session = activeSession();
    var title_buf: [512]u8 = undefined;
    const title_update = if (app.client.isDisconnected())
        "Boring Terminal — Disconnected"
    else
        session.copyTitle(&title_buf, true);
    if (title_update) |title| {
        var ellipsis_buf: [title_buf.len + 3]u8 = undefined;
        const shown = title_mod.middleEllipsize(
            title,
            &ellipsis_buf,
            title_mod.default_max_codepoints,
        );
        const ns_title = objc.nsStringFromBytes(shown);
        if (ns_title != null) {
            objc.setId(app.window, objc.sel("setTitle:"), ns_title);
            objc.release(ns_title);
        }
    }

    const display_index = activeDisplayIndex() orelse return;
    const item = app.display_items.items[display_index];
    app.renderer.beginFrame();
    switch (item) {
        .single => |id| {
            const visible = sessionById(id) orelse return;
            const result = appendRendererPane(visible, .{
                .origin = .{ 0, 0 },
                .size = app.view_size,
            }, true) catch return;
            if (result) |epoch| {
                armSyncOutputTimer(visible, epoch);
                return;
            }
        },
        .pair => |pair| {
            if (zoomedPairMember(pair)) |zoomed_id| {
                const visible = sessionById(zoomed_id) orelse return;
                const result = appendRendererPane(visible, .{
                    .origin = .{ 0, 0 },
                    .size = app.view_size,
                }, true) catch return;
                if (result) |epoch| {
                    armSyncOutputTimer(visible, epoch);
                    return;
                }
            } else {
                const geometry = activePairGeometry(pair) orelse return;
                const left = sessionById(pair.left) orelse return;
                const right = sessionById(pair.right) orelse return;
                const left_result = appendRendererPane(left, .{
                    .origin = .{ geometry.left_origin, 0 },
                    .size = .{ geometry.left_width, geometry.height },
                }, pair.left == session.id) catch return;
                if (left_result) |epoch| {
                    armSyncOutputTimer(left, epoch);
                    return;
                }
                const right_result = appendRendererPane(right, .{
                    .origin = .{ geometry.right_origin, 0 },
                    .size = .{ geometry.right_width, geometry.height },
                }, pair.right == session.id) catch return;
                if (right_result) |epoch| {
                    armSyncOutputTimer(right, epoch);
                    return;
                }
            }
        },
    }
    app.renderer.finishFrame();
    stopSyncOutputTimer();
    switch (app.renderer.present(app.layer, app.view_size, app.in_live_resize)) {
        .submitted => {},
        .no_frame_slot => scheduleRender(),
        .no_drawable, .encoding_failed => {},
    }
}

fn appendRendererPane(
    session: *daemon_client.Session,
    rect: renderer_mod.PaneRect,
    focused: bool,
) !?u64 {
    session.mutex.lockUncancelable(session.io);
    defer session.mutex.unlock(session.io);
    const snapshot = if (session.render_snapshot) |*value| value else return error.MissingSnapshot;
    const geometry_ready = display_model.geometryReady(
        snapshot.cols,
        snapshot.rows,
        session.requested_cols,
        session.requested_rows,
        session.render_snapshot_geometry_generation,
        session.geometry_generation.load(.acquire),
    );
    if (geometry_ready and snapshot.modes.synchronized_output) return snapshot.sync_output_epoch;
    const graphics = .{
        .session_id = session.id,
        .images = session.graphics_images.items,
        .placements = snapshot.placements,
    };
    var hovered_hyperlink_id: u32 = 0;
    if (geometry_ready and app.hyperlink_command_held and
        app.hovered_hyperlink_session == session.id and
        app.hovered_hyperlink_cell.row < snapshot.rows and
        app.hovered_hyperlink_cell.col < snapshot.cols)
    {
        hovered_hyperlink_id = snapshot.viewCellAt(
            app.hovered_hyperlink_cell.row,
            app.hovered_hyperlink_cell.col,
        ).hyperlink_id;
        app.hovered_hyperlink_id = hovered_hyperlink_id;
        if (hovered_hyperlink_id == 0) {
            app.hovered_hyperlink_session = null;
            setHyperlinkPointer(false);
        }
    }
    const preedit: ?renderer_mod.Preedit = if (geometry_ready and focused and app.preedit.active()) .{
        .utf8 = app.preedit.text(),
        .caret_utf8 = app.preedit.selected_utf8,
    } else null;
    try app.renderer.appendPaneWithGraphics(
        snapshot,
        geometry_ready and focused and !session.exited.load(.acquire) and preedit == null,
        hovered_hyperlink_id,
        graphics,
        preedit,
        rect,
    );
    return null;
}

fn activePairGeometry(pair: display_registry.Pair) ?display_model.PairGeometry {
    const metrics = app.renderer.cellMetrics();
    return display_model.pairGeometry(
        app.view_size[0],
        app.view_size[1],
        pair.ratio,
        metrics.cell_width,
        metrics.cell_height,
    );
}

// -- window & view ----------------------------------------------------------

fn setViewFrame(view: objc.Id, frame: objc.CGRect) void {
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect) callconv(.c) void)(
        view,
        objc.sel("setFrame:"),
        frame,
    );
}

fn invalidateCursorRects(view: objc.Id) void {
    if (app.window == null or view == null) return;
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        app.window,
        objc.sel("invalidateCursorRectsForView:"),
        view,
    );
}

fn layoutSearchOverlay() void {
    if (app.search_bar.overlay == null or app.view == null) return;
    const view_frame = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGRect)(
        app.view,
        objc.sel("frame"),
    );
    var pane_x: f32 = 0;
    var pane_width: f32 = @floatCast(view_frame.size.width);
    if (activeDisplayIndex()) |index| switch (app.display_items.items[index]) {
        .single => {},
        .pair => |pair| if (activePairGeometry(pair)) |geometry| {
            if (zoomedPairMember(pair) != null) {
                pane_x = 0;
                pane_width = @floatCast(view_frame.size.width);
            } else if (activeSession().id == pair.right) {
                pane_x = geometry.right_origin;
                pane_width = geometry.right_width;
            } else {
                pane_width = geometry.left_width;
            }
        },
    };
    app.search_bar.layout(.{
        .origin = .{ .x = view_frame.origin.x + pane_x, .y = view_frame.origin.y },
        .size = .{ .width = pane_width, .height = view_frame.size.height },
    });
}

fn layoutSessionBar() void {
    if (app.root_view == null or app.sidebar == null or app.sidebar_scroll == null or
        app.sidebar_divider == null or app.view == null) return;
    const bounds = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGRect)(
        app.root_view,
        objc.sel("bounds"),
    );
    const width: f32 = @floatCast(bounds.size.width);
    const height: f32 = @floatCast(bounds.size.height);
    const metrics = app.renderer.cellMetrics();
    const paired = if (activeDisplayIndex()) |index| switch (app.display_items.items[index]) {
        .single => false,
        .pair => true,
    } else false;
    const terminal_min_width = metrics.cell_width *
        @as(f32, @floatFromInt(if (paired) display_model.min_pane_cols * 2 else 20)) +
        (if (paired) display_model.pair_divider_width else 0);
    const rail_width = if (app.session_bar_visible)
        sidebar_layout.effectiveWidth(app.sidebar_preferred_width, width, terminal_min_width)
    else
        0;
    app.sidebar_effective_width = rail_width;

    objc.setU(app.sidebar, objc.sel("setHidden:"), @intFromBool(!app.session_bar_visible));
    objc.setU(app.sidebar_divider, objc.sel("setHidden:"), @intFromBool(!app.session_bar_visible));
    invalidateCursorRects(app.sidebar_divider);
    if (!app.session_bar_visible) {
        setViewFrame(app.view, .{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = width, .height = height },
        });
        objc.setU(app.view, objc.sel("setAutoresizingMask:"), 2 | 16);
    } else {
        setViewFrame(app.sidebar, .{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = rail_width, .height = height },
        });
        objc.setU(app.sidebar, objc.sel("setAutoresizingMask:"), 16);
        setViewFrame(app.sidebar_scroll, .{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = rail_width, .height = height },
        });
        objc.setU(app.sidebar_scroll, objc.sel("setAutoresizingMask:"), 2 | 16);
        setViewFrame(app.sidebar_divider, .{
            .origin = .{
                .x = rail_width - sidebar_layout.divider_hit_width / 2,
                .y = 0,
            },
            .size = .{ .width = sidebar_layout.divider_hit_width, .height = height },
        });
        invalidateCursorRects(app.sidebar_divider);
        if (app.sidebar_divider_line != null) {
            const hairline = 1.0 / @max(app.scale, 1);
            objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect) callconv(.c) void)(
                app.sidebar_divider_line,
                objc.sel("setFrame:"),
                .{
                    .origin = .{
                        .x = (sidebar_layout.divider_hit_width - hairline) / 2,
                        .y = 0,
                    },
                    .size = .{ .width = hairline, .height = height },
                },
            );
        }
        setViewFrame(app.view, .{
            .origin = .{ .x = rail_width, .y = 0 },
            .size = .{ .width = @max(1, width - rail_width), .height = height },
        });
        objc.setU(app.view, objc.sel("setAutoresizingMask:"), 2 | 16);
    }

    layoutPairDivider();
    layoutSearchOverlay();

    const extra_width: f32 = if (app.session_bar_visible) sidebar_layout.min_width else 0;
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGSize) callconv(.c) void)(
        app.window,
        objc.sel("setContentMinSize:"),
        .{
            .width = extra_width + terminal_min_width,
            .height = metrics.cell_height * 4,
        },
    );
    refreshSidebar();
    revealActiveSession();
}

fn toggleSessionBar() void {
    app.session_bar_visible = !app.session_bar_visible;
    saveSessionBarPreferences();
    layoutSessionBar();
    syncSizes();
    scheduleRender();
}

fn layoutPairDivider() void {
    if (app.pair_divider == null or app.view == null) return;
    const display_index = activeDisplayIndex() orelse {
        objc.setU(app.pair_divider, objc.sel("setHidden:"), 1);
        invalidateCursorRects(app.pair_divider);
        return;
    };
    const pair = switch (app.display_items.items[display_index]) {
        .single => {
            objc.setU(app.pair_divider, objc.sel("setHidden:"), 1);
            invalidateCursorRects(app.pair_divider);
            return;
        },
        .pair => |value| value,
    };
    if (zoomedPairMember(pair) != null) {
        objc.setU(app.pair_divider, objc.sel("setHidden:"), 1);
        invalidateCursorRects(app.pair_divider);
        return;
    }
    const bounds = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGRect)(
        app.view,
        objc.sel("bounds"),
    );
    const metrics = app.renderer.cellMetrics();
    const geometry = display_model.pairGeometry(
        @floatCast(bounds.size.width),
        @floatCast(bounds.size.height),
        pair.ratio,
        metrics.cell_width,
        metrics.cell_height,
    ) orelse {
        objc.setU(app.pair_divider, objc.sel("setHidden:"), 1);
        invalidateCursorRects(app.pair_divider);
        return;
    };
    const view_frame = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGRect)(
        app.view,
        objc.sel("frame"),
    );
    setViewFrame(app.pair_divider, .{
        .origin = .{
            .x = view_frame.origin.x + geometry.right_origin - display_model.pair_divider_hit_width / 2,
            .y = view_frame.origin.y,
        },
        .size = .{
            .width = display_model.pair_divider_hit_width,
            .height = view_frame.size.height,
        },
    });
    invalidateCursorRects(app.pair_divider);
    if (app.pair_divider_line != null) {
        const hairline = 1.0 / @max(app.scale, 1);
        setViewFrame(app.pair_divider_line, .{
            .origin = .{
                .x = (display_model.pair_divider_hit_width - hairline) / 2,
                .y = 0,
            },
            .size = .{ .width = hairline, .height = @floatCast(view_frame.size.height) },
        });
    }
    objc.setU(app.pair_divider, objc.sel("setHidden:"), 0);
}

fn setActivePairRatio(ratio: u16) ?u64 {
    const index = activeDisplayIndex() orelse return null;
    switch (app.display_items.items[index]) {
        .single => return null,
        .pair => |*pair| {
            pair.ratio = ratio;
            return pair.focusedId();
        },
    }
}

fn configureSessionShortcut(shortcut: objc.Id, visual_index: usize) void {
    objc.setU(shortcut, objc.sel("setTag:"), visual_index + 1);
    var label_buf: [8]u8 = undefined;
    const label = sidebar_layout.shortcutLabel(visual_index, &label_buf);
    const ns_label = objc.nsStringFromBytes(label);
    defer objc.release(ns_label);
    objc.setId(shortcut, objc.sel("setTitle:"), ns_label);
    objc.setU(
        shortcut,
        objc.sel("setHidden:"),
        @intFromBool(!app.show_session_shortcuts or visual_index >= 9),
    );
}

fn refreshSidebar() void {
    if (app.sidebar_document == null or app.sidebar_scroll == null or app.view == null) return;

    const row_count = app.display_items.items.len;
    app.session_buttons.ensureTotalCapacity(app.gpa, row_count) catch return;
    app.session_shortcut_buttons.ensureTotalCapacity(app.gpa, row_count) catch return;
    app.session_close_buttons.ensureTotalCapacity(app.gpa, row_count) catch return;
    app.session_attention_layers.ensureTotalCapacity(app.gpa, row_count) catch return;
    app.pair_left_buttons.ensureTotalCapacity(app.gpa, row_count) catch return;
    app.pair_right_buttons.ensureTotalCapacity(app.gpa, row_count) catch return;
    app.pair_left_shortcut_buttons.ensureTotalCapacity(app.gpa, row_count) catch return;
    app.pair_right_shortcut_buttons.ensureTotalCapacity(app.gpa, row_count) catch return;
    app.pair_left_attention_layers.ensureTotalCapacity(app.gpa, row_count) catch return;
    app.pair_right_attention_layers.ensureTotalCapacity(app.gpa, row_count) catch return;
    app.pair_left_close_buttons.ensureTotalCapacity(app.gpa, row_count) catch return;
    app.pair_right_close_buttons.ensureTotalCapacity(app.gpa, row_count) catch return;
    app.pair_separator_layers.ensureTotalCapacity(app.gpa, row_count) catch return;
    app.session_context_menus.ensureTotalCapacity(app.gpa, row_count) catch return;
    app.session_context_items.ensureTotalCapacity(app.gpa, row_count) catch return;
    app.session_context_swap_items.ensureTotalCapacity(app.gpa, row_count) catch return;
    app.session_context_zoom_items.ensureTotalCapacity(app.gpa, row_count) catch return;

    while (app.session_buttons.items.len < row_count) {
        const index = app.session_buttons.items.len;
        const row = createSessionButton(index) orelse break;
        app.session_buttons.appendAssumeCapacity(row.button);
        app.session_shortcut_buttons.appendAssumeCapacity(row.shortcut);
        app.session_close_buttons.appendAssumeCapacity(row.close);
        app.session_attention_layers.appendAssumeCapacity(row.attention);
        app.pair_left_buttons.appendAssumeCapacity(row.pair_left);
        app.pair_right_buttons.appendAssumeCapacity(row.pair_right);
        app.pair_left_shortcut_buttons.appendAssumeCapacity(row.pair_left_shortcut);
        app.pair_right_shortcut_buttons.appendAssumeCapacity(row.pair_right_shortcut);
        app.pair_left_attention_layers.appendAssumeCapacity(row.pair_left_attention);
        app.pair_right_attention_layers.appendAssumeCapacity(row.pair_right_attention);
        app.pair_left_close_buttons.appendAssumeCapacity(row.pair_left_close);
        app.pair_right_close_buttons.appendAssumeCapacity(row.pair_right_close);
        app.pair_separator_layers.appendAssumeCapacity(row.pair_separator);
        app.session_context_menus.appendAssumeCapacity(row.context_menu);
        app.session_context_items.appendAssumeCapacity(row.context_item);
        app.session_context_swap_items.appendAssumeCapacity(row.context_swap_item);
        app.session_context_zoom_items.appendAssumeCapacity(row.context_zoom_item);
    }

    while (app.session_buttons.items.len > app.display_items.items.len) removeLastSidebarRow();

    resizeSidebarDocument();
    const bounds = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGRect)(
        app.sidebar_document,
        objc.sel("bounds"),
    );
    const active_id = activeSession().id;
    const active_index = activeDisplayIndex() orelse 0;
    var visual_index: usize = 0;
    for (app.display_items.items, 0..) |item, index| {
        if (index >= app.session_buttons.items.len or
            index >= app.session_shortcut_buttons.items.len or
            index >= app.session_close_buttons.items.len or
            index >= app.session_attention_layers.items.len) break;
        const button = app.session_buttons.items[index];
        const shortcut = app.session_shortcut_buttons.items[index];
        const close = app.session_close_buttons.items[index];
        const attention = app.session_attention_layers.items[index];
        const pair_left = app.pair_left_buttons.items[index];
        const pair_right = app.pair_right_buttons.items[index];
        const pair_left_shortcut = app.pair_left_shortcut_buttons.items[index];
        const pair_right_shortcut = app.pair_right_shortcut_buttons.items[index];
        const pair_left_attention = app.pair_left_attention_layers.items[index];
        const pair_right_attention = app.pair_right_attention_layers.items[index];
        const pair_left_close = app.pair_left_close_buttons.items[index];
        const pair_right_close = app.pair_right_close_buttons.items[index];
        const pair_separator = app.pair_separator_layers.items[index];
        const context_menu = app.session_context_menus.items[index];
        const context_item = app.session_context_items.items[index];
        const context_swap_item = app.session_context_swap_items.items[index];
        const context_zoom_item = app.session_context_zoom_items.items[index];
        objc.setU(button, objc.sel("setTag:"), index + 1);
        objc.setU(close, objc.sel("setTag:"), index + 1);
        objc.setU(context_item, objc.sel("setTag:"), index + 1);
        objc.setU(context_swap_item, objc.sel("setTag:"), index + 1);
        objc.setU(context_zoom_item, objc.sel("setTag:"), index + 1);

        const font = objc.msg(*const fn (objc.Class, objc.Sel, objc.CGFloat) callconv(.c) objc.Id)(
            objc.cls("NSFont"),
            objc.sel("systemFontOfSize:"),
            12.5,
        );
        objc.setId(button, objc.sel("setFont:"), font);
        objc.setId(pair_left, objc.sel("setFont:"), font);
        objc.setId(pair_right, objc.sel("setFont:"), font);
        styleSessionButton(
            button,
            index == active_index,
        );

        const row_frame: objc.CGRect = .{
            .origin = .{
                .x = sidebar_horizontal_padding,
                .y = sidebar_layout.rowY(index),
            },
            .size = .{
                .width = @max(1, @as(f32, @floatCast(bounds.size.width)) - 2 * sidebar_horizontal_padding),
                .height = sidebar_row_height,
            },
        };
        setViewFrame(button, row_frame);
        switch (item) {
            .single => |id| {
                const session = sessionById(id) orelse continue;
                configureSessionShortcut(shortcut, visual_index);
                objc.setU(pair_left_shortcut, objc.sel("setHidden:"), 1);
                objc.setU(pair_right_shortcut, objc.sel("setHidden:"), 1);
                visual_index += 1;
                setSidebarTitle(button, session);
                setCloseTooltip(close, session);
                objc.setU(pair_left, objc.sel("setHidden:"), 1);
                objc.setU(pair_right, objc.sel("setHidden:"), 1);
                styleAttentionLayer(attention, session.needsAttention() and id != active_id);
                styleAttentionLayer(pair_left_attention, false);
                styleAttentionLayer(pair_right_attention, false);
                objc.setU(pair_left_close, objc.sel("setHidden:"), 1);
                objc.setU(pair_right_close, objc.sel("setHidden:"), 1);
                objc.setU(pair_separator, objc.sel("setHidden:"), 1);
                objc.setId(button, objc.sel("setMenu:"), null);
            },
            .pair => |pair| {
                const left_session = sessionById(pair.left) orelse continue;
                const right_session = sessionById(pair.right) orelse continue;
                objc.setU(shortcut, objc.sel("setHidden:"), 1);
                configureSessionShortcut(pair_left_shortcut, visual_index);
                configureSessionShortcut(pair_right_shortcut, visual_index + 1);
                visual_index += 2;
                objc.setId(button, objc.sel("setTitle:"), objc.nsString(""));
                styleAttentionLayer(attention, false);
                const segment_width = @as(f32, @floatCast(row_frame.size.width)) / 2;
                setViewFrame(pair_left, .{
                    .origin = .{ .x = 0, .y = 0 },
                    .size = .{ .width = segment_width, .height = sidebar_row_height },
                });
                setViewFrame(pair_right, .{
                    .origin = .{ .x = segment_width, .y = 0 },
                    .size = .{ .width = segment_width, .height = sidebar_row_height },
                });
                objc.setU(pair_left, objc.sel("setTag:"), pair.left);
                objc.setU(pair_right, objc.sel("setTag:"), pair.right);
                objc.setU(pair_left_close, objc.sel("setTag:"), pair.left);
                objc.setU(pair_right_close, objc.sel("setTag:"), pair.right);
                setSidebarTitle(pair_left, left_session);
                setSidebarTitle(pair_right, right_session);
                setCloseTooltip(close, if (pair.focusedId() == pair.left) left_session else right_session);
                setCloseTooltip(pair_left_close, left_session);
                setCloseTooltip(pair_right_close, right_session);
                objc.setU(pair_left, objc.sel("setHidden:"), 0);
                objc.setU(pair_right, objc.sel("setHidden:"), 0);
                stylePairSegment(pair_left, pair.left == active_id);
                stylePairSegment(pair_right, pair.right == active_id);
                const zoomed_id = zoomedPairMember(pair);
                objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat) callconv(.c) void)(
                    pair_left,
                    objc.sel("setAlphaValue:"),
                    if (zoomed_id != null and zoomed_id.? != pair.left) 0.55 else 1,
                );
                objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat) callconv(.c) void)(
                    pair_right,
                    objc.sel("setAlphaValue:"),
                    if (zoomed_id != null and zoomed_id.? != pair.right) 0.55 else 1,
                );
                objc.setId(
                    context_zoom_item,
                    objc.sel("setTitle:"),
                    objc.nsString(if (zoomed_id != null) "Show Both Panes" else "Zoom Focused Pane"),
                );
                styleAttentionLayer(
                    pair_left_attention,
                    left_session.needsAttention() and pair.left != active_id,
                );
                styleAttentionLayer(
                    pair_right_attention,
                    right_session.needsAttention() and pair.right != active_id,
                );
                setViewFrame(pair_left_close, .{
                    .origin = .{ .x = segment_width - 19, .y = 6 },
                    .size = .{ .width = 16, .height = 16 },
                });
                setViewFrame(pair_right_close, .{
                    .origin = .{ .x = segment_width - 19, .y = 6 },
                    .size = .{ .width = 16, .height = 16 },
                });
                setViewFrame(pair_left_shortcut, .{
                    .origin = .{ .x = segment_width - 36, .y = 4 },
                    .size = .{ .width = 32, .height = 20 },
                });
                setViewFrame(pair_right_shortcut, .{
                    .origin = .{ .x = segment_width - 36, .y = 4 },
                    .size = .{ .width = 32, .height = 20 },
                });
                objc.setU(pair_left_close, objc.sel("setHidden:"), @intFromBool(
                    app.show_session_shortcuts or app.hovered_pair_member_id != pair.left,
                ));
                objc.setU(pair_right_close, objc.sel("setHidden:"), @intFromBool(
                    app.show_session_shortcuts or app.hovered_pair_member_id != pair.right,
                ));
                const hairline = 1.0 / @max(app.scale, 1);
                setViewFrame(pair_separator, .{
                    .origin = .{ .x = segment_width - hairline / 2, .y = 5 },
                    .size = .{ .width = hairline, .height = sidebar_row_height - 10 },
                });
                objc.setU(pair_separator, objc.sel("setHidden:"), 0);
                objc.setId(button, objc.sel("setMenu:"), context_menu);
            },
        }
        setViewFrame(shortcut, .{
            .origin = .{
                .x = @floatCast(row_frame.origin.x + row_frame.size.width - 36),
                .y = @floatCast(row_frame.origin.y + 4),
            },
            .size = .{ .width = 32, .height = 20 },
        });
        setViewFrame(close, .{
            .origin = .{ .x = row_frame.size.width - 22, .y = 6 },
            .size = .{ .width = 16, .height = 16 },
        });
        objc.setU(
            close,
            objc.sel("setHidden:"),
            @intFromBool(
                app.show_session_shortcuts or app.hovered_session_index != index or
                    switch (item) {
                        .single => false,
                        .pair => true,
                    },
            ),
        );
    }
    updateAttentionSurfaces();
}

fn resizeSidebarDocument() void {
    const content_size = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGSize)(
        app.sidebar_scroll,
        objc.sel("contentSize"),
    );
    const viewport_height: f32 = @floatCast(content_size.height);
    setViewFrame(app.sidebar_document, .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{
            .width = @max(1, @as(f32, @floatCast(content_size.width))),
            .height = sidebar_layout.contentHeight(viewport_height, app.display_items.items.len),
        },
    });
}

fn removeLastSidebarRow() void {
    const button = app.session_buttons.pop().?;
    const shortcut = app.session_shortcut_buttons.pop().?;
    _ = app.session_close_buttons.pop();
    _ = app.session_attention_layers.pop();
    _ = app.pair_left_buttons.pop();
    _ = app.pair_right_buttons.pop();
    _ = app.pair_left_shortcut_buttons.pop();
    _ = app.pair_right_shortcut_buttons.pop();
    _ = app.pair_left_attention_layers.pop();
    _ = app.pair_right_attention_layers.pop();
    _ = app.pair_left_close_buttons.pop();
    _ = app.pair_right_close_buttons.pop();
    _ = app.pair_separator_layers.pop();
    _ = app.session_context_menus.pop();
    _ = app.session_context_items.pop();
    _ = app.session_context_swap_items.pop();
    _ = app.session_context_zoom_items.pop();
    objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(button, objc.sel("removeFromSuperview"));
    objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(shortcut, objc.sel("removeFromSuperview"));
}

fn setSidebarTitle(button: objc.Id, session: *daemon_client.Session) void {
    var title_buf: [512]u8 = undefined;
    const title = session.copyTitleSnapshot(&title_buf);
    const ns_label = objc.nsStringFromBytes(title);
    objc.setId(button, objc.sel("setTitle:"), ns_label);
    objc.release(ns_label);
    const ns_tooltip = objc.nsStringFromBytes(title);
    objc.setId(button, objc.sel("setToolTip:"), ns_tooltip);
    objc.release(ns_tooltip);
}

fn setCloseTooltip(button: objc.Id, session: *daemon_client.Session) void {
    var title_buf: [512]u8 = undefined;
    const title = session.copyTitleSnapshot(&title_buf);
    var tooltip_buf: [600]u8 = undefined;
    const tooltip = std.fmt.bufPrint(&tooltip_buf, "Close {s}", .{title}) catch "Close Session";
    const ns_tooltip = objc.nsStringFromBytes(tooltip);
    objc.setId(button, objc.sel("setToolTip:"), ns_tooltip);
    objc.release(ns_tooltip);
}

fn revealActiveSession() void {
    const index = activeDisplayIndex() orelse return;
    if (index >= app.session_buttons.items.len) return;
    const button = app.session_buttons.items[index];
    const frame = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGRect)(
        button,
        objc.sel("frame"),
    );
    _ = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect) callconv(.c) objc.BOOL)(
        app.sidebar_document,
        objc.sel("scrollRectToVisible:"),
        frame,
    );
}

fn updateAttentionSurfaces() void {
    var count: usize = 0;
    for (app.sessions.sessions.items) |session| {
        if (session.needsAttention()) count += 1;
    }

    if (app.titlebar_attention_layer != null) {
        const show_titlebar_badge = !app.session_bar_visible and count > 0;
        styleAttentionLayer(app.titlebar_attention_layer, show_titlebar_badge);
    }
    if (app.sidebar_toggle_button != null) {
        var tooltip_buf: [128]u8 = undefined;
        const tooltip = if (app.session_bar_visible)
            "Hide Session Bar (⌘B)"
        else if (count == 1)
            "Show Session Bar — 1 session needs attention (⌘B)"
        else if (count > 1)
            std.fmt.bufPrint(
                &tooltip_buf,
                "Show Session Bar — {d} sessions need attention (⌘B)",
                .{count},
            ) catch "Show Session Bar (⌘B)"
        else
            "Show Session Bar (⌘B)";
        const ns_tooltip = objc.nsStringFromBytes(tooltip);
        objc.setId(app.sidebar_toggle_button, objc.sel("setToolTip:"), ns_tooltip);
        objc.setId(app.sidebar_toggle_button, objc.sel("setAccessibilityLabel:"), ns_tooltip);
        objc.release(ns_tooltip);
    }

    const ns_app = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSApplication"),
        objc.sel("sharedApplication"),
    );
    const dock_tile = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        ns_app,
        objc.sel("dockTile"),
    );
    if (count == 0) {
        objc.setId(dock_tile, objc.sel("setBadgeLabel:"), null);
        return;
    }
    var count_buf: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&count_buf, "{d}", .{count}) catch return;
    const ns_label = objc.nsStringFromBytes(label);
    objc.setId(dock_tile, objc.sel("setBadgeLabel:"), ns_label);
    objc.release(ns_label);
}

const SessionRowViews = struct {
    button: objc.Id,
    shortcut: objc.Id,
    close: objc.Id,
    attention: objc.Id,
    pair_left: objc.Id,
    pair_right: objc.Id,
    pair_left_shortcut: objc.Id,
    pair_right_shortcut: objc.Id,
    pair_left_attention: objc.Id,
    pair_right_attention: objc.Id,
    pair_left_close: objc.Id,
    pair_right_close: objc.Id,
    pair_separator: objc.Id,
    context_menu: objc.Id,
    context_item: objc.Id,
    context_swap_item: objc.Id,
    context_zoom_item: objc.Id,
};

const PairSegmentViews = struct {
    button: objc.Id,
    shortcut: objc.Id,
    attention: objc.Id,
    close: objc.Id,
};

fn createShortcutButton(parent: objc.Id) ?objc.Id {
    const shortcut = objc.msg(
        *const fn (objc.Class, objc.Sel, objc.Id, objc.Id, objc.Sel) callconv(.c) objc.Id,
    )(
        objc.cls("NSButton"),
        objc.sel("buttonWithTitle:target:action:"),
        objc.nsString(""),
        app.view,
        objc.sel("selectNumberedSession:"),
    );
    if (shortcut == null) return null;
    objc.setU(shortcut, objc.sel("setBordered:"), 0);
    objc.setU(shortcut, objc.sel("setAlignment:"), 1); // center
    objc.setU(shortcut, objc.sel("setWantsLayer:"), 1);
    objc.setU(shortcut, objc.sel("setHidden:"), 1);
    const shortcut_font = objc.msg(*const fn (objc.Class, objc.Sel, objc.CGFloat) callconv(.c) objc.Id)(
        objc.cls("NSFont"),
        objc.sel("systemFontOfSize:"),
        10.5,
    );
    objc.setId(shortcut, objc.sel("setFont:"), shortcut_font);
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        parent,
        objc.sel("addSubview:"),
        shortcut,
    );
    styleShortcutButton(shortcut);
    return shortcut;
}

fn createSessionButton(index: usize) ?SessionRowViews {
    const empty = objc.nsString("");
    const button = objc.msg(
        *const fn (objc.Class, objc.Sel, objc.Id, objc.Id, objc.Sel) callconv(.c) objc.Id,
    )(
        app.session_row_class,
        objc.sel("buttonWithTitle:target:action:"),
        empty,
        app.view,
        objc.sel("selectSession:"),
    );
    if (button == null) return null;
    objc.setU(button, objc.sel("setTag:"), index + 1);
    objc.setU(button, objc.sel("setBordered:"), 0);
    objc.setU(button, objc.sel("setAlignment:"), 0); // left
    objc.setU(button, objc.sel("setAutoresizingMask:"), 0);
    objc.setU(button, objc.sel("setWantsLayer:"), 1);
    const cell = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(button, objc.sel("cell"));
    objc.setClass(cell, app.session_row_cell_class);
    objc.setU(cell, objc.sel("setLineBreakMode:"), 5); // truncate middle
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        app.sidebar_document,
        objc.sel("addSubview:"),
        button,
    );

    const tracking_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSTrackingArea"),
        objc.sel("alloc"),
    );
    const tracking = objc.msg(
        *const fn (objc.Id, objc.Sel, objc.CGRect, objc.NSUInteger, objc.Id, objc.Id) callconv(.c) objc.Id,
    )(
        tracking_alloc,
        objc.sel("initWithRect:options:owner:userInfo:"),
        .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } },
        1 | 32 | 512, // mouse entered/exited | active in key window | visible rect
        button,
        null,
    );
    if (tracking != null) {
        objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
            button,
            objc.sel("addTrackingArea:"),
            tracking,
        );
        objc.release(tracking);
    }

    const pair_left = createPairSegment(button) orelse return null;
    const pair_right = createPairSegment(button) orelse return null;
    const pair_separator = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("CALayer"),
        objc.sel("layer"),
    );
    if (pair_separator == null) return null;
    const separator_color = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSColor"),
        objc.sel("separatorColor"),
    );
    const separator_cg = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        separator_color,
        objc.sel("CGColor"),
    );
    objc.setId(pair_separator, objc.sel("setBackgroundColor:"), separator_cg);
    objc.setU(pair_separator, objc.sel("setHidden:"), 1);
    const row_layer = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(button, objc.sel("layer"));
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        row_layer,
        objc.sel("addSublayer:"),
        pair_separator,
    );
    const context_menu = objc.allocInit(objc.cls("NSMenu"));
    const context_item_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSMenuItem"),
        objc.sel("alloc"),
    );
    const context_item = objc.msg(
        *const fn (objc.Id, objc.Sel, objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id,
    )(
        context_item_alloc,
        objc.sel("initWithTitle:action:keyEquivalent:"),
        objc.nsString("Separate Sessions"),
        objc.sel("separateDisplayItem:"),
        objc.nsString(""),
    );
    if (context_menu == null or context_item == null) return null;
    objc.setId(context_item, objc.sel("setTarget:"), app.view);
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        context_menu,
        objc.sel("addItem:"),
        context_item,
    );
    const context_swap_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSMenuItem"),
        objc.sel("alloc"),
    );
    const context_swap_item = objc.msg(
        *const fn (objc.Id, objc.Sel, objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id,
    )(
        context_swap_alloc,
        objc.sel("initWithTitle:action:keyEquivalent:"),
        objc.nsString("Swap Sides"),
        objc.sel("swapDisplayItemSides:"),
        objc.nsString(""),
    );
    if (context_swap_item == null) return null;
    objc.setId(context_swap_item, objc.sel("setTarget:"), app.view);
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        context_menu,
        objc.sel("addItem:"),
        context_swap_item,
    );
    const context_zoom_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSMenuItem"),
        objc.sel("alloc"),
    );
    const context_zoom_item = objc.msg(
        *const fn (objc.Id, objc.Sel, objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id,
    )(
        context_zoom_alloc,
        objc.sel("initWithTitle:action:keyEquivalent:"),
        objc.nsString("Zoom Focused Pane"),
        objc.sel("toggleDisplayItemZoom:"),
        objc.nsString(""),
    );
    if (context_zoom_item == null) return null;
    objc.setId(context_zoom_item, objc.sel("setTarget:"), app.view);
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        context_menu,
        objc.sel("addItem:"),
        context_zoom_item,
    );

    const close_title = objc.nsString("×");
    const close = objc.msg(
        *const fn (objc.Class, objc.Sel, objc.Id, objc.Id, objc.Sel) callconv(.c) objc.Id,
    )(
        objc.cls("NSButton"),
        objc.sel("buttonWithTitle:target:action:"),
        close_title,
        app.view,
        objc.sel("closeSession:"),
    );
    if (close == null) return null;
    objc.setU(close, objc.sel("setTag:"), index + 1);
    objc.setU(close, objc.sel("setBordered:"), 0);
    objc.setU(close, objc.sel("setAlignment:"), 1);
    objc.setU(close, objc.sel("setHidden:"), 1);
    styleSidebarCloseButton(close);
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        button,
        objc.sel("addSubview:"),
        close,
    );

    const attention = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("CALayer"),
        objc.sel("layer"),
    );
    if (attention == null) return null;
    setViewFrame(attention, .{
        .origin = .{ .x = 8, .y = 11 },
        .size = .{ .width = 6, .height = 6 },
    });
    objc.setU(attention, objc.sel("setHidden:"), 1);
    const button_layer = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        button,
        objc.sel("layer"),
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        button_layer,
        objc.sel("addSublayer:"),
        attention,
    );

    const shortcut = createShortcutButton(app.sidebar_document) orelse return null;
    objc.setU(shortcut, objc.sel("setTag:"), index + 1);
    return .{
        .button = button,
        .shortcut = shortcut,
        .close = close,
        .attention = attention,
        .pair_left = pair_left.button,
        .pair_right = pair_right.button,
        .pair_left_shortcut = pair_left.shortcut,
        .pair_right_shortcut = pair_right.shortcut,
        .pair_left_attention = pair_left.attention,
        .pair_right_attention = pair_right.attention,
        .pair_left_close = pair_left.close,
        .pair_right_close = pair_right.close,
        .pair_separator = pair_separator,
        .context_menu = context_menu,
        .context_item = context_item,
        .context_swap_item = context_swap_item,
        .context_zoom_item = context_zoom_item,
    };
}

fn createPairSegment(parent: objc.Id) ?PairSegmentViews {
    const segment = objc.msg(
        *const fn (objc.Class, objc.Sel, objc.Id, objc.Id, objc.Sel) callconv(.c) objc.Id,
    )(
        app.pair_segment_class,
        objc.sel("buttonWithTitle:target:action:"),
        objc.nsString(""),
        app.view,
        objc.sel("selectPairMember:"),
    );
    if (segment == null) return null;
    objc.setU(segment, objc.sel("setBordered:"), 0);
    objc.setU(segment, objc.sel("setAlignment:"), 0);
    objc.setU(segment, objc.sel("setWantsLayer:"), 1);
    objc.setU(segment, objc.sel("setHidden:"), 1);
    const cell = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(segment, objc.sel("cell"));
    objc.setClass(cell, app.pair_segment_cell_class);
    objc.setU(cell, objc.sel("setLineBreakMode:"), 5);
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        parent,
        objc.sel("addSubview:"),
        segment,
    );

    const tracking_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSTrackingArea"),
        objc.sel("alloc"),
    );
    const tracking = objc.msg(
        *const fn (objc.Id, objc.Sel, objc.CGRect, objc.NSUInteger, objc.Id, objc.Id) callconv(.c) objc.Id,
    )(
        tracking_alloc,
        objc.sel("initWithRect:options:owner:userInfo:"),
        .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } },
        1 | 2 | 32 | 512,
        segment,
        null,
    );
    if (tracking != null) {
        objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
            segment,
            objc.sel("addTrackingArea:"),
            tracking,
        );
        objc.release(tracking);
    }
    const attention = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("CALayer"),
        objc.sel("layer"),
    );
    if (attention == null) return null;
    setViewFrame(attention, .{
        .origin = .{ .x = 6, .y = 11 },
        .size = .{ .width = 6, .height = 6 },
    });
    styleAttentionLayer(attention, false);
    const layer = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(segment, objc.sel("layer"));
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        layer,
        objc.sel("addSublayer:"),
        attention,
    );
    const close = objc.msg(
        *const fn (objc.Class, objc.Sel, objc.Id, objc.Id, objc.Sel) callconv(.c) objc.Id,
    )(
        objc.cls("NSButton"),
        objc.sel("buttonWithTitle:target:action:"),
        objc.nsString("×"),
        app.view,
        objc.sel("closePairMember:"),
    );
    if (close == null) return null;
    objc.setU(close, objc.sel("setBordered:"), 0);
    objc.setU(close, objc.sel("setAlignment:"), 1);
    objc.setU(close, objc.sel("setHidden:"), 1);
    styleSidebarCloseButton(close);
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        segment,
        objc.sel("addSubview:"),
        close,
    );
    const shortcut = createShortcutButton(segment) orelse return null;
    return .{ .button = segment, .shortcut = shortcut, .attention = attention, .close = close };
}

fn styleSidebarCloseButton(close: objc.Id) void {
    const image = makeCloseIcon();
    if (image == null) return;
    defer objc.release(image);
    objc.setId(close, objc.sel("setTitle:"), objc.nsString(""));
    objc.setId(close, objc.sel("setImage:"), image);
    objc.setU(close, objc.sel("setImagePosition:"), 1); // NSImageOnly
    objc.setU(close, objc.sel("setImageScaling:"), 0); // proportionally down
    const label = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSColor"),
        objc.sel("labelColor"),
    );
    objc.setId(close, objc.sel("setContentTintColor:"), label);
}

fn styleAttentionLayer(layer: objc.Id, visible: bool) void {
    objc.setU(layer, objc.sel("setHidden:"), @intFromBool(!visible));
    if (!visible) return;
    const color = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSColor"),
        objc.sel("systemOrangeColor"),
    );
    const cg_color = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        color,
        objc.sel("CGColor"),
    );
    objc.setId(layer, objc.sel("setBackgroundColor:"), cg_color);
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat) callconv(.c) void)(
        layer,
        objc.sel("setCornerRadius:"),
        3,
    );
}

fn styleSessionButton(button: objc.Id, active: bool) void {
    const layer = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(button, objc.sel("layer"));
    const label_color = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSColor"),
        objc.sel("labelColor"),
    );
    const background = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat) callconv(.c) objc.Id)(
        label_color,
        objc.sel("colorWithAlphaComponent:"),
        if (active) 0.08 else 0,
    );
    const cg_color = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        background,
        objc.sel("CGColor"),
    );
    objc.setId(layer, objc.sel("setBackgroundColor:"), cg_color);
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat) callconv(.c) void)(
        layer,
        objc.sel("setCornerRadius:"),
        5,
    );
    objc.setU(layer, objc.sel("setMasksToBounds:"), 1);
}

fn stylePairSegment(button: objc.Id, active: bool) void {
    const layer = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(button, objc.sel("layer"));
    const label_color = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSColor"),
        objc.sel("labelColor"),
    );
    const background = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat) callconv(.c) objc.Id)(
        label_color,
        objc.sel("colorWithAlphaComponent:"),
        if (active) 0.1 else 0,
    );
    const cg_color = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        background,
        objc.sel("CGColor"),
    );
    objc.setId(layer, objc.sel("setBackgroundColor:"), cg_color);
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat) callconv(.c) void)(
        layer,
        objc.sel("setCornerRadius:"),
        0,
    );
}

fn styleShortcutButton(button: objc.Id) void {
    const layer = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(button, objc.sel("layer"));
    const label_color = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSColor"),
        objc.sel("labelColor"),
    );
    const background = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat) callconv(.c) objc.Id)(
        label_color,
        objc.sel("colorWithAlphaComponent:"),
        0.08,
    );
    const cg_color = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        background,
        objc.sel("CGColor"),
    );
    objc.setId(layer, objc.sel("setBackgroundColor:"), cg_color);
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat) callconv(.c) void)(
        layer,
        objc.sel("setCornerRadius:"),
        4,
    );
}

fn installTitlebarControls() void {
    const zoom = objc.msg(*const fn (objc.Id, objc.Sel, objc.NSUInteger) callconv(.c) objc.Id)(
        app.window,
        objc.sel("standardWindowButton:"),
        2, // NSWindowZoomButton
    );
    if (zoom == null) return;
    const titlebar = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        zoom,
        objc.sel("superview"),
    );
    if (titlebar == null) return;
    const traffic_frame = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGRect)(
        zoom,
        objc.sel("frame"),
    );
    const button_size: f32 = 24;
    const y: f32 = @floatCast(
        traffic_frame.origin.y + (traffic_frame.size.height - button_size) / 2,
    );
    const first_x: f32 = @floatCast(traffic_frame.origin.x + traffic_frame.size.width + 12);
    app.sidebar_toggle_button = addTitlebarButton(
        titlebar,
        .sidebar,
        "Toggle Session Bar (⌘B)",
        "toggleSessionBar:",
        first_x,
        y,
    );
    if (app.sidebar_toggle_button != null) {
        const attention = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
            objc.cls("CALayer"),
            objc.sel("layer"),
        );
        if (attention != null) {
            setViewFrame(attention, .{
                .origin = .{ .x = 17, .y = 17 },
                .size = .{ .width = 6, .height = 6 },
            });
            styleAttentionLayer(attention, false);
            const button_layer = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
                app.sidebar_toggle_button,
                objc.sel("layer"),
            );
            objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
                button_layer,
                objc.sel("addSublayer:"),
                attention,
            );
            app.titlebar_attention_layer = attention;
        }
    }
    _ = addTitlebarButton(
        titlebar,
        .new_session,
        "New Session (⌘T)",
        "newSession:",
        first_x + button_size + 4,
        y,
    );
}

const TitlebarIcon = enum { sidebar, new_session };

fn makeCloseIcon() objc.Id {
    const image_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSImage"),
        objc.sel("alloc"),
    );
    const image = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGSize) callconv(.c) objc.Id)(
        image_alloc,
        objc.sel("initWithSize:"),
        .{ .width = 10, .height = 10 },
    );
    if (image == null) return null;
    objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(image, objc.sel("lockFocus"));
    const black = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSColor"),
        objc.sel("blackColor"),
    );
    objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(black, objc.sel("setStroke"));
    const path = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSBezierPath"),
        objc.sel("bezierPath"),
    );
    styleIconPath(path);
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGPoint) callconv(.c) void)(
        path,
        objc.sel("moveToPoint:"),
        .{ .x = 2.25, .y = 2.25 },
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGPoint) callconv(.c) void)(
        path,
        objc.sel("lineToPoint:"),
        .{ .x = 7.75, .y = 7.75 },
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGPoint) callconv(.c) void)(
        path,
        objc.sel("moveToPoint:"),
        .{ .x = 7.75, .y = 2.25 },
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGPoint) callconv(.c) void)(
        path,
        objc.sel("lineToPoint:"),
        .{ .x = 2.25, .y = 7.75 },
    );
    objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(path, objc.sel("stroke"));
    objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(image, objc.sel("unlockFocus"));
    objc.setU(image, objc.sel("setTemplate:"), 1);
    return image;
}

fn addTitlebarButton(
    titlebar: objc.Id,
    icon: TitlebarIcon,
    tooltip: [*:0]const u8,
    action: [*:0]const u8,
    x: f32,
    y: f32,
) objc.Id {
    const image = makeTitlebarIcon(icon);
    if (image == null) return null;
    defer objc.release(image);
    const button = objc.msg(
        *const fn (objc.Class, objc.Sel, objc.Id, objc.Id, objc.Sel) callconv(.c) objc.Id,
    )(
        objc.cls("NSButton"),
        objc.sel("buttonWithImage:target:action:"),
        image,
        app.view,
        objc.sel(action),
    );
    if (button == null) return null;
    objc.setU(button, objc.sel("setBordered:"), 0);
    objc.setU(button, objc.sel("setImagePosition:"), 1); // NSImageOnly
    objc.setU(button, objc.sel("setImageScaling:"), 0); // proportionally down
    objc.setU(button, objc.sel("setWantsLayer:"), 1);
    objc.setId(button, objc.sel("setToolTip:"), objc.nsString(tooltip));
    objc.setId(button, objc.sel("setAccessibilityLabel:"), objc.nsString(tooltip));
    setViewFrame(button, .{
        .origin = .{ .x = x, .y = y },
        .size = .{ .width = 24, .height = 24 },
    });
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        titlebar,
        objc.sel("addSubview:"),
        button,
    );
    return button;
}

/// Our title-bar glyphs are vector paths rendered into NSImage templates.
/// The geometry ships in the executable; AppKit still owns tinting, scale,
/// disabled state, accessibility, and button interaction.
fn makeTitlebarIcon(icon: TitlebarIcon) objc.Id {
    const image_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSImage"),
        objc.sel("alloc"),
    );
    const image = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGSize) callconv(.c) objc.Id)(
        image_alloc,
        objc.sel("initWithSize:"),
        .{ .width = 16, .height = 16 },
    );
    if (image == null) return null;

    objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(image, objc.sel("lockFocus"));
    const black = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSColor"),
        objc.sel("blackColor"),
    );
    objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(black, objc.sel("setStroke"));

    switch (icon) {
        .sidebar => {
            const outline = objc.msg(
                *const fn (objc.Class, objc.Sel, objc.CGRect, objc.CGFloat, objc.CGFloat) callconv(.c) objc.Id,
            )(
                objc.cls("NSBezierPath"),
                objc.sel("bezierPathWithRoundedRect:xRadius:yRadius:"),
                .{ .origin = .{ .x = 1.5, .y = 2 }, .size = .{ .width = 13, .height = 12 } },
                2.25,
                2.25,
            );
            styleIconPath(outline);
            objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(outline, objc.sel("stroke"));

            const rail = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
                objc.cls("NSBezierPath"),
                objc.sel("bezierPath"),
            );
            styleIconPath(rail);
            objc.msg(*const fn (objc.Id, objc.Sel, objc.CGPoint) callconv(.c) void)(
                rail,
                objc.sel("moveToPoint:"),
                .{ .x = 5.25, .y = 2.5 },
            );
            objc.msg(*const fn (objc.Id, objc.Sel, objc.CGPoint) callconv(.c) void)(
                rail,
                objc.sel("lineToPoint:"),
                .{ .x = 5.25, .y = 13.5 },
            );
            objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(rail, objc.sel("stroke"));
        },
        .new_session => {
            const plus = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
                objc.cls("NSBezierPath"),
                objc.sel("bezierPath"),
            );
            styleIconPath(plus);
            objc.msg(*const fn (objc.Id, objc.Sel, objc.CGPoint) callconv(.c) void)(
                plus,
                objc.sel("moveToPoint:"),
                .{ .x = 3.5, .y = 8 },
            );
            objc.msg(*const fn (objc.Id, objc.Sel, objc.CGPoint) callconv(.c) void)(
                plus,
                objc.sel("lineToPoint:"),
                .{ .x = 12.5, .y = 8 },
            );
            objc.msg(*const fn (objc.Id, objc.Sel, objc.CGPoint) callconv(.c) void)(
                plus,
                objc.sel("moveToPoint:"),
                .{ .x = 8, .y = 3.5 },
            );
            objc.msg(*const fn (objc.Id, objc.Sel, objc.CGPoint) callconv(.c) void)(
                plus,
                objc.sel("lineToPoint:"),
                .{ .x = 8, .y = 12.5 },
            );
            objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(plus, objc.sel("stroke"));
        },
    }

    objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(image, objc.sel("unlockFocus"));
    objc.setU(image, objc.sel("setTemplate:"), 1);
    return image;
}

fn styleIconPath(path: objc.Id) void {
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat) callconv(.c) void)(
        path,
        objc.sel("setLineWidth:"),
        1.5,
    );
    objc.setU(path, objc.sel("setLineCapStyle:"), 1); // round
    objc.setU(path, objc.sel("setLineJoinStyle:"), 1); // round
}

fn buildWindow() !void {
    const m = app.renderer.cellMetrics();
    const terminal_width = m.cell_width * @as(f32, @floatFromInt(initial_cols));
    const terminal_height = m.cell_height * @as(f32, @floatFromInt(initial_rows));
    const extra_width: f32 = if (app.session_bar_visible) app.sidebar_preferred_width else 0;
    const content: objc.CGRect = .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{
            .width = terminal_width + extra_width,
            .height = terminal_height,
        },
    };

    const window_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSWindow"),
        objc.sel("alloc"),
    );
    const window = objc.msg(
        *const fn (objc.Id, objc.Sel, objc.CGRect, objc.NSUInteger, objc.NSUInteger, objc.BOOL) callconv(.c) objc.Id,
    )(
        window_alloc,
        objc.sel("initWithContentRect:styleMask:backing:defer:"),
        content,
        15, // titled | closable | miniaturizable | resizable
        2, // buffered
        0,
    );
    if (window == null) return error.WindowCreate;
    app.window = window;

    const title = objc.nsString("Boring Terminal");
    objc.setId(window, objc.sel("setTitle:"), title);

    // Grids below ~20x4 are degenerate for shell repaint math and reflow
    // alike (RFC 0005); clamp like every terminal does.
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGSize) callconv(.c) void)(
        window,
        objc.sel("setContentMinSize:"),
        .{
            .width = (if (app.session_bar_visible) sidebar_layout.min_width else 0) + m.cell_width * 20,
            .height = m.cell_height * 4,
        },
    );

    const root_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSView"),
        objc.sel("alloc"),
    );
    const root = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect) callconv(.c) objc.Id)(
        root_alloc,
        objc.sel("initWithFrame:"),
        content,
    );
    if (root == null) return error.ViewCreate;
    app.root_view = root;

    const sidebar_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSVisualEffectView"),
        objc.sel("alloc"),
    );
    const sidebar = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect) callconv(.c) objc.Id)(
        sidebar_alloc,
        objc.sel("initWithFrame:"),
        content,
    );
    if (sidebar == null) return error.ViewCreate;
    app.sidebar = sidebar;
    objc.setU(sidebar, objc.sel("setMaterial:"), 7); // NSVisualEffectMaterialSidebar
    objc.setU(sidebar, objc.sel("setBlendingMode:"), 0); // behind window
    objc.setU(sidebar, objc.sel("setState:"), 1); // active

    const scroll_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSScrollView"),
        objc.sel("alloc"),
    );
    const sidebar_scroll = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect) callconv(.c) objc.Id)(
        scroll_alloc,
        objc.sel("initWithFrame:"),
        content,
    );
    if (sidebar_scroll == null) return error.ViewCreate;
    app.sidebar_scroll = sidebar_scroll;
    objc.setU(sidebar_scroll, objc.sel("setDrawsBackground:"), 0);
    objc.setU(sidebar_scroll, objc.sel("setBorderType:"), 0);
    objc.setU(sidebar_scroll, objc.sel("setHasHorizontalScroller:"), 0);
    objc.setU(sidebar_scroll, objc.sel("setHasVerticalScroller:"), 1);
    objc.setU(sidebar_scroll, objc.sel("setAutohidesScrollers:"), 1);
    objc.setU(sidebar_scroll, objc.sel("setScrollerStyle:"), 1); // NSScrollerStyleOverlay
    const clip_view = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        sidebar_scroll,
        objc.sel("contentView"),
    );
    objc.setU(clip_view, objc.sel("setDrawsBackground:"), 0);

    const document_class = makeSidebarDocumentClass();
    const document_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        document_class,
        objc.sel("alloc"),
    );
    const sidebar_document = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect) callconv(.c) objc.Id)(
        document_alloc,
        objc.sel("initWithFrame:"),
        content,
    );
    if (sidebar_document == null) return error.ViewCreate;
    app.sidebar_document = sidebar_document;
    objc.setU(sidebar_document, objc.sel("setWantsLayer:"), 1);
    const drag_types = objc.msg(*const fn (objc.Class, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        objc.cls("NSArray"),
        objc.sel("arrayWithObject:"),
        objc.nsString(sidebar_drag_type),
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        sidebar_document,
        objc.sel("registerForDraggedTypes:"),
        drag_types,
    );
    const drop_indicator = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("CALayer"),
        objc.sel("layer"),
    );
    if (drop_indicator == null) return error.ViewCreate;
    app.sidebar_drop_indicator = drop_indicator;
    const accent = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSColor"),
        objc.sel("controlAccentColor"),
    );
    const translucent_accent = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat) callconv(.c) objc.Id)(
        accent,
        objc.sel("colorWithAlphaComponent:"),
        0.28,
    );
    const accent_cg = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        translucent_accent,
        objc.sel("CGColor"),
    );
    objc.setId(drop_indicator, objc.sel("setBackgroundColor:"), accent_cg);
    objc.setU(drop_indicator, objc.sel("setHidden:"), 1);
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat) callconv(.c) void)(
        drop_indicator,
        objc.sel("setCornerRadius:"),
        4,
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat) callconv(.c) void)(
        drop_indicator,
        objc.sel("setZPosition:"),
        100,
    );
    const document_layer = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        sidebar_document,
        objc.sel("layer"),
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        document_layer,
        objc.sel("addSublayer:"),
        drop_indicator,
    );
    objc.setId(sidebar_scroll, objc.sel("setDocumentView:"), sidebar_document);
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        sidebar,
        objc.sel("addSubview:"),
        sidebar_scroll,
    );

    app.session_row_class = makeSessionRowClass();
    app.session_row_cell_class = makeSessionRowCellClass();
    app.pair_segment_class = makePairSegmentClass();
    app.pair_segment_cell_class = makePairSegmentCellClass();
    const view_class = makeViewClass();
    const view_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        view_class,
        objc.sel("alloc"),
    );
    const view = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect) callconv(.c) objc.Id)(
        view_alloc,
        objc.sel("initWithFrame:"),
        content,
    );
    if (view == null) return error.ViewCreate;
    app.view = view;
    const file_drop_types = objc.msg(*const fn (objc.Class, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        objc.cls("NSArray"),
        objc.sel("arrayWithObject:"),
        objc.nsString("public.file-url"),
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        view,
        objc.sel("registerForDraggedTypes:"),
        file_drop_types,
    );

    const divider_class = makeSidebarDividerClass();
    const divider_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        divider_class,
        objc.sel("alloc"),
    );
    const sidebar_divider = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect) callconv(.c) objc.Id)(
        divider_alloc,
        objc.sel("initWithFrame:"),
        content,
    );
    if (sidebar_divider == null) return error.ViewCreate;
    app.sidebar_divider = sidebar_divider;
    objc.setU(sidebar_divider, objc.sel("setWantsLayer:"), 1);
    objc.setId(sidebar_divider, objc.sel("setToolTip:"), objc.nsString("Resize Sidebar"));
    objc.setId(sidebar_divider, objc.sel("setAccessibilityLabel:"), objc.nsString("Resize Sidebar"));

    const divider_layer = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        sidebar_divider,
        objc.sel("layer"),
    );
    const line = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("CALayer"),
        objc.sel("layer"),
    );
    app.sidebar_divider_line = line;
    const separator = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSColor"),
        objc.sel("separatorColor"),
    );
    const separator_cg = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        separator,
        objc.sel("CGColor"),
    );
    objc.setId(line, objc.sel("setBackgroundColor:"), separator_cg);
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        divider_layer,
        objc.sel("addSublayer:"),
        line,
    );

    const pair_divider_class = makePairDividerClass();
    const pair_divider_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        pair_divider_class,
        objc.sel("alloc"),
    );
    const pair_divider = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect) callconv(.c) objc.Id)(
        pair_divider_alloc,
        objc.sel("initWithFrame:"),
        content,
    );
    if (pair_divider == null) return error.ViewCreate;
    app.pair_divider = pair_divider;
    objc.setU(pair_divider, objc.sel("setWantsLayer:"), 1);
    objc.setU(pair_divider, objc.sel("setHidden:"), 1);
    objc.setId(pair_divider, objc.sel("setToolTip:"), objc.nsString("Resize Paired Sessions"));
    objc.setId(pair_divider, objc.sel("setAccessibilityLabel:"), objc.nsString("Resize Paired Sessions"));
    const pair_layer = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        pair_divider,
        objc.sel("layer"),
    );
    const pair_line = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("CALayer"),
        objc.sel("layer"),
    );
    app.pair_divider_line = pair_line;
    objc.setId(pair_line, objc.sel("setBackgroundColor:"), separator_cg);
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        pair_layer,
        objc.sel("addSublayer:"),
        pair_line,
    );

    // Layer-hosting CAMetalLayer.
    const layer = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("CAMetalLayer"),
        objc.sel("layer"),
    );
    app.layer = layer;
    objc.setId(layer, objc.sel("setDevice:"), app.renderer.device);
    objc.setU(layer, objc.sel("setPixelFormat:"), 80); // bgra8_unorm
    objc.setU(layer, objc.sel("setFramebufferOnly:"), 1);
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat) callconv(.c) void)(
        layer,
        objc.sel("setContentsScale:"),
        @floatCast(app.scale),
    );
    objc.setId(view, objc.sel("setLayer:"), layer);
    objc.setU(view, objc.sel("setWantsLayer:"), 1);

    // Frame-change notifications drive grid/drawable resizing.
    objc.setU(view, objc.sel("setPostsFrameChangedNotifications:"), 1);
    const center = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSNotificationCenter"),
        objc.sel("defaultCenter"),
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id, objc.Sel, objc.Id, objc.Id) callconv(.c) void)(
        center,
        objc.sel("addObserver:selector:name:object:"),
        view,
        objc.sel("frameChanged:"),
        objc.nsString("NSViewFrameDidChangeNotification"),
        view,
    );

    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        root,
        objc.sel("addSubview:"),
        sidebar,
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        root,
        objc.sel("addSubview:"),
        view,
    );
    // The divider is last so its forgiving hit target straddles both the rail
    // and terminal without either underlying view stealing the drag.
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        root,
        objc.sel("addSubview:"),
        sidebar_divider,
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        root,
        objc.sel("addSubview:"),
        pair_divider,
    );
    try app.search_bar.init(.{
        .parent = root,
        .target = view,
        .placeholder = "Find in Session",
        .query_action = objc.sel("searchChanged:"),
        .previous_action = objc.sel("findPrevious:"),
        .next_action = objc.sel("findNext:"),
        .close_action = objc.sel("closeFind:"),
    });
    objc.setId(window, objc.sel("setContentView:"), root);
    objc.setU(window, objc.sel("setAcceptsMouseMovedEvents:"), 1);
    installTitlebarControls();
    _ = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.BOOL)(
        window,
        objc.sel("makeFirstResponder:"),
        view,
    );
    objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(window, objc.sel("center"));
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        window,
        objc.sel("makeKeyAndOrderFront:"),
        null,
    );

    layoutSessionBar();
    syncSizes();
}

/// Recompute drawable size and grid dimensions from the view bounds.
fn syncSizes() void {
    const bounds = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGRect)(
        app.view,
        objc.sel("bounds"),
    );
    const w: f32 = @floatCast(bounds.size.width);
    const h: f32 = @floatCast(bounds.size.height);
    if (w <= 0 or h <= 0) return;
    app.view_size = .{ w, h };
    layoutPairDivider();
    layoutSearchOverlay();

    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGSize) callconv(.c) void)(
        app.layer,
        objc.sel("setDrawableSize:"),
        .{ .width = @floatCast(w * app.scale), .height = @floatCast(h * app.scale) },
    );

    const m = app.renderer.cellMetrics();
    const cols: u16 = @max(2, @as(u16, @intFromFloat(@floor(w / m.cell_width))));
    const rows: u16 = @max(1, @as(u16, @intFromFloat(h / m.cell_height)));
    const cell_pixel_width: u16 = @max(1, @as(u16, @intFromFloat(@round(m.cell_width * app.scale))));
    const cell_pixel_height: u16 = @max(1, @as(u16, @intFromFloat(@round(m.cell_height * app.scale))));
    const pixel_width = std.math.mul(u16, cols, cell_pixel_width) catch std.math.maxInt(u16);
    const pixel_height = std.math.mul(u16, rows, cell_pixel_height) catch std.math.maxInt(u16);
    app.cols = cols;
    app.rows = rows;
    app.pixel_width = pixel_width;
    app.pixel_height = pixel_height;

    const display_index = activeDisplayIndex() orelse return;
    switch (app.display_items.items[display_index]) {
        .single => |id| {
            const session = sessionById(id) orelse return;
            resizeVisibleSession(session, cols, rows, pixel_width, pixel_height);
        },
        .pair => |pair| {
            const geometry = display_model.pairGeometry(
                w,
                h,
                pair.ratio,
                m.cell_width,
                m.cell_height,
            ) orelse return;
            const left = sessionById(pair.left) orelse return;
            const right = sessionById(pair.right) orelse return;
            const left_pixels = std.math.mul(u16, geometry.left_cols, cell_pixel_width) catch
                std.math.maxInt(u16);
            const right_pixels = std.math.mul(u16, geometry.right_cols, cell_pixel_width) catch
                std.math.maxInt(u16);
            if (zoomedPairMember(pair)) |zoomed_id| {
                if (zoomed_id == pair.left) {
                    resizeVisibleSession(left, cols, rows, pixel_width, pixel_height);
                    resizeVisibleSession(right, geometry.right_cols, geometry.rows, right_pixels, pixel_height);
                } else {
                    resizeVisibleSession(left, geometry.left_cols, geometry.rows, left_pixels, pixel_height);
                    resizeVisibleSession(right, cols, rows, pixel_width, pixel_height);
                }
            } else {
                resizeVisibleSession(left, geometry.left_cols, geometry.rows, left_pixels, pixel_height);
                resizeVisibleSession(right, geometry.right_cols, geometry.rows, right_pixels, pixel_height);
            }
        },
    }
}

fn resizeVisibleSession(
    session: *daemon_client.Session,
    cols: u16,
    rows: u16,
    pixel_width: u16,
    pixel_height: u16,
) void {
    if (session.requested_cols == cols and session.requested_rows == rows and
        session.requested_pixel_width == pixel_width and
        session.requested_pixel_height == pixel_height)
    {
        return;
    }
    session.requested_cols = cols;
    session.requested_rows = rows;
    session.requested_pixel_width = pixel_width;
    session.requested_pixel_height = pixel_height;
    const generation = session.geometry_generation.fetchAdd(1, .acq_rel) + 1;
    session.requestResize(.{
        .cols = cols,
        .rows = rows,
        .pixel_width = pixel_width,
        .pixel_height = pixel_height,
        .generation = generation,
    });
}

// -- input helpers -----------------------------------------------------------

fn ptyWrite(bytes: []const u8) void {
    const session = activeSession();
    if (session.exited.load(.acquire)) return;
    app.client.writeInput(session.id, bytes) catch {
        NSBeep();
        return;
    };
    session.grid_dirty.store(true, .release);
    scheduleRender();
}

fn ptyKey(event: vt.keyboard.Event) void {
    const session = activeSession();
    if (session.exited.load(.acquire)) return;
    app.client.keyEvent(session.id, event) catch {
        NSBeep();
        return;
    };
    session.grid_dirty.store(true, .release);
    scheduleRender();
}

fn ptyText(text: []const u8) void {
    if (text.len == 0) return;
    var offset: usize = 0;
    while (offset < text.len) {
        var end = @min(text.len, offset + vt.keyboard.max_text_bytes);
        while (end > offset and end < text.len and (text[end] & 0xc0) == 0x80) end -= 1;
        if (end == offset) return;
        ptyKey(.{ .code = .text, .text = text[offset..end] });
        offset = end;
    }
}

fn sendReplacementBackspaces(count: usize) void {
    var remaining = @min(count, vt.keyboard.max_text_bytes);
    while (remaining > 0) : (remaining -= 1) ptyKey(.{ .code = .backspace });
}

fn nsStringUtf8(str: objc.Id) ?[]const u8 {
    if (str == null) return null;
    const c_str = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) ?[*:0]const u8)(
        str,
        objc.sel("UTF8String"),
    ) orelse return null;
    return std.mem.span(c_str);
}

const mod_control: objc.NSUInteger = 1 << 18;
const mod_shift: objc.NSUInteger = 1 << 17;
const mod_option: objc.NSUInteger = 1 << 19;
const mod_command: objc.NSUInteger = 1 << 20;
const mod_caps_lock: objc.NSUInteger = 1 << 16;

// -- view class (runtime-built) ---------------------------------------------

fn makeSessionRowClass() objc.Class {
    const class = objc.allocateClass(objc.cls("NSButton"), "BoringTerminalSessionRowButton");
    objc.addProtocol(class, "NSDraggingSource");
    objc.addMethod(class, objc.sel("mouseEntered:"), @ptrCast(@constCast(&sessionRowMouseEntered)), "v@:@");
    objc.addMethod(class, objc.sel("mouseExited:"), @ptrCast(@constCast(&sessionRowMouseExited)), "v@:@");
    objc.addMethod(class, objc.sel("mouseDown:"), @ptrCast(@constCast(&sidebarDraggableMouseDown)), "v@:@");
    objc.addMethod(class, objc.sel("draggingSession:sourceOperationMaskForDraggingContext:"), @ptrCast(@constCast(&sidebarDragOperationMask)), "Q@:@q");
    objc.addMethod(class, objc.sel("ignoreModifierKeysForDraggingSession:"), @ptrCast(@constCast(&sidebarDragIgnoresModifiers)), "c@:@");
    objc.addMethod(class, objc.sel("draggingSession:endedAtPoint:operation:"), @ptrCast(@constCast(&sidebarDragEnded)), "v@:@{CGPoint=dd}Q");
    objc.registerClass(class);
    return class;
}

fn makeSessionRowCellClass() objc.Class {
    const class = objc.allocateClass(objc.cls("NSButtonCell"), "BoringTerminalSessionRowButtonCell");
    objc.addMethod(class, objc.sel("titleRectForBounds:"), @ptrCast(@constCast(&sessionRowTitleRect)), "{CGRect={CGPoint=dd}{CGSize=dd}}@:{CGRect={CGPoint=dd}{CGSize=dd}}");
    objc.registerClass(class);
    return class;
}

fn insetButtonCellTitleRect(
    self: objc.Id,
    selector: objc.Sel,
    bounds: objc.CGRect,
    leading: f64,
    trailing: f64,
) objc.CGRect {
    var super_ctx: objc.Super = .{ .receiver = self, .super_class = objc.cls("NSButtonCell") };
    var rect = objc.msgSuper(*const fn (*objc.Super, objc.Sel, objc.CGRect) callconv(.c) objc.CGRect)(
        &super_ctx,
        selector,
        bounds,
    );
    rect.origin.x += leading;
    rect.size.width = @max(0, rect.size.width - leading - trailing);
    return rect;
}

fn sessionRowTitleRect(self: objc.Id, selector: objc.Sel, bounds: objc.CGRect) callconv(.c) objc.CGRect {
    // A fixed leading attention lane and trailing close slot keep the label
    // stable whether either affordance is visible or not.
    return insetButtonCellTitleRect(self, selector, bounds, 18, 28);
}

fn makePairSegmentClass() objc.Class {
    const class = objc.allocateClass(objc.cls("NSButton"), "BoringTerminalPairSegmentButton");
    objc.addProtocol(class, "NSDraggingSource");
    objc.addMethod(class, objc.sel("mouseEntered:"), @ptrCast(@constCast(&pairSegmentMouseEntered)), "v@:@");
    objc.addMethod(class, objc.sel("mouseExited:"), @ptrCast(@constCast(&pairSegmentMouseExited)), "v@:@");
    objc.addMethod(class, objc.sel("mouseDown:"), @ptrCast(@constCast(&sidebarDraggableMouseDown)), "v@:@");
    objc.addMethod(class, objc.sel("draggingSession:sourceOperationMaskForDraggingContext:"), @ptrCast(@constCast(&sidebarDragOperationMask)), "Q@:@q");
    objc.addMethod(class, objc.sel("ignoreModifierKeysForDraggingSession:"), @ptrCast(@constCast(&sidebarDragIgnoresModifiers)), "c@:@");
    objc.addMethod(class, objc.sel("draggingSession:endedAtPoint:operation:"), @ptrCast(@constCast(&sidebarDragEnded)), "v@:@{CGPoint=dd}Q");
    objc.registerClass(class);
    return class;
}

fn makePairSegmentCellClass() objc.Class {
    const class = objc.allocateClass(objc.cls("NSButtonCell"), "BoringTerminalPairSegmentButtonCell");
    objc.addMethod(class, objc.sel("titleRectForBounds:"), @ptrCast(@constCast(&pairSegmentTitleRect)), "{CGRect={CGPoint=dd}{CGSize=dd}}@:{CGRect={CGPoint=dd}{CGSize=dd}}");
    objc.registerClass(class);
    return class;
}

fn pairSegmentTitleRect(self: objc.Id, selector: objc.Sel, bounds: objc.CGRect) callconv(.c) objc.CGRect {
    // The fixed leading lane owns the attention dot; the trailing lane owns
    // the member close control. Middle truncation paints in neither.
    return insetButtonCellTitleRect(self, selector, bounds, 16, 22);
}

fn makeSidebarDocumentClass() objc.Class {
    const class = objc.allocateClass(objc.cls("NSView"), "BoringTerminalSidebarDocumentView");
    objc.addProtocol(class, "NSDraggingDestination");
    objc.addMethod(class, objc.sel("isFlipped"), @ptrCast(@constCast(&sidebarDocumentIsFlipped)), "c@:");
    objc.addMethod(class, objc.sel("draggingEntered:"), @ptrCast(@constCast(&sidebarDraggingUpdated)), "Q@:@");
    objc.addMethod(class, objc.sel("draggingUpdated:"), @ptrCast(@constCast(&sidebarDraggingUpdated)), "Q@:@");
    objc.addMethod(class, objc.sel("draggingExited:"), @ptrCast(@constCast(&sidebarDraggingExited)), "v@:@");
    objc.addMethod(class, objc.sel("prepareForDragOperation:"), @ptrCast(@constCast(&sidebarPrepareDrag)), "c@:@");
    objc.addMethod(class, objc.sel("performDragOperation:"), @ptrCast(@constCast(&sidebarPerformDrag)), "c@:@");
    objc.registerClass(class);
    return class;
}

fn sidebarDocumentIsFlipped(_: objc.Id, _: objc.Sel) callconv(.c) objc.BOOL {
    return 1;
}

fn makeSidebarDividerClass() objc.Class {
    const class = objc.allocateClass(objc.cls("NSView"), "BoringTerminalSidebarDividerView");
    objc.addMethod(class, objc.sel("mouseDown:"), @ptrCast(@constCast(&sidebarDividerMouseDown)), "v@:@");
    objc.addMethod(class, objc.sel("mouseDragged:"), @ptrCast(@constCast(&sidebarDividerMouseDragged)), "v@:@");
    objc.addMethod(class, objc.sel("mouseUp:"), @ptrCast(@constCast(&sidebarDividerMouseUp)), "v@:@");
    objc.addMethod(class, objc.sel("resetCursorRects"), @ptrCast(@constCast(&sidebarDividerResetCursorRects)), "v@:");
    objc.registerClass(class);
    return class;
}

fn makePairDividerClass() objc.Class {
    const class = objc.allocateClass(objc.cls("NSView"), "BoringTerminalPairDividerView");
    objc.addMethod(class, objc.sel("mouseDown:"), @ptrCast(@constCast(&pairDividerMouseDown)), "v@:@");
    objc.addMethod(class, objc.sel("mouseDragged:"), @ptrCast(@constCast(&pairDividerMouseDragged)), "v@:@");
    objc.addMethod(class, objc.sel("mouseUp:"), @ptrCast(@constCast(&pairDividerMouseUp)), "v@:@");
    objc.addMethod(class, objc.sel("resetCursorRects"), @ptrCast(@constCast(&pairDividerResetCursorRects)), "v@:");
    objc.registerClass(class);
    return class;
}

fn pairDividerEventX(event: objc.Id) f32 {
    const in_window = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGPoint)(
        event,
        objc.sel("locationInWindow"),
    );
    const in_view = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGPoint, objc.Id) callconv(.c) objc.CGPoint)(
        app.view,
        objc.sel("convertPoint:fromView:"),
        in_window,
        null,
    );
    return @floatCast(in_view.x);
}

fn pairDividerMouseDown(_: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    const click_count = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(
        event,
        objc.sel("clickCount"),
    );
    if (click_count >= 2) {
        const member = setActivePairRatio(display_registry.default_ratio) orelse return;
        app.client.setPairRatio(member, display_registry.default_ratio) catch return NSBeep();
        syncSizes();
        renderNow();
        return;
    }
    app.pair_resize_active = true;
    app.in_live_resize = true;
    objc.setU(app.layer, objc.sel("setPresentsWithTransaction:"), 1);
}

fn pairDividerMouseDragged(_: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    if (!app.pair_resize_active) return;
    const metrics = app.renderer.cellMetrics();
    const ratio = display_model.ratioFromDivider(
        pairDividerEventX(event),
        app.view_size[0],
        metrics.cell_width,
    ) orelse return;
    const index = activeDisplayIndex() orelse return;
    const old_ratio = switch (app.display_items.items[index]) {
        .single => return,
        .pair => |pair| pair.ratio,
    };
    if (old_ratio == ratio) return;
    _ = setActivePairRatio(ratio);
    syncSizes();
    renderNow();
}

fn reconcileDividerCursor(divider: objc.Id, event: objc.Id) void {
    invalidateCursorRects(divider);

    const in_window = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGPoint)(
        event,
        objc.sel("locationInWindow"),
    );
    const point = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGPoint, objc.Id) callconv(.c) objc.CGPoint)(
        divider,
        objc.sel("convertPoint:fromView:"),
        in_window,
        null,
    );
    const bounds = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGRect)(
        divider,
        objc.sel("bounds"),
    );
    const inside = point.x >= bounds.origin.x and
        point.x < bounds.origin.x + bounds.size.width and
        point.y >= bounds.origin.y and
        point.y < bounds.origin.y + bounds.size.height;
    if (inside) return;

    const cursor = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSCursor"),
        objc.sel("arrowCursor"),
    );
    objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(cursor, objc.sel("set"));
}

fn pairDividerMouseUp(_: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    if (!app.pair_resize_active) return;
    app.pair_resize_active = false;
    app.in_live_resize = false;
    objc.setU(app.layer, objc.sel("setPresentsWithTransaction:"), 0);
    reconcileDividerCursor(app.pair_divider, event);
    const index = activeDisplayIndex() orelse return;
    const pair = switch (app.display_items.items[index]) {
        .single => return,
        .pair => |value| value,
    };
    app.client.setPairRatio(pair.focusedId(), pair.ratio) catch NSBeep();
    app.display_registry_dirty.store(true, .release);
    syncSizes();
    scheduleRender();
}

fn pairDividerResetCursorRects(self: objc.Id, selector: objc.Sel) callconv(.c) void {
    sidebarDividerResetCursorRects(self, selector);
}

fn sidebarDividerEventX(event: objc.Id) f32 {
    const in_window = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGPoint)(
        event,
        objc.sel("locationInWindow"),
    );
    const in_root = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGPoint, objc.Id) callconv(.c) objc.CGPoint)(
        app.root_view,
        objc.sel("convertPoint:fromView:"),
        in_window,
        null,
    );
    return @floatCast(in_root.x);
}

fn sidebarDividerMouseDown(_: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    const click_count = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(
        event,
        objc.sel("clickCount"),
    );
    if (click_count >= 2) {
        app.sidebar_preferred_width = sidebar_layout.default_width;
        saveSessionBarPreferences();
        layoutSessionBar();
        syncSizes();
        scheduleRender();
        return;
    }

    app.sidebar_resize_active = true;
    app.sidebar_resize_anchor_x = sidebarDividerEventX(event);
    app.sidebar_resize_start_width = app.sidebar_effective_width;
    app.in_live_resize = true;
    objc.setU(app.layer, objc.sel("setPresentsWithTransaction:"), 1);
}

fn sidebarDividerMouseDragged(_: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    if (!app.sidebar_resize_active) return;
    const delta = sidebarDividerEventX(event) - app.sidebar_resize_anchor_x;
    const width = sidebar_layout.preferredWidth(app.sidebar_resize_start_width + delta);
    if (width == app.sidebar_preferred_width) return;
    app.sidebar_preferred_width = width;
    layoutSessionBar();
    syncSizes();
    renderNow();
}

fn sidebarDividerMouseUp(_: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    if (!app.sidebar_resize_active) return;
    app.sidebar_resize_active = false;
    app.in_live_resize = false;
    objc.setU(app.layer, objc.sel("setPresentsWithTransaction:"), 0);
    reconcileDividerCursor(app.sidebar_divider, event);
    saveSessionBarPreferences();
    syncSizes();
    scheduleRender();
}

fn sidebarDividerResetCursorRects(self: objc.Id, selector: objc.Sel) callconv(.c) void {
    callSuperVoid(self, selector);
    const bounds = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGRect)(
        self,
        objc.sel("bounds"),
    );
    const cursor = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSCursor"),
        objc.sel("resizeLeftRightCursor"),
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect, objc.Id) callconv(.c) void)(
        self,
        objc.sel("addCursorRect:cursor:"),
        bounds,
        cursor,
    );
}

fn makeViewClass() objc.Class {
    const class = objc.allocateClass(objc.cls("NSView"), "BoringTerminalView");
    objc.addProtocol(class, "NSTextInputClient");
    objc.addProtocol(class, "NSControlTextEditingDelegate");
    objc.addProtocol(class, "NSDraggingDestination");

    objc.addMethod(class, objc.sel("acceptsFirstResponder"), @ptrCast(@constCast(&viewAcceptsFirstResponder)), "c@:");
    objc.addMethod(class, objc.sel("isOpaque"), @ptrCast(@constCast(&viewIsOpaque)), "c@:");
    objc.addMethod(class, objc.sel("keyDown:"), @ptrCast(@constCast(&viewKeyDown)), "v@:@");
    objc.addMethod(class, objc.sel("keyUp:"), @ptrCast(@constCast(&viewKeyUp)), "v@:@");
    objc.addMethod(class, objc.sel("flagsChanged:"), @ptrCast(@constCast(&viewFlagsChanged)), "v@:@");
    objc.addMethod(class, objc.sel("paste:"), @ptrCast(@constCast(&viewPaste)), "v@:@");
    objc.addMethod(class, objc.sel("draggingEntered:"), @ptrCast(@constCast(&viewFileDraggingUpdated)), "Q@:@");
    objc.addMethod(class, objc.sel("draggingUpdated:"), @ptrCast(@constCast(&viewFileDraggingUpdated)), "Q@:@");
    objc.addMethod(class, objc.sel("prepareForDragOperation:"), @ptrCast(@constCast(&viewPrepareFileDrag)), "c@:@");
    objc.addMethod(class, objc.sel("performDragOperation:"), @ptrCast(@constCast(&viewPerformFileDrag)), "c@:@");
    objc.addMethod(class, objc.sel("frameChanged:"), @ptrCast(@constCast(&viewFrameChanged)), "v@:@");
    objc.addMethod(class, objc.sel("scrollWheel:"), @ptrCast(@constCast(&viewScrollWheel)), "v@:@");
    objc.addMethod(class, objc.sel("mouseDown:"), @ptrCast(@constCast(&viewMouseDown)), "v@:@");
    objc.addMethod(class, objc.sel("mouseDragged:"), @ptrCast(@constCast(&viewMouseDragged)), "v@:@");
    objc.addMethod(class, objc.sel("mouseUp:"), @ptrCast(@constCast(&viewMouseUp)), "v@:@");
    objc.addMethod(class, objc.sel("rightMouseDown:"), @ptrCast(@constCast(&viewRightMouseDown)), "v@:@");
    objc.addMethod(class, objc.sel("rightMouseDragged:"), @ptrCast(@constCast(&viewRightMouseDragged)), "v@:@");
    objc.addMethod(class, objc.sel("rightMouseUp:"), @ptrCast(@constCast(&viewRightMouseUp)), "v@:@");
    objc.addMethod(class, objc.sel("otherMouseDown:"), @ptrCast(@constCast(&viewOtherMouseDown)), "v@:@");
    objc.addMethod(class, objc.sel("otherMouseDragged:"), @ptrCast(@constCast(&viewOtherMouseDragged)), "v@:@");
    objc.addMethod(class, objc.sel("otherMouseUp:"), @ptrCast(@constCast(&viewOtherMouseUp)), "v@:@");
    objc.addMethod(class, objc.sel("mouseMoved:"), @ptrCast(@constCast(&viewMouseMoved)), "v@:@");
    objc.addMethod(class, objc.sel("selectionScrollTick:"), @ptrCast(@constCast(&selectionScrollTick)), "v@:@");
    objc.addMethod(class, objc.sel("syncOutputTimeout:"), @ptrCast(@constCast(&syncOutputTimeout)), "v@:@");
    objc.addMethod(class, objc.sel("shortcutHintTick:"), @ptrCast(@constCast(&shortcutHintTick)), "v@:@");
    objc.addMethod(class, objc.sel("copy:"), @ptrCast(@constCast(&viewCopy)), "v@:@");
    objc.addMethod(class, objc.sel("clearSession:"), @ptrCast(@constCast(&viewClearSession)), "v@:@");
    objc.addMethod(class, objc.sel("newSession:"), @ptrCast(@constCast(&viewNewSession)), "v@:@");
    objc.addMethod(class, objc.sel("newSessionBeside:"), @ptrCast(@constCast(&viewNewSessionBeside)), "v@:@");
    objc.addMethod(class, objc.sel("closeSession:"), @ptrCast(@constCast(&viewCloseSession)), "v@:@");
    objc.addMethod(class, objc.sel("closePairMember:"), @ptrCast(@constCast(&viewClosePairMember)), "v@:@");
    objc.addMethod(class, objc.sel("selectSession:"), @ptrCast(@constCast(&viewSelectSession)), "v@:@");
    objc.addMethod(class, objc.sel("selectNumberedSession:"), @ptrCast(@constCast(&viewSelectNumberedSession)), "v@:@");
    objc.addMethod(class, objc.sel("selectPairMember:"), @ptrCast(@constCast(&viewSelectPairMember)), "v@:@");
    objc.addMethod(class, objc.sel("nextSession:"), @ptrCast(@constCast(&viewNextSession)), "v@:@");
    objc.addMethod(class, objc.sel("previousSession:"), @ptrCast(@constCast(&viewPreviousSession)), "v@:@");
    objc.addMethod(class, objc.sel("pairWithPreviousSession:"), @ptrCast(@constCast(&viewPairWithPreviousSession)), "v@:@");
    objc.addMethod(class, objc.sel("pairWithNextSession:"), @ptrCast(@constCast(&viewPairWithNextSession)), "v@:@");
    objc.addMethod(class, objc.sel("separateSessions:"), @ptrCast(@constCast(&viewSeparateSessions)), "v@:@");
    objc.addMethod(class, objc.sel("separateDisplayItem:"), @ptrCast(@constCast(&viewSeparateDisplayItem)), "v@:@");
    objc.addMethod(class, objc.sel("swapSessionSides:"), @ptrCast(@constCast(&viewSwapSessionSides)), "v@:@");
    objc.addMethod(class, objc.sel("swapDisplayItemSides:"), @ptrCast(@constCast(&viewSwapDisplayItemSides)), "v@:@");
    objc.addMethod(class, objc.sel("focusLeftPane:"), @ptrCast(@constCast(&viewFocusLeftPane)), "v@:@");
    objc.addMethod(class, objc.sel("focusRightPane:"), @ptrCast(@constCast(&viewFocusRightPane)), "v@:@");
    objc.addMethod(class, objc.sel("movePaneLeft:"), @ptrCast(@constCast(&viewMovePaneLeft)), "v@:@");
    objc.addMethod(class, objc.sel("movePaneRight:"), @ptrCast(@constCast(&viewMovePaneRight)), "v@:@");
    objc.addMethod(class, objc.sel("focusPreviousSessionGroup:"), @ptrCast(@constCast(&viewFocusPreviousSessionGroup)), "v@:@");
    objc.addMethod(class, objc.sel("focusNextSessionGroup:"), @ptrCast(@constCast(&viewFocusNextSessionGroup)), "v@:@");
    objc.addMethod(class, objc.sel("moveSessionGroupUp:"), @ptrCast(@constCast(&viewMoveSessionGroupUp)), "v@:@");
    objc.addMethod(class, objc.sel("moveSessionGroupDown:"), @ptrCast(@constCast(&viewMoveSessionGroupDown)), "v@:@");
    objc.addMethod(class, objc.sel("togglePairZoom:"), @ptrCast(@constCast(&viewTogglePairZoom)), "v@:@");
    objc.addMethod(class, objc.sel("toggleDisplayItemZoom:"), @ptrCast(@constCast(&viewToggleDisplayItemZoom)), "v@:@");
    objc.addMethod(class, objc.sel("toggleSessionBar:"), @ptrCast(@constCast(&viewToggleSessionBar)), "v@:@");
    objc.addMethod(class, objc.sel("increaseFontSize:"), @ptrCast(@constCast(&viewIncreaseFontSize)), "v@:@");
    objc.addMethod(class, objc.sel("decreaseFontSize:"), @ptrCast(@constCast(&viewDecreaseFontSize)), "v@:@");
    objc.addMethod(class, objc.sel("resetFontSize:"), @ptrCast(@constCast(&viewResetFontSize)), "v@:@");
    objc.addMethod(class, objc.sel("validateMenuItem:"), @ptrCast(@constCast(&viewValidateMenuItem)), "c@:@");
    objc.addMethod(class, objc.sel("openConfiguration:"), @ptrCast(@constCast(&viewOpenConfiguration)), "v@:@");
    objc.addMethod(class, objc.sel("showBackgroundServiceUpdate:"), @ptrCast(@constCast(&viewShowBackgroundServiceUpdate)), "v@:@");
    objc.addMethod(class, objc.sel("showKeyboardShortcuts:"), @ptrCast(@constCast(&viewShowKeyboardShortcuts)), "v@:@");
    objc.addMethod(class, objc.sel("showFind:"), @ptrCast(@constCast(&viewShowFind)), "v@:@");
    objc.addMethod(class, objc.sel("findNext:"), @ptrCast(@constCast(&viewFindNext)), "v@:@");
    objc.addMethod(class, objc.sel("findPrevious:"), @ptrCast(@constCast(&viewFindPrevious)), "v@:@");
    objc.addMethod(class, objc.sel("closeFind:"), @ptrCast(@constCast(&viewCloseFind)), "v@:@");
    objc.addMethod(class, objc.sel("searchChanged:"), @ptrCast(@constCast(&viewSearchChanged)), "v@:@");
    objc.addMethod(class, objc.sel("control:textView:doCommandBySelector:"), @ptrCast(@constCast(&viewSearchCommand)), "c@:@@:");
    objc.addMethod(class, objc.sel("viewWillStartLiveResize"), @ptrCast(@constCast(&viewWillStartLiveResize)), "v@:");
    objc.addMethod(class, objc.sel("viewDidEndLiveResize"), @ptrCast(@constCast(&viewDidEndLiveResize)), "v@:");

    // NSTextInputClient.
    objc.addMethod(class, objc.sel("insertText:replacementRange:"), @ptrCast(@constCast(&tiInsertText)), "v@:@{_NSRange=QQ}");
    objc.addMethod(class, objc.sel("doCommandBySelector:"), @ptrCast(@constCast(&tiDoCommand)), "v@::");
    objc.addMethod(class, objc.sel("setMarkedText:selectedRange:replacementRange:"), @ptrCast(@constCast(&tiSetMarkedText)), "v@:@{_NSRange=QQ}{_NSRange=QQ}");
    objc.addMethod(class, objc.sel("unmarkText"), @ptrCast(@constCast(&tiUnmarkText)), "v@:");
    objc.addMethod(class, objc.sel("hasMarkedText"), @ptrCast(@constCast(&tiHasMarkedText)), "c@:");
    objc.addMethod(class, objc.sel("markedRange"), @ptrCast(@constCast(&tiMarkedRange)), "{_NSRange=QQ}@:");
    objc.addMethod(class, objc.sel("selectedRange"), @ptrCast(@constCast(&tiSelectedRange)), "{_NSRange=QQ}@:");
    objc.addMethod(class, objc.sel("attributedSubstringForProposedRange:actualRange:"), @ptrCast(@constCast(&tiAttributedSubstring)), "@@:{_NSRange=QQ}^{_NSRange=QQ}");
    objc.addMethod(class, objc.sel("validAttributesForMarkedText"), @ptrCast(@constCast(&tiValidAttributes)), "@@:");
    objc.addMethod(class, objc.sel("firstRectForCharacterRange:actualRange:"), @ptrCast(@constCast(&tiFirstRect)), "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}");
    objc.addMethod(class, objc.sel("characterIndexForPoint:"), @ptrCast(@constCast(&tiCharIndex)), "Q@:{CGPoint=dd}");

    objc.registerClass(class);
    return class;
}

fn viewAcceptsFirstResponder(_: objc.Id, _: objc.Sel) callconv(.c) objc.BOOL {
    return 1;
}

fn viewIsOpaque(_: objc.Id, _: objc.Sel) callconv(.c) objc.BOOL {
    return 1;
}

fn sessionRowMouseEntered(self: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    const tag = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(
        self,
        objc.sel("tag"),
    );
    if (tag < 1) return;
    app.hovered_session_index = @intCast(tag - 1);
    refreshSidebar();
}

fn sessionRowMouseExited(self: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    const tag = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(
        self,
        objc.sel("tag"),
    );
    if (tag < 1 or app.hovered_session_index != @as(usize, @intCast(tag - 1))) return;
    app.hovered_session_index = null;
    refreshSidebar();
}

fn pairSegmentMouseEntered(self: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    const tag = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(self, objc.sel("tag"));
    if (tag < 1) return;
    app.hovered_pair_member_id = @intCast(tag);
    refreshSidebar();
}

fn pairSegmentMouseExited(self: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    const tag = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(self, objc.sel("tag"));
    if (tag < 1 or app.hovered_pair_member_id != @as(u64, @intCast(tag))) return;
    app.hovered_pair_member_id = null;
    refreshSidebar();
}

fn prepareSidebarDragSource(source: objc.Id) bool {
    app.dragged_display_index = null;
    app.dragged_pair_member_id = null;
    app.sidebar_drop = .none;
    const tag = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(source, objc.sel("tag"));
    if (tag < 1) return false;
    const is_segment = objc.msg(*const fn (objc.Id, objc.Sel, objc.Class) callconv(.c) objc.BOOL)(
        source,
        objc.sel("isKindOfClass:"),
        app.pair_segment_class,
    ) != 0;
    if (is_segment) {
        const member_id: u64 = @intCast(tag);
        const index = display_model.itemIndex(app.display_items.items, member_id) orelse return false;
        switch (app.display_items.items[index]) {
            .single => return false,
            .pair => {},
        }
        app.dragged_display_index = index;
        app.dragged_pair_member_id = member_id;
        return true;
    }
    const index: usize = @intCast(tag - 1);
    if (index >= app.display_items.items.len) return false;
    app.dragged_display_index = index;
    return true;
}

fn sidebarDraggableMouseDown(self: objc.Id, _: objc.Sel, mouse_down: objc.Id) callconv(.c) void {
    const initial = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGPoint)(
        mouse_down,
        objc.sel("locationInWindow"),
    );
    const click_count = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(
        mouse_down,
        objc.sel("clickCount"),
    );
    const ns_app = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSApplication"),
        objc.sel("sharedApplication"),
    );
    const distant_future = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSDate"),
        objc.sel("distantFuture"),
    );
    const tracking_mode = objc.nsString("NSEventTrackingRunLoopMode");
    const drag_mask: objc.NSUInteger = (@as(objc.NSUInteger, 1) << 2) | (@as(objc.NSUInteger, 1) << 6);

    while (true) {
        const next = objc.msg(
            *const fn (objc.Id, objc.Sel, objc.NSUInteger, objc.Id, objc.Id, objc.BOOL) callconv(.c) objc.Id,
        )(
            ns_app,
            objc.sel("nextEventMatchingMask:untilDate:inMode:dequeue:"),
            drag_mask,
            distant_future,
            tracking_mode,
            1,
        );
        if (next == null) return;
        const event_type = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(
            next,
            objc.sel("type"),
        );
        if (event_type == 2) { // NSEventTypeLeftMouseUp
            const is_segment = objc.msg(*const fn (objc.Id, objc.Sel, objc.Class) callconv(.c) objc.BOOL)(
                self,
                objc.sel("isKindOfClass:"),
                app.pair_segment_class,
            ) != 0;
            if (click_count >= 2 and is_segment) {
                const tag = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(
                    self,
                    objc.sel("tag"),
                );
                if (tag >= 1) zoomPairMember(@intCast(tag));
                return;
            }
            objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
                self,
                objc.sel("performClick:"),
                self,
            );
            return;
        }
        if (event_type != 6) continue; // NSEventTypeLeftMouseDragged
        const point = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGPoint)(
            next,
            objc.sel("locationInWindow"),
        );
        const dx = point.x - initial.x;
        const dy = point.y - initial.y;
        if (dx * dx + dy * dy < 16) continue;
        if (!prepareSidebarDragSource(self) or !beginSidebarNativeDrag(self, mouse_down)) {
            clearSessionRowDrag();
            NSBeep();
        }
        return;
    }
}

fn sidebarDragOperationMask(_: objc.Id, _: objc.Sel, _: objc.Id, _: objc.NSInteger) callconv(.c) objc.NSUInteger {
    return ns_drag_operation_move;
}

fn sidebarDragIgnoresModifiers(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) objc.BOOL {
    return 1;
}

fn sidebarDragEnded(
    source: objc.Id,
    _: objc.Sel,
    _: objc.Id,
    _: objc.CGPoint,
    _: objc.NSUInteger,
) callconv(.c) void {
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat) callconv(.c) void)(
        source,
        objc.sel("setAlphaValue:"),
        1,
    );
    clearSessionRowDrag();
}

fn sidebarDragImage(source: objc.Id) ?objc.Id {
    const bounds = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGRect)(source, objc.sel("bounds"));
    const rep = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect) callconv(.c) objc.Id)(
        source,
        objc.sel("bitmapImageRepForCachingDisplayInRect:"),
        bounds,
    );
    if (rep == null) return null;
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect, objc.Id) callconv(.c) void)(
        source,
        objc.sel("cacheDisplayInRect:toBitmapImageRep:"),
        bounds,
        rep,
    );
    const image_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSImage"),
        objc.sel("alloc"),
    );
    const image = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGSize) callconv(.c) objc.Id)(
        image_alloc,
        objc.sel("initWithSize:"),
        bounds.size,
    );
    if (image == null) return null;
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        image,
        objc.sel("addRepresentation:"),
        rep,
    );
    return image;
}

fn beginSidebarNativeDrag(source: objc.Id, event: objc.Id) bool {
    const image = sidebarDragImage(source) orelse return false;
    defer objc.release(image);

    const pasteboard_item = objc.allocInit(objc.cls("NSPasteboardItem"));
    if (pasteboard_item == null) return false;
    defer objc.release(pasteboard_item);
    _ = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id, objc.Id) callconv(.c) objc.BOOL)(
        pasteboard_item,
        objc.sel("setString:forType:"),
        objc.nsString("session"),
        objc.nsString(sidebar_drag_type),
    );
    const dragging_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSDraggingItem"),
        objc.sel("alloc"),
    );
    const dragging_item = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        dragging_alloc,
        objc.sel("initWithPasteboardWriter:"),
        pasteboard_item,
    );
    if (dragging_item == null) return false;
    defer objc.release(dragging_item);
    const bounds = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGRect)(source, objc.sel("bounds"));
    const frame = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect, objc.Id) callconv(.c) objc.CGRect)(
        source,
        objc.sel("convertRect:toView:"),
        bounds,
        app.sidebar_document,
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect, objc.Id) callconv(.c) void)(
        dragging_item,
        objc.sel("setDraggingFrame:contents:"),
        frame,
        image,
    );
    const items = objc.msg(*const fn (objc.Class, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        objc.cls("NSArray"),
        objc.sel("arrayWithObject:"),
        dragging_item,
    );
    const session = objc.msg(
        *const fn (objc.Id, objc.Sel, objc.Id, objc.Id, objc.Id) callconv(.c) objc.Id,
    )(
        app.sidebar_document,
        objc.sel("beginDraggingSessionWithItems:event:source:"),
        items,
        event,
        source,
    );
    if (session == null) return false;
    objc.setU(session, objc.sel("setAnimatesToStartingPositionsOnCancelOrFail:"), 1);
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat) callconv(.c) void)(
        source,
        objc.sel("setAlphaValue:"),
        0.35,
    );
    return true;
}

fn singleSessionIdAtDisplayIndex(index: usize) ?u64 {
    if (index >= app.display_items.items.len) return null;
    return switch (app.display_items.items[index]) {
        .single => |id| id,
        .pair => null,
    };
}

fn pairDropAvailable() bool {
    const metrics = app.renderer.cellMetrics();
    return display_model.pairGeometry(
        app.view_size[0],
        app.view_size[1],
        display_registry.default_ratio,
        metrics.cell_width,
        metrics.cell_height,
    ) != null;
}

const SidebarHit = union(enum) {
    insertion: usize,
    row: struct { index: usize, on_left: bool, upper_half: bool },
};

fn sidebarHit(point: objc.CGPoint) SidebarHit {
    const count = app.display_items.items.len;
    if (count == 0) return .{ .insertion = 0 };
    const y: f32 = @floatCast(point.y);
    if (y <= sidebar_layout.rowY(0)) return .{ .insertion = 0 };
    const last_bottom = sidebar_layout.rowY(count - 1) + sidebar_row_height;
    if (y >= last_bottom) return .{ .insertion = count };

    const raw = @max(0, y - sidebar_layout.top_padding) / sidebar_layout.row_pitch;
    const index = @min(count - 1, @as(usize, @intFromFloat(@floor(raw))));
    const local_y = y - sidebar_layout.rowY(index);
    const edge: f32 = 6;
    if (local_y < edge) return .{ .insertion = index };
    if (local_y > sidebar_row_height - edge) return .{ .insertion = index + 1 };
    const frame = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGRect)(
        app.session_buttons.items[index],
        objc.sel("frame"),
    );
    const x: f32 = @floatCast(point.x);
    return .{ .row = .{
        .index = index,
        .on_left = x < @as(f32, @floatCast(frame.origin.x + frame.size.width / 2)),
        .upper_half = local_y < sidebar_row_height / 2,
    } };
}

fn sidebarDropProposal(point: objc.CGPoint) SidebarDrop {
    const source_index = app.dragged_display_index orelse return .none;
    if (source_index >= app.display_items.items.len) return .none;
    const hit = sidebarHit(point);
    if (app.dragged_pair_member_id) |member_id| return switch (hit) {
        .insertion => |boundary| .{ .extract = boundary },
        .row => |row| blk: {
            if (row.index == source_index) {
                const pair = switch (app.display_items.items[source_index]) {
                    .single => break :blk .none,
                    .pair => |value| value,
                };
                const crosses_sibling = (pair.left == member_id and !row.on_left) or
                    (pair.right == member_id and row.on_left);
                break :blk if (crosses_sibling) .swap else .none;
            }
            const target = switch (app.display_items.items[row.index]) {
                .single => |id| id,
                .pair => break :blk .none,
            };
            if (!pairDropAvailable()) break :blk .none;
            break :blk .{ .transfer = .{ .target_id = target, .member_on_left = row.on_left } };
        },
    };

    return switch (hit) {
        .insertion => |boundary| if (display_model.moveDestination(
            source_index,
            boundary,
            app.display_items.items.len,
        )) |destination| .{ .reorder = destination } else .none,
        .row => |row| blk: {
            if (row.index == source_index) break :blk .none;
            const source_id = switch (app.display_items.items[source_index]) {
                .single => |id| id,
                .pair => {
                    const boundary = row.index + @intFromBool(!row.upper_half);
                    break :blk if (display_model.moveDestination(
                        source_index,
                        boundary,
                        app.display_items.items.len,
                    )) |destination| .{ .reorder = destination } else .none;
                },
            };
            const target_id = switch (app.display_items.items[row.index]) {
                .single => |id| id,
                .pair => {
                    const boundary = row.index + @intFromBool(!row.upper_half);
                    break :blk if (display_model.moveDestination(
                        source_index,
                        boundary,
                        app.display_items.items.len,
                    )) |destination| .{ .reorder = destination } else .none;
                },
            };
            if (!pairDropAvailable()) break :blk .none;
            _ = source_id;
            break :blk .{ .pair = .{ .target_id = target_id, .source_on_left = row.on_left } };
        },
    };
}

fn updateSidebarDropIndicator(drop: SidebarDrop) void {
    const layer = app.sidebar_drop_indicator;
    if (layer == null) return;
    const bounds = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGRect)(
        app.sidebar_document,
        objc.sel("bounds"),
    );
    var frame: objc.CGRect = undefined;
    switch (drop) {
        .none => return objc.setU(layer, objc.sel("setHidden:"), 1),
        .reorder => |destination| {
            const source = app.dragged_display_index orelse return;
            const boundary = if (destination > source) destination + 1 else destination;
            const y = if (boundary >= app.display_items.items.len)
                sidebar_layout.rowY(app.display_items.items.len - 1) + sidebar_row_height + 1
            else
                sidebar_layout.rowY(boundary) - 2;
            frame = .{
                .origin = .{ .x = sidebar_horizontal_padding, .y = y },
                .size = .{ .width = bounds.size.width - 2 * sidebar_horizontal_padding, .height = 3 },
            };
        },
        .extract => |boundary| {
            const y = if (boundary >= app.display_items.items.len)
                sidebar_layout.rowY(app.display_items.items.len - 1) + sidebar_row_height + 1
            else
                sidebar_layout.rowY(boundary) - 2;
            frame = .{
                .origin = .{ .x = sidebar_horizontal_padding, .y = y },
                .size = .{ .width = bounds.size.width - 2 * sidebar_horizontal_padding, .height = 3 },
            };
        },
        .pair => |pair_drop| {
            const index = display_model.itemIndex(app.display_items.items, pair_drop.target_id) orelse return;
            const row = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGRect)(
                app.session_buttons.items[index],
                objc.sel("frame"),
            );
            frame = .{
                .origin = .{ .x = row.origin.x + (if (pair_drop.source_on_left) 0 else row.size.width / 2), .y = row.origin.y },
                .size = .{ .width = row.size.width / 2, .height = row.size.height },
            };
        },
        .transfer => |transfer| {
            const index = display_model.itemIndex(app.display_items.items, transfer.target_id) orelse return;
            const row = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGRect)(
                app.session_buttons.items[index],
                objc.sel("frame"),
            );
            frame = .{
                .origin = .{ .x = row.origin.x + (if (transfer.member_on_left) 0 else row.size.width / 2), .y = row.origin.y },
                .size = .{ .width = row.size.width / 2, .height = row.size.height },
            };
        },
        .swap => {
            const source = app.dragged_display_index orelse return;
            const row = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGRect)(
                app.session_buttons.items[source],
                objc.sel("frame"),
            );
            const pair = app.display_items.items[source].pair;
            const member = app.dragged_pair_member_id orelse return;
            const target_left = pair.right == member;
            frame = .{
                .origin = .{ .x = row.origin.x + (if (target_left) 0 else row.size.width / 2), .y = row.origin.y },
                .size = .{ .width = row.size.width / 2, .height = row.size.height },
            };
        },
    }
    setViewFrame(layer, frame);
    objc.setU(layer, objc.sel("setHidden:"), 0);
}

fn sidebarDraggingUpdated(_: objc.Id, _: objc.Sel, info: objc.Id) callconv(.c) objc.NSUInteger {
    if (app.dragged_display_index == null) return ns_drag_operation_none;
    const window_point = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGPoint)(
        info,
        objc.sel("draggingLocation"),
    );
    const point = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGPoint, objc.Id) callconv(.c) objc.CGPoint)(
        app.sidebar_document,
        objc.sel("convertPoint:fromView:"),
        window_point,
        null,
    );
    app.sidebar_drop = sidebarDropProposal(point);
    updateSidebarDropIndicator(app.sidebar_drop);
    return switch (app.sidebar_drop) {
        .none => ns_drag_operation_none,
        else => ns_drag_operation_move,
    };
}

fn sidebarDraggingExited(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    app.sidebar_drop = .none;
    updateSidebarDropIndicator(.none);
}

fn sidebarPrepareDrag(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) objc.BOOL {
    return @intFromBool(switch (app.sidebar_drop) {
        .none => false,
        else => true,
    });
}

fn sidebarPerformDrag(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) objc.BOOL {
    const source_index = app.dragged_display_index orelse return 0;
    if (source_index >= app.display_items.items.len) return 0;
    const active_id = activeSession().id;
    const source_id = display_model.focusedId(app.display_items.items[source_index]);
    const succeeded = switch (app.sidebar_drop) {
        .none => false,
        .reorder => |destination| blk: {
            app.client.moveDisplayItem(source_id, @intCast(destination)) catch break :blk false;
            break :blk true;
        },
        .pair => |pair_drop| blk: {
            const single_source = singleSessionIdAtDisplayIndex(source_index) orelse break :blk false;
            const left = if (pair_drop.source_on_left) single_source else pair_drop.target_id;
            const right = if (pair_drop.source_on_left) pair_drop.target_id else single_source;
            app.client.pairSessions(left, right) catch break :blk false;
            break :blk true;
        },
        .swap => blk: {
            const member = app.dragged_pair_member_id orelse break :blk false;
            app.client.swapPairSides(member) catch break :blk false;
            break :blk true;
        },
        .extract => |destination| blk: {
            const member = app.dragged_pair_member_id orelse break :blk false;
            app.client.extractPairMember(member, @intCast(destination)) catch break :blk false;
            break :blk true;
        },
        .transfer => |transfer| blk: {
            const member = app.dragged_pair_member_id orelse break :blk false;
            app.client.transferPairMember(member, transfer.target_id, transfer.member_on_left) catch break :blk false;
            break :blk true;
        },
    };
    if (!succeeded) return 0;
    app.display_registry_dirty.store(true, .release);
    syncDisplayRegistry();
    _ = selectSessionId(active_id);
    activateSelectedSession();
    return 1;
}

fn clearSessionRowDrag() void {
    app.dragged_display_index = null;
    app.dragged_pair_member_id = null;
    app.sidebar_drop = .none;
    if (app.sidebar_drop_indicator != null) objc.setU(app.sidebar_drop_indicator, objc.sel("setHidden:"), 1);
    refreshSidebar();
}

fn viewFlagsChanged(_: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    const mods = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSUInteger)(
        event,
        objc.sel("modifierFlags"),
    );
    const show = mods & mod_command != 0;
    if (show != app.hyperlink_command_held) {
        app.hyperlink_command_held = show;
        if (show) updateHyperlinkHover(event) else clearHyperlinkHover();
    }
    if (show != app.show_session_shortcuts) {
        app.show_session_shortcuts = show;
        if (show) startShortcutHintTimer() else stopShortcutHintTimer();
        refreshSidebar();
    }

    if (app.preedit.active()) return;
    const key_code = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) u16)(
        event,
        objc.sel("keyCode"),
    );
    const code = input.modifierFromKeyCode(key_code) orelse return;
    const generic_mask: objc.NSUInteger = switch (code) {
        .caps_lock => mod_caps_lock,
        .left_shift, .right_shift => mod_shift,
        .left_control, .right_control => mod_control,
        .left_alt, .right_alt => mod_option,
        .left_super, .right_super => mod_command,
        else => return,
    };
    var pressed = mods & generic_mask != 0;
    const right_device_mask: objc.NSUInteger = switch (code) {
        .right_shift => 0x00000004,
        .right_super => 0x00000010,
        .right_alt => 0x00000040,
        .right_control => 0x00002000,
        else => 0,
    };
    if (pressed and right_device_mask != 0) pressed = mods & right_device_mask != 0;
    if (key_normalizer.normalizeModifier(key_code, keyModifiers(mods), pressed)) |key_event|
        ptyKey(key_event);
}

fn startShortcutHintTimer() void {
    if (app.shortcut_hint_timer != null) return;
    const timer = objc.msg(
        *const fn (objc.Class, objc.Sel, objc.CGFloat, objc.Id, objc.Sel, objc.Id, objc.BOOL) callconv(.c) objc.Id,
    )(
        objc.cls("NSTimer"),
        objc.sel("timerWithTimeInterval:target:selector:userInfo:repeats:"),
        0.05,
        app.view,
        objc.sel("shortcutHintTick:"),
        null,
        1,
    );
    if (timer == null) return;
    app.shortcut_hint_timer = timer;
    const run_loop = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSRunLoop"),
        objc.sel("mainRunLoop"),
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id, objc.Id) callconv(.c) void)(
        run_loop,
        objc.sel("addTimer:forMode:"),
        timer,
        ns_run_loop_common_modes.*,
    );
}

fn stopShortcutHintTimer() void {
    if (app.shortcut_hint_timer) |timer| {
        objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(timer, objc.sel("invalidate"));
        app.shortcut_hint_timer = null;
    }
}

fn shortcutHintTick(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    if (CGEventSourceFlagsState(0) & mod_command != 0) return;
    stopShortcutHintTimer();
    if (app.hyperlink_command_held) {
        app.hyperlink_command_held = false;
        clearHyperlinkHover();
    }
    if (!app.show_session_shortcuts) return;
    app.show_session_shortcuts = false;
    refreshSidebar();
}

fn viewNewSession(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    createSession();
    _ = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.BOOL)(
        app.window,
        objc.sel("makeFirstResponder:"),
        app.view,
    );
}

fn viewNewSessionBeside(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    createSessionBeside();
    _ = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.BOOL)(
        app.window,
        objc.sel("makeFirstResponder:"),
        app.view,
    );
}

fn viewClearSession(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    clearActiveSession();
}

fn viewCloseSession(_: objc.Id, _: objc.Sel, sender: objc.Id) callconv(.c) void {
    const tag = if (sender == null)
        0
    else
        objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(
            sender,
            objc.sel("tag"),
        );
    if (tag >= 1) {
        const display_index: usize = @intCast(tag - 1);
        if (display_index >= app.display_items.items.len) return;
        const id = display_model.focusedId(app.display_items.items[display_index]);
        const session_index = sessionIndexById(id) orelse return;
        closeSession(session_index);
    } else {
        closeSession(app.sessions.active_index);
    }
}

fn viewClosePairMember(_: objc.Id, _: objc.Sel, sender: objc.Id) callconv(.c) void {
    const tag = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(
        sender,
        objc.sel("tag"),
    );
    if (tag < 1) return;
    const index = sessionIndexById(@intCast(tag)) orelse return;
    closeSession(index);
}

fn viewSelectSession(_: objc.Id, _: objc.Sel, sender: objc.Id) callconv(.c) void {
    const tag = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(
        sender,
        objc.sel("tag"),
    );
    if (tag < 1) return;
    selectDisplayItem(@intCast(tag - 1));
    _ = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.BOOL)(
        app.window,
        objc.sel("makeFirstResponder:"),
        app.view,
    );
}

fn viewSelectNumberedSession(_: objc.Id, _: objc.Sel, sender: objc.Id) callconv(.c) void {
    const tag = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(
        sender,
        objc.sel("tag"),
    );
    if (tag < 1) return;
    const id = display_model.sessionIdAtVisualIndex(
        app.display_items.items,
        @intCast(tag - 1),
    ) orelse return;
    if (!selectSessionAndRememberPair(id)) return NSBeep();
    activateSelectedSession();
    _ = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.BOOL)(
        app.window,
        objc.sel("makeFirstResponder:"),
        app.view,
    );
}

fn viewSelectPairMember(_: objc.Id, _: objc.Sel, sender: objc.Id) callconv(.c) void {
    const tag = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(
        sender,
        objc.sel("tag"),
    );
    if (tag < 1) return;
    const id: u64 = @intCast(tag);
    if (!selectSessionAndRememberPair(id)) return NSBeep();
    activateSelectedSession();
    _ = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.BOOL)(
        app.window,
        objc.sel("makeFirstResponder:"),
        app.view,
    );
}

fn viewNextSession(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    selectNextSession();
}

fn viewPreviousSession(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    selectPreviousSession();
}

fn viewPairWithPreviousSession(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    pairActiveSession(.previous);
}

fn viewPairWithNextSession(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    pairActiveSession(.next);
}

fn viewSeparateSessions(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    separateActiveSessions();
}

fn viewSeparateDisplayItem(_: objc.Id, _: objc.Sel, sender: objc.Id) callconv(.c) void {
    const tag = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(
        sender,
        objc.sel("tag"),
    );
    if (tag < 1) return;
    const index: usize = @intCast(tag - 1);
    if (index >= app.display_items.items.len) return;
    const pair = switch (app.display_items.items[index]) {
        .single => return,
        .pair => |value| value,
    };
    const active_id = activeSession().id;
    app.client.separateSessions(pair.focusedId()) catch return NSBeep();
    app.display_registry_dirty.store(true, .release);
    syncDisplayRegistry();
    _ = selectSessionId(active_id);
    activateSelectedSession();
}

fn swapDisplayItem(index: usize) void {
    if (index >= app.display_items.items.len) return;
    const pair = switch (app.display_items.items[index]) {
        .single => return,
        .pair => |value| value,
    };
    const active_id = activeSession().id;
    app.client.swapPairSides(pair.focusedId()) catch return NSBeep();
    app.display_registry_dirty.store(true, .release);
    syncDisplayRegistry();
    _ = selectSessionId(active_id);
    activateSelectedSession();
}

fn focusActivePairSide(side: daemon_protocol.FocusedMember) void {
    const index = activeDisplayIndex() orelse return NSBeep();
    const pair = switch (app.display_items.items[index]) {
        .single => return NSBeep(),
        .pair => |value| value,
    };
    const id = switch (side) {
        .left => pair.left,
        .right => pair.right,
    };
    if (id == activeSession().id) return;
    if (!selectSessionAndRememberPair(id)) return NSBeep();
    activateSelectedSession();
}

fn moveActivePairMemberTo(side: daemon_protocol.FocusedMember) void {
    const index = activeDisplayIndex() orelse return NSBeep();
    const pair = switch (app.display_items.items[index]) {
        .single => return NSBeep(),
        .pair => |value| value,
    };
    const already_on_side = switch (side) {
        .left => pair.left == activeSession().id,
        .right => pair.right == activeSession().id,
    };
    if (already_on_side) return;
    swapDisplayItem(index);
}

fn zoomPairMember(member_id: u64) void {
    const index = display_model.itemIndex(app.display_items.items, member_id) orelse return NSBeep();
    switch (app.display_items.items[index]) {
        .single => return NSBeep(),
        .pair => {},
    }
    if (!app.client.supportsPersistentPairZoom()) return NSBeep();
    app.client.setPairZoom(member_id, true) catch return NSBeep();
    app.display_registry_dirty.store(true, .release);
    syncDisplayRegistry();
    if (!selectSessionId(member_id)) return NSBeep();
    activateSelectedSession();
}

fn toggleDisplayItemZoom(index: usize) void {
    if (index >= app.display_items.items.len) return NSBeep();
    const pair = switch (app.display_items.items[index]) {
        .single => return NSBeep(),
        .pair => |value| value,
    };
    if (!app.client.supportsPersistentPairZoom()) return NSBeep();
    app.client.setPairZoom(pair.focusedId(), !pair.zoomed) catch return NSBeep();
    app.display_registry_dirty.store(true, .release);
    syncDisplayRegistry();
    if (activeSession().id != pair.left and activeSession().id != pair.right)
        _ = selectSessionId(pair.focusedId());
    activateSelectedSession();
}

fn viewSwapSessionSides(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    swapDisplayItem(activeDisplayIndex() orelse return NSBeep());
}

fn viewSwapDisplayItemSides(_: objc.Id, _: objc.Sel, sender: objc.Id) callconv(.c) void {
    const tag = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(sender, objc.sel("tag"));
    if (tag < 1) return;
    swapDisplayItem(@intCast(tag - 1));
}

fn viewFocusLeftPane(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    focusActivePairSide(.left);
}

fn viewFocusRightPane(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    focusActivePairSide(.right);
}

fn viewMovePaneLeft(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    moveActivePairMemberTo(.left);
}

fn viewMovePaneRight(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    moveActivePairMemberTo(.right);
}

fn focusAdjacentSessionGroup(direction: display_model.Direction) void {
    const id = display_model.adjacentDisplayItemId(
        app.display_items.items,
        activeSession().id,
        direction,
    ) orelse return NSBeep();
    if (!selectSessionId(id)) return NSBeep();
    activateSelectedSession();
}

fn moveActiveSessionGroup(direction: display_model.Direction) void {
    const active_id = activeSession().id;
    const destination = display_model.adjacentDisplayItemDestination(
        app.display_items.items,
        active_id,
        direction,
    ) orelse return NSBeep();
    app.client.moveDisplayItem(active_id, @intCast(destination)) catch return NSBeep();
    app.display_registry_dirty.store(true, .release);
    syncDisplayRegistry();
    _ = selectSessionId(active_id);
    activateSelectedSession();
}

fn viewFocusPreviousSessionGroup(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    focusAdjacentSessionGroup(.previous);
}

fn viewFocusNextSessionGroup(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    focusAdjacentSessionGroup(.next);
}

fn viewMoveSessionGroupUp(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    moveActiveSessionGroup(.previous);
}

fn viewMoveSessionGroupDown(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    moveActiveSessionGroup(.next);
}

fn viewTogglePairZoom(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    toggleDisplayItemZoom(activeDisplayIndex() orelse return NSBeep());
}

fn viewToggleDisplayItemZoom(_: objc.Id, _: objc.Sel, sender: objc.Id) callconv(.c) void {
    const tag = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(sender, objc.sel("tag"));
    if (tag < 1) return;
    toggleDisplayItemZoom(@intCast(tag - 1));
}

fn viewValidateMenuItem(_: objc.Id, _: objc.Sel, item: objc.Id) callconv(.c) objc.BOOL {
    const action = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Sel)(item, objc.sel("action"));
    if (action == objc.sel("showFind:") or action == objc.sel("findNext:") or
        action == objc.sel("findPrevious:"))
        return @intFromBool(app.client.supportsSearch());
    if (action == objc.sel("newSessionBeside:")) {
        return @intFromBool(canCreateSessionBeside());
    }
    if (action == objc.sel("pairWithPreviousSession:") or action == objc.sel("pairWithNextSession:")) {
        const index = activeDisplayIndex() orelse return 0;
        const direction: display_model.Direction = if (action == objc.sel("pairWithPreviousSession:"))
            .previous
        else
            .next;
        if (display_model.pairCandidate(app.display_items.items, index, direction) == null) return 0;
        const metrics = app.renderer.cellMetrics();
        return @intFromBool(display_model.pairGeometry(
            app.view_size[0],
            app.view_size[1],
            display_registry.default_ratio,
            metrics.cell_width,
            metrics.cell_height,
        ) != null);
    }
    if (action == objc.sel("separateSessions:") or action == objc.sel("swapSessionSides:")) {
        const index = activeDisplayIndex() orelse return 0;
        return switch (app.display_items.items[index]) {
            .single => 0,
            .pair => 1,
        };
    }
    if (action == objc.sel("focusLeftPane:") or action == objc.sel("focusRightPane:") or
        action == objc.sel("movePaneLeft:") or action == objc.sel("movePaneRight:") or
        action == objc.sel("togglePairZoom:"))
    {
        const index = activeDisplayIndex() orelse return 0;
        const pair = switch (app.display_items.items[index]) {
            .single => return 0,
            .pair => |value| value,
        };
        if (action == objc.sel("togglePairZoom:")) {
            objc.setId(
                item,
                objc.sel("setTitle:"),
                objc.nsString(if (zoomedPairMember(pair) != null) "Show Both Panes" else "Zoom Focused Pane"),
            );
            return @intFromBool(app.client.supportsPersistentPairZoom());
        }
        return 1;
    }
    if (action == objc.sel("focusPreviousSessionGroup:") or action == objc.sel("moveSessionGroupUp:") or
        action == objc.sel("focusNextSessionGroup:") or action == objc.sel("moveSessionGroupDown:"))
    {
        const direction: display_model.Direction = if (action == objc.sel("focusPreviousSessionGroup:") or action == objc.sel("moveSessionGroupUp:")) .previous else .next;
        return @intFromBool(display_model.adjacentDisplayItemDestination(
            app.display_items.items,
            activeSession().id,
            direction,
        ) != null);
    }
    if (action == objc.sel("toggleDisplayItemZoom:")) {
        if (!app.client.supportsPersistentPairZoom()) return 0;
        const tag = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(item, objc.sel("tag"));
        if (tag < 1) return 0;
        const index: usize = @intCast(tag - 1);
        if (index >= app.display_items.items.len) return 0;
        return switch (app.display_items.items[index]) {
            .single => 0,
            .pair => 1,
        };
    }
    if (action == objc.sel("increaseFontSize:"))
        return @intFromBool(effectiveFontSize() < config_mod.max_font_size);
    if (action == objc.sel("decreaseFontSize:"))
        return @intFromBool(effectiveFontSize() > config_mod.min_font_size);
    if (action == objc.sel("resetFontSize:"))
        return @intFromBool(app.font_zoom.isOverridden());
    return 1;
}

fn viewToggleSessionBar(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    toggleSessionBar();
}

fn viewIncreaseFontSize(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    adjustTemporaryFontSize(1);
}

fn viewDecreaseFontSize(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    adjustTemporaryFontSize(-1);
}

fn viewResetFontSize(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    setTemporaryFontSize(null);
}

fn viewOpenConfiguration(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    config_mod.ensureFile(app.io, app.config_directory, app.config_path) catch |err| {
        std.log.err("could not create configuration file: {s}", .{@errorName(err)});
        NSBeep();
        return;
    };

    const path_z = app.gpa.dupeZ(u8, app.config_path) catch {
        NSBeep();
        return;
    };
    defer app.gpa.free(path_z);
    const path_string = objc.nsString(path_z.ptr);
    if (path_string == null) {
        NSBeep();
        return;
    }
    const url = objc.msg(*const fn (objc.Class, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        objc.cls("NSURL"),
        objc.sel("fileURLWithPath:"),
        path_string,
    );
    const workspace = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSWorkspace"),
        objc.sel("sharedWorkspace"),
    );
    if (url == null or workspace == null) {
        NSBeep();
        return;
    }
    const editor_url = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        workspace,
        objc.sel("URLForApplicationToOpenContentType:"),
        ut_type_plain_text.*,
    );
    if (editor_url == null) {
        std.log.err("no default plain-text application is available", .{});
        NSBeep();
        return;
    }
    const urls = objc.msg(*const fn (objc.Class, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        objc.cls("NSArray"),
        objc.sel("arrayWithObject:"),
        url,
    );
    const configuration = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSWorkspaceOpenConfiguration"),
        objc.sel("configuration"),
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id, objc.Id, objc.Id, objc.Id) callconv(.c) void)(
        workspace,
        objc.sel("openURLs:withApplicationAtURL:configuration:completionHandler:"),
        urls,
        editor_url,
        configuration,
        null,
    );
}

fn viewShowBackgroundServiceUpdate(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    const identity = app.client.daemonIdentity();
    const running = identity.versionText() orelse "Earlier version";
    const informative = std.fmt.allocPrint(
        app.gpa,
        "The background service is still running Boring Terminal {s} (attach dialect {d}). " ++
            "Boring Terminal {s} is using compatibility mode so your {d} session{s} can remain open.",
        .{
            running,
            app.client.attachDialect(),
            product_version.semantic,
            app.sessions.sessions.items.len,
            if (app.sessions.sessions.items.len == 1) "" else "s",
        },
    ) catch return NSBeep();
    defer app.gpa.free(informative);

    const alert = objc.allocInit(objc.cls("NSAlert"));
    if (alert == null) return NSBeep();
    defer objc.release(alert);
    const ns_informative = objc.nsStringFromBytes(informative);
    defer objc.release(ns_informative);
    objc.setId(alert, objc.sel("setMessageText:"), objc.nsString("Background Service Update Pending"));
    objc.setId(alert, objc.sel("setInformativeText:"), ns_informative);
    _ = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        alert,
        objc.sel("addButtonWithTitle:"),
        objc.nsString("Keep Sessions"),
    );
    _ = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        alert,
        objc.sel("addButtonWithTitle:"),
        objc.nsString("Restart and Close Sessions…"),
    );
    const response = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(
        alert,
        objc.sel("runModal"),
    );
    if (response != 1001) return;

    const confirmation = std.fmt.allocPrint(
        app.gpa,
        "This will close {d} session{s}, update the background service, and reopen Boring Terminal.",
        .{
            app.sessions.sessions.items.len,
            if (app.sessions.sessions.items.len == 1) "" else "s",
        },
    ) catch return NSBeep();
    defer app.gpa.free(confirmation);
    if (!runDestructiveConfirmation(
        "Restart the background service?",
        confirmation,
        "Restart and Close Sessions",
    )) return;

    if (identity.lifecycle_supported) {
        app.client.terminateDaemon() catch return NSBeep();
    } else {
        app.client.terminateVerifiedLegacyDaemon() catch return NSBeep();
    }
    relaunchCurrentApplication() catch return NSBeep();
    const ns_app = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSApplication"),
        objc.sel("sharedApplication"),
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        ns_app,
        objc.sel("terminate:"),
        null,
    );
}

fn relaunchCurrentApplication() !void {
    const executable_dir = try std.process.executableDirPathAlloc(app.io, app.gpa);
    defer app.gpa.free(executable_dir);
    const contents_dir = std.fs.path.dirname(executable_dir) orelse return error.InvalidBundlePath;
    const bundle_path = std.fs.path.dirname(contents_dir) orelse return error.InvalidBundlePath;
    var opener = try std.process.spawn(app.io, .{
        .argv = &.{ "/usr/bin/open", "-n", bundle_path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = try opener.wait(app.io);
}

fn viewKeyDown(self: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    const mods = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSUInteger)(
        event,
        objc.sel("modifierFlags"),
    );
    if (mods & mod_command != 0) {
        // A disabled menu item does not consume its key equivalent. Preserve
        // the RFC 0014 feedback contract without allowing Command shortcuts
        // to leak into the PTY.
        if (mods & (mod_shift | mod_option | mod_control) == 0) {
            const chars = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
                event,
                objc.sel("charactersIgnoringModifiers"),
            );
            if (nsStringUtf8(chars)) |text| {
                if (std.ascii.eqlIgnoreCase(text, "d") and !canCreateSessionBeside()) NSBeep();
            }
        }
        // Claimed menu equivalents never arrive here. An unclaimed Command
        // combination remains a semantic key and the authoritative daemon
        // suppresses it unless Kitty report-all is active.
    }

    const repeat = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.BOOL)(
        event,
        objc.sel("isARepeat"),
    ) != 0;
    const action: vt.keyboard.Action = if (repeat) .repeat else .press;
    app.key_text.begin(app.preedit.active());
    defer app.key_text.end();

    // AppKit must see every non-menu event once. Its callbacks accumulate
    // committed text and update preedit; only after it returns do we decide
    // which semantic transaction to submit.
    const array = objc.msg(*const fn (objc.Class, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        objc.cls("NSArray"),
        objc.sel("arrayWithObject:"),
        event,
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        self,
        objc.sel("interpretKeyEvents:"),
        array,
    );

    const marked_before = app.key_text.marked_before;
    const marked_after = app.preedit.active();
    if (app.key_text.commit_count != 0) {
        const composing = marked_before or marked_after;
        var i: usize = 0;
        while (i < app.key_text.commit_count) : (i += 1) {
            const commit = app.key_text.commits[i];
            const text = app.key_text.text(commit);
            // Some input methods surface the command key as a single control
            // character while they are editing preedit. That byte belongs to
            // AppKit's composition state, not to the foreground program.
            if (composing and isSingleC0(text)) continue;
            sendReplacementBackspaces(commit.replacement_count);
            if (i == 0 and !marked_before) {
                if (nativeKeyEvent(event, action, text)) |key_event| {
                    ptyKey(key_event);
                    continue;
                }
            }
            ptyText(text);
        }
        // Arrow keys can both commit preedit and still represent navigation.
        // AppKit already accounts for plain Left during Korean composition;
        // the other directions, and modified Left, must be replayed once.
        if (marked_before and shouldReplayCommittedPreeditKey(event)) {
            if (nativeKeyEvent(event, action, "")) |key_event| ptyKey(key_event);
        }
        return;
    }

    // Keys owned by an active input method edit/cancel preedit; replaying
    // them would leak Escape/Backspace/arrows into the foreground program.
    if (marked_before or marked_after) return;
    if (nativeKeyEvent(event, action, "")) |key_event| ptyKey(key_event);
}

fn viewKeyUp(_: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    if (nativeKeyEvent(event, .release, "")) |key_event| ptyKey(key_event);
}

fn isSingleC0(text: []const u8) bool {
    return text.len == 1 and text[0] < 0x20;
}

/// Ghostty documents the same AppKit/Korean-IME exception in its MIT-licensed
/// macOS input path. Plain Left is deliberately excluded because the input
/// context has already left the caret in the correct position after commit.
fn shouldReplayCommittedPreeditKey(event: objc.Id) bool {
    const key_code = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) u16)(
        event,
        objc.sel("keyCode"),
    );
    return switch (key_code) {
        124, 125, 126 => true, // right, down, up
        123 => eventModifierFlags(event) & (mod_shift | mod_control | mod_option | mod_command) != 0,
        else => false,
    };
}

fn keyModifiers(flags: objc.NSUInteger) vt.keyboard.Modifiers {
    return .{
        .shift = flags & mod_shift != 0,
        .alt = flags & mod_option != 0,
        .control = flags & mod_control != 0,
        .super = flags & mod_command != 0,
        .caps_lock = flags & mod_caps_lock != 0,
    };
}

fn singleScalar(text: []const u8) ?u21 {
    if (text.len == 0) return null;
    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch return null;
    if (len != text.len) return null;
    return std.unicode.utf8Decode(text) catch null;
}

fn eventScalar(event: objc.Id, modifiers: objc.NSUInteger) ?u21 {
    const string = objc.msg(*const fn (objc.Id, objc.Sel, objc.NSUInteger) callconv(.c) objc.Id)(
        event,
        objc.sel("charactersByApplyingModifiers:"),
        modifiers,
    );
    return singleScalar(nsStringUtf8(string) orelse return null);
}

fn nativeKeyEvent(
    event: objc.Id,
    action: vt.keyboard.Action,
    committed_text: []const u8,
) ?vt.keyboard.Event {
    const key_code = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) u16)(
        event,
        objc.sel("keyCode"),
    );
    const flags = eventModifierFlags(event);
    const primary = eventScalar(event, 0);
    const shifted_raw = if (flags & mod_shift != 0) eventScalar(event, mod_shift) else null;
    return key_normalizer.normalize(.{
        .key_code = key_code,
        .primary = primary,
        .shifted = shifted_raw,
        .modifiers = keyModifiers(flags),
        .action = action,
        .committed_text = committed_text,
    });
}

const CellPoint = struct { row: u16, col: u16 };
const EventPoint = struct {
    cell: CellPoint,
    /// View coordinates with a top-left origin; intentionally unclamped.
    x: f32,
    y: f32,
};

const SessionCell = struct {
    session: *daemon_client.Session,
    cell: CellPoint,
};

const selection_drag_threshold: f32 = 3;
const selection_scroll_interval: objc.CGFloat = 1.0 / 30.0;

/// Mouse point → view-relative cell. NSView y grows upward; the grid
/// grows downward. Raw coordinates remain unclamped so edge dragging can
/// distinguish a pointer outside the view from one on its first/last row.
fn pointFromEvent(event: objc.Id) EventPoint {
    const win_point = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGPoint)(
        event,
        objc.sel("locationInWindow"),
    );
    const local = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGPoint, objc.Id) callconv(.c) objc.CGPoint)(
        app.view,
        objc.sel("convertPoint:fromView:"),
        win_point,
        null,
    );
    const m = app.renderer.cellMetrics();
    const view_x: f32 = @floatCast(local.x);
    const y_up: f32 = @floatCast(local.y);
    const y: f32 = app.view_size[1] - y_up;
    const session = activeSession();
    var pane_origin_x: f32 = 0;
    if (activeDisplayIndex()) |index| switch (app.display_items.items[index]) {
        .single => {},
        .pair => |pair| if (zoomedPairMember(pair) == null and pair.right == session.id) {
            if (activePairGeometry(pair)) |geometry| pane_origin_x = geometry.right_origin;
        },
    };
    const x = view_x - pane_origin_x;
    const col_f = @max(x, 0) / m.cell_width;
    const row_f = @max(y, 0) / m.cell_height;
    const rows = @max(@as(u16, 1), session.requested_rows);
    const cols = @max(@as(u16, 1), session.requested_cols);
    return .{ .x = x, .y = y, .cell = .{
        .row = @intFromFloat(@min(row_f, @as(f32, @floatFromInt(rows - 1)))),
        .col = @intFromFloat(@min(col_f, @as(f32, @floatFromInt(cols - 1)))),
    } };
}

/// Resolve a pointer to the pane beneath it without changing pair focus.
/// Unlike selection's active-pane point, OSC 8 hover must work in either
/// visible pane before Command-click focuses it.
fn sessionCellFromEvent(event: objc.Id) ?SessionCell {
    const win_point = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGPoint)(
        event,
        objc.sel("locationInWindow"),
    );
    const local = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGPoint, objc.Id) callconv(.c) objc.CGPoint)(
        app.view,
        objc.sel("convertPoint:fromView:"),
        win_point,
        null,
    );
    const x: f32 = @floatCast(local.x);
    const y: f32 = app.view_size[1] - @as(f32, @floatCast(local.y));
    if (x < 0 or x >= app.view_size[0] or y < 0 or y >= app.view_size[1]) return null;

    const display_index = activeDisplayIndex() orelse return null;
    var pane_x: f32 = 0;
    var pane_width: f32 = app.view_size[0];
    const session = switch (app.display_items.items[display_index]) {
        .single => |id| sessionById(id) orelse return null,
        .pair => |pair| blk: {
            if (zoomedPairMember(pair)) |id| break :blk sessionById(id) orelse return null;
            const geometry = activePairGeometry(pair) orelse return null;
            if (x < geometry.left_width) {
                pane_width = geometry.left_width;
                break :blk sessionById(pair.left) orelse return null;
            }
            if (x < geometry.right_origin) return null;
            pane_x = geometry.right_origin;
            pane_width = geometry.right_width;
            break :blk sessionById(pair.right) orelse return null;
        },
    };
    const pane_local_x = x - pane_x;
    if (pane_local_x < 0 or pane_local_x >= pane_width) return null;
    const metrics = app.renderer.cellMetrics();
    const cols = @max(@as(u16, 1), session.requested_cols);
    const rows = @max(@as(u16, 1), session.requested_rows);
    return .{ .session = session, .cell = .{
        .row = @intFromFloat(@min(y / metrics.cell_height, @as(f32, @floatFromInt(rows - 1)))),
        .col = @intFromFloat(@min(pane_local_x / metrics.cell_width, @as(f32, @floatFromInt(cols - 1)))),
    } };
}

fn setHyperlinkPointer(linked: bool) void {
    if (!linked) {
        applyTrackedPointerShape();
        return;
    }
    setNativePointerShape(.pointer);
}

fn setNativePointerShape(shape: vt.mouse.PointerShape) void {
    if (app.applied_pointer_shape != null and app.applied_pointer_shape.? == shape) return;
    const selector = switch (shape) {
        .text => "IBeamCursor",
        .default => "arrowCursor",
        .pointer => "pointingHandCursor",
        .crosshair => "crosshairCursor",
    };
    const cursor = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSCursor"),
        objc.sel(selector),
    );
    objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(cursor, objc.sel("set"));
    app.applied_pointer_shape = shape;
}

fn applyTrackedPointerShape() void {
    if (app.hyperlink_command_held and app.hovered_hyperlink_id != 0) {
        setHyperlinkPointer(true);
        return;
    }
    const session_id = app.pointer_session_id orelse {
        setNativePointerShape(.default);
        return;
    };
    const session = sessionById(session_id) orelse {
        setNativePointerShape(.default);
        return;
    };
    session.mutex.lockUncancelable(session.io);
    const shape = if (session.render_snapshot) |snapshot|
        snapshot.modes.pointer_shape
    else
        vt.mouse.PointerShape.text;
    session.mutex.unlock(session.io);
    setNativePointerShape(shape);
}

fn trackPointerSession(event: objc.Id) ?SessionCell {
    const target = sessionCellFromEvent(event);
    app.pointer_session_id = if (target) |value| value.session.id else null;
    // Cursor rects belonging to AppKit chrome do not know about this cache.
    // Re-entering terminal content must therefore reassert the requested
    // shape even when the terminal state itself did not change.
    app.applied_pointer_shape = null;
    return target;
}

fn clearHyperlinkHover() void {
    const changed = app.hovered_hyperlink_id != 0 or app.hovered_hyperlink_session != null;
    app.hovered_hyperlink_id = 0;
    app.hovered_hyperlink_session = null;
    setHyperlinkPointer(false);
    if (changed) scheduleRender();
}

fn updateHyperlinkHover(event: objc.Id) void {
    if (!app.hyperlink_command_held) {
        clearHyperlinkHover();
        return;
    }
    const target = trackPointerSession(event) orelse {
        clearHyperlinkHover();
        return;
    };
    target.session.mutex.lockUncancelable(target.session.io);
    const hyperlink_id = if (target.session.render_snapshot) |snapshot|
        if (target.cell.row < snapshot.rows and target.cell.col < snapshot.cols)
            snapshot.viewCellAt(target.cell.row, target.cell.col).hyperlink_id
        else
            0
    else
        0;
    target.session.mutex.unlock(target.session.io);

    const session_id: ?u64 = if (hyperlink_id == 0) null else target.session.id;
    const changed = hyperlink_id != app.hovered_hyperlink_id or
        session_id != app.hovered_hyperlink_session or
        target.cell.row != app.hovered_hyperlink_cell.row or
        target.cell.col != app.hovered_hyperlink_cell.col;
    app.hovered_hyperlink_id = hyperlink_id;
    app.hovered_hyperlink_session = session_id;
    app.hovered_hyperlink_cell = target.cell;
    setHyperlinkPointer(hyperlink_id != 0);
    if (changed) scheduleRender();
}

fn openHyperlinkAtEvent(event: objc.Id) bool {
    if (eventModifierFlags(event) & mod_command == 0) return false;
    const target = sessionCellFromEvent(event) orelse return false;
    target.session.mutex.lockUncancelable(target.session.io);
    const uri_copy = blk: {
        const snapshot = target.session.render_snapshot orelse break :blk null;
        if (target.cell.row >= snapshot.rows or target.cell.col >= snapshot.cols) break :blk null;
        const cell = snapshot.viewCellAt(target.cell.row, target.cell.col);
        const link = snapshot.viewCellHyperlink(cell) orelse break :blk null;
        break :blk app.gpa.dupe(u8, link.uri) catch null;
    };
    target.session.mutex.unlock(target.session.io);
    const uri = uri_copy orelse return false;
    defer app.gpa.free(uri);
    openHyperlinkUri(uri);
    return true;
}

fn openHyperlinkUri(uri: []const u8) void {
    var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = std.posix.gethostname(&hostname_buf) catch "";
    switch (hyperlink_mod.classify(uri, hostname)) {
        .reject => {
            NSBeep();
            return;
        },
        .confirm => if (!runDestructiveConfirmation(
            "Open this link?",
            uri,
            "Open Link",
        )) return,
        .direct => {},
    }

    const ns_uri = objc.nsStringFromBytes(uri);
    if (ns_uri == null) {
        NSBeep();
        return;
    }
    defer objc.release(ns_uri);
    const url = objc.msg(*const fn (objc.Class, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        objc.cls("NSURL"),
        objc.sel("URLWithString:"),
        ns_uri,
    );
    const workspace = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSWorkspace"),
        objc.sel("sharedWorkspace"),
    );
    if (url == null or workspace == null or objc.msg(
        *const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.BOOL,
    )(workspace, objc.sel("openURL:"), url) == 0) NSBeep();
}

fn focusPaneAtEvent(event: objc.Id) void {
    const display_index = activeDisplayIndex() orelse return;
    const pair = switch (app.display_items.items[display_index]) {
        .single => return,
        .pair => |value| value,
    };
    if (zoomedPairMember(pair) != null) return;
    const geometry = activePairGeometry(pair) orelse return;
    const win_point = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGPoint)(
        event,
        objc.sel("locationInWindow"),
    );
    const local = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGPoint, objc.Id) callconv(.c) objc.CGPoint)(
        app.view,
        objc.sel("convertPoint:fromView:"),
        win_point,
        null,
    );
    const id = if (@as(f32, @floatCast(local.x)) >= geometry.right_origin) pair.right else pair.left;
    if (id == activeSession().id or !selectSessionAndRememberPair(id)) return;
    activateSelectedSession();
}

fn eventModifierFlags(event: objc.Id) objc.NSUInteger {
    return objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSUInteger)(
        event,
        objc.sel("modifierFlags"),
    );
}

fn mouseModifiers(event: objc.Id) vt.mouse.Modifiers {
    const flags = eventModifierFlags(event);
    return .{
        .shift = flags & mod_shift != 0,
        .alt = flags & mod_option != 0,
        .control = flags & mod_control != 0,
    };
}

fn optionHeld(event: objc.Id) bool {
    return eventModifierFlags(event) & mod_option != 0;
}

fn mouseReportingAtLiveViewport(session: *daemon_client.Session) bool {
    session.mutex.lockUncancelable(session.io);
    defer session.mutex.unlock(session.io);
    const snapshot = session.render_snapshot orelse return false;
    return snapshot.modes.mouse_reporting and (snapshot.modes.on_alt or snapshot.viewport_offset == 0);
}

fn reportMouse(event: objc.Id, kind: vt.mouse.Kind, button: vt.mouse.Button) bool {
    const session = activeSession();
    if (session.exited.load(.acquire) or !mouseReportingAtLiveViewport(session)) return false;
    const point = pointFromEvent(event);
    const pixel_x = backingPixelCoordinate(point.x, session.requested_pixel_width);
    const pixel_y = backingPixelCoordinate(point.y, session.requested_pixel_height);
    return app.client.mouseEvent(session.id, .{
        .kind = kind,
        .button = button,
        .modifiers = mouseModifiers(event),
        .col = point.cell.col,
        .row = point.cell.row,
        .pixel_x = pixel_x,
        .pixel_y = pixel_y,
    }) catch {
        // A stale active-mode snapshot must not turn an application click
        // into a local selection after an IPC failure.
        NSBeep();
        return true;
    };
}

/// Convert pane-local AppKit points into the same zero-based physical backing
/// pixels used by the drawable, PTY winsize, and XTWINOPS reports.
fn backingPixelCoordinate(points: f32, extent: u16) u32 {
    if (extent == 0 or points <= 0) return 0;
    const backing = @round(points * app.scale);
    const last: u32 = extent - 1;
    return @intFromFloat(@min(backing, @as(f32, @floatFromInt(last))));
}

fn pressedMouseButton() vt.mouse.Button {
    const buttons = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.NSUInteger)(
        objc.cls("NSEvent"),
        objc.sel("pressedMouseButtons"),
    );
    if (buttons & 1 != 0) return .left;
    if (buttons & 4 != 0) return .middle;
    if (buttons & 2 != 0) return .right;
    return .none;
}

fn stopSelectionScroll() void {
    if (app.selection_scroll_timer) |timer| {
        objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(timer, objc.sel("invalidate"));
        app.selection_scroll_timer = null;
    }
    app.selection_scroll_delta = 0;
}

fn resetSelectionGesture() void {
    stopSelectionScroll();
    app.selection_pending = false;
    app.selection_dragging = false;
    app.left_mouse_reported = false;
}

fn startSelectionScroll(delta: i8, col: u16) void {
    app.selection_scroll_delta = delta;
    app.selection_scroll_col = col;
    if (app.selection_scroll_timer != null) return;

    const timer = objc.msg(
        *const fn (objc.Class, objc.Sel, objc.CGFloat, objc.Id, objc.Sel, objc.Id, objc.BOOL) callconv(.c) objc.Id,
    )(
        objc.cls("NSTimer"),
        objc.sel("timerWithTimeInterval:target:selector:userInfo:repeats:"),
        selection_scroll_interval,
        app.view,
        objc.sel("selectionScrollTick:"),
        null,
        1,
    );
    if (timer == null) return;
    app.selection_scroll_timer = timer;
    const run_loop = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSRunLoop"),
        objc.sel("mainRunLoop"),
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id, objc.Id) callconv(.c) void)(
        run_loop,
        objc.sel("addTimer:forMode:"),
        timer,
        ns_run_loop_common_modes.*,
    );
}

fn updateSelectionScroll(p: EventPoint) void {
    if (p.y < 0) {
        startSelectionScroll(1, p.cell.col);
    } else if (p.y >= app.view_size[1]) {
        startSelectionScroll(-1, p.cell.col);
    } else {
        stopSelectionScroll();
    }
}

fn selectionScrollTick(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    const buttons = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.NSUInteger)(
        objc.cls("NSEvent"),
        objc.sel("pressedMouseButtons"),
    );
    if (buttons & 1 == 0 or !app.selection_dragging) {
        resetSelectionGesture();
        return;
    }

    const delta = app.selection_scroll_delta;
    if (delta == 0) {
        stopSelectionScroll();
        return;
    }

    var moved = false;
    const session = activeSession();
    const on_alt = blk: {
        session.mutex.lockUncancelable(session.io);
        defer session.mutex.unlock(session.io);
        break :blk if (session.render_snapshot) |snapshot| snapshot.modes.on_alt else false;
    };
    if (!on_alt) {
        moved = app.client.scroll(session.id, delta) catch false;
        if (moved) {
            const row: u16 = if (delta > 0) 0 else @max(@as(u16, 1), session.requested_rows) - 1;
            app.client.selectionDrag(session.id, row, app.selection_scroll_col) catch {
                moved = false;
            };
            session.grid_dirty.store(true, .release);
        }
    }
    if (!moved) {
        stopSelectionScroll();
        return;
    }
    scheduleRender();
}

fn beginSelectionAt(p: CellPoint, mode: vt.terminal.SelectionMode) void {
    const session = activeSession();
    app.client.selectionStart(session.id, p.row, p.col, mode) catch {
        NSBeep();
        return;
    };
    session.grid_dirty.store(true, .release);
}

fn dragSelectionTo(p: CellPoint) void {
    const session = activeSession();
    app.client.selectionDrag(session.id, p.row, p.col) catch {
        NSBeep();
        return;
    };
    session.grid_dirty.store(true, .release);
}

fn clearSelection() void {
    const session = activeSession();
    app.client.selectionClear(session.id) catch return;
    session.grid_dirty.store(true, .release);
}

fn viewMouseDown(_: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    focusPaneAtEvent(event);
    resetSelectionGesture();
    if (openHyperlinkAtEvent(event)) return;
    if (!optionHeld(event) and reportMouse(event, .press, .left)) {
        app.left_mouse_reported = true;
        return;
    }
    const p = pointFromEvent(event);
    clearSelection();

    const clicks = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(
        event,
        objc.sel("clickCount"),
    );
    app.selection_mode = switch (clicks) {
        1 => .char,
        2 => .word,
        else => .line,
    };
    app.selection_anchor = p.cell;
    app.selection_press_x = p.x;
    app.selection_press_y = p.y;
    if (clicks == 1) {
        app.selection_pending = true;
    } else {
        beginSelectionAt(p.cell, app.selection_mode);
        app.selection_dragging = true;
    }
    scheduleRender();
}

fn viewMouseDragged(_: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    if (app.left_mouse_reported) {
        _ = reportMouse(event, .motion, .left);
        return;
    }
    const p = pointFromEvent(event);
    if (app.selection_pending) {
        const dx = p.x - app.selection_press_x;
        const dy = p.y - app.selection_press_y;
        if (dx * dx + dy * dy < selection_drag_threshold * selection_drag_threshold) return;
        beginSelectionAt(app.selection_anchor, .char);
        app.selection_pending = false;
        app.selection_dragging = true;
    }
    if (!app.selection_dragging) return;

    dragSelectionTo(p.cell);
    updateSelectionScroll(p);
    scheduleRender();
}

fn viewMouseUp(_: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    if (app.left_mouse_reported) {
        _ = reportMouse(event, .release, .left);
        resetSelectionGesture();
        return;
    }
    if (app.selection_dragging) dragSelectionTo(pointFromEvent(event).cell);
    resetSelectionGesture();
    scheduleRender();
}

fn viewRightMouseDown(_: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    focusPaneAtEvent(event);
    _ = reportMouse(event, .press, .right);
}

fn viewRightMouseDragged(_: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    _ = reportMouse(event, .motion, .right);
}

fn viewRightMouseUp(_: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    _ = reportMouse(event, .release, .right);
}

fn isMiddleMouseEvent(event: objc.Id) bool {
    return objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(
        event,
        objc.sel("buttonNumber"),
    ) == 2;
}

fn viewOtherMouseDown(_: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    if (isMiddleMouseEvent(event)) _ = reportMouse(event, .press, .middle);
}

fn viewOtherMouseDragged(_: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    if (isMiddleMouseEvent(event)) _ = reportMouse(event, .motion, .middle);
}

fn viewOtherMouseUp(_: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    if (isMiddleMouseEvent(event)) _ = reportMouse(event, .release, .middle);
}

fn viewMouseMoved(_: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    if (app.hyperlink_command_held) {
        updateHyperlinkHover(event);
        return;
    }
    _ = trackPointerSession(event);
    applyTrackedPointerShape();
    _ = reportMouse(event, .motion, pressedMouseButton());
}

fn viewCopy(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    const session = activeSession();
    const text = app.client.selectionText(session.id) catch null;
    const bytes = text orelse return; // empty selection: never clobber
    defer app.gpa.free(bytes);
    if (bytes.len == 0) return;

    const pasteboard = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSPasteboard"),
        objc.sel("generalPasteboard"),
    );
    _ = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSInteger)(
        pasteboard,
        objc.sel("clearContents"),
    );
    const ns = objc.nsStringFromBytes(bytes);
    _ = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id, objc.Id) callconv(.c) objc.BOOL)(
        pasteboard,
        objc.sel("setString:forType:"),
        ns,
        objc.nsString("public.utf8-plain-text"),
    );
    objc.release(ns);
}

/// Primary screen: wheel scrolls the viewport. Alt screen: wheel becomes
/// arrow keys (the alternate-scroll convention — less/vim behave as users
/// expect). RFC 0003.
fn viewScrollWheel(_: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    clearHyperlinkHover();
    const dx = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGFloat)(
        event,
        objc.sel("scrollingDeltaX"),
    );
    const dy = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGFloat)(
        event,
        objc.sel("scrollingDeltaY"),
    );
    const precise = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.BOOL)(
        event,
        objc.sel("hasPreciseScrollingDeltas"),
    );
    const m = app.renderer.cellMetrics();
    // Precise deltas are pixels; line-based deltas are already rows.
    const rows_f: f64 = if (precise != 0) dy / @as(f64, @floatCast(m.cell_height)) else dy;
    const cols_f: f64 = if (precise != 0) dx / @as(f64, @floatCast(m.cell_width)) else dx;
    const session = activeSession();
    session.scroll_accum += rows_f;
    session.scroll_accum_x += cols_f;
    const whole_y: i64 = @intFromFloat(session.scroll_accum);
    const whole_x: i64 = @intFromFloat(session.scroll_accum_x);
    if (whole_y != 0) session.scroll_accum -= @floatFromInt(whole_y);
    if (whole_x != 0) session.scroll_accum_x -= @floatFromInt(whole_x);
    if (whole_y == 0 and whole_x == 0) return;

    if (mouseReportingAtLiveViewport(session)) {
        var vertical = @min(@abs(whole_y), 40);
        while (vertical > 0) : (vertical -= 1) {
            _ = reportMouse(event, if (whole_y > 0) .wheel_up else .wheel_down, .none);
        }
        var horizontal = @min(@abs(whole_x), 40);
        while (horizontal > 0) : (horizontal -= 1) {
            _ = reportMouse(event, if (whole_x > 0) .wheel_left else .wheel_right, .none);
        }
        return;
    }

    if (whole_y == 0) return; // local viewport has no horizontal scrolling

    var on_alt = false;
    {
        session.mutex.lockUncancelable(session.io);
        defer session.mutex.unlock(session.io);
        if (session.render_snapshot) |snapshot| {
            on_alt = snapshot.modes.on_alt;
        }
    }
    if (on_alt) {
        const code: vt.keyboard.Code = if (whole_y > 0) .up else .down;
        var n: u64 = @abs(whole_y);
        n = @min(n, 40);
        while (n > 0) : (n -= 1) {
            if (!session.exited.load(.acquire)) app.client.keyEvent(session.id, .{ .code = code }) catch break;
        }
    } else {
        _ = app.client.scroll(session.id, whole_y) catch return;
    }
    session.grid_dirty.store(true, .release);
    scheduleRender();
}

fn viewPaste(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    const pasteboard = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSPasteboard"),
        objc.sel("generalPasteboard"),
    );
    const str = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        pasteboard,
        objc.sel("stringForType:"),
        objc.nsString("public.utf8-plain-text"),
    );
    const text = nsStringUtf8(str) orelse return;
    const session = activeSession();
    if (session.exited.load(.acquire)) return;
    app.client.paste(session.id, text) catch {
        NSBeep();
        return;
    };
    session.grid_dirty.store(true, .release);
    scheduleRender();
}

fn fileDropSession(info: objc.Id) ?*daemon_client.Session {
    const window_point = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGPoint)(
        info,
        objc.sel("draggingLocation"),
    );
    const local = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGPoint, objc.Id) callconv(.c) objc.CGPoint)(
        app.view,
        objc.sel("convertPoint:fromView:"),
        window_point,
        null,
    );
    const x: f32 = @floatCast(local.x);
    const y: f32 = @floatCast(local.y);
    if (x < 0 or x >= app.view_size[0] or y < 0 or y >= app.view_size[1]) return null;

    const index = activeDisplayIndex() orelse return null;
    return switch (app.display_items.items[index]) {
        .single => |id| sessionById(id),
        .pair => |pair| blk: {
            if (zoomedPairMember(pair)) |id| break :blk sessionById(id);
            const geometry = activePairGeometry(pair) orelse break :blk null;
            if (x < geometry.left_width) break :blk sessionById(pair.left);
            if (x < geometry.right_origin) break :blk null;
            break :blk sessionById(pair.right);
        },
    };
}

fn fileDropPasteboard(info: objc.Id) objc.Id {
    return objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        info,
        objc.sel("draggingPasteboard"),
    );
}

fn fileDropAvailable(info: objc.Id) bool {
    const pasteboard = fileDropPasteboard(info);
    if (pasteboard == null) return false;
    const types = objc.msg(*const fn (objc.Class, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        objc.cls("NSArray"),
        objc.sel("arrayWithObject:"),
        objc.nsString("public.file-url"),
    );
    return objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        pasteboard,
        objc.sel("availableTypeFromArray:"),
        types,
    ) != null;
}

fn viewFileDraggingUpdated(_: objc.Id, _: objc.Sel, info: objc.Id) callconv(.c) objc.NSUInteger {
    const session = fileDropSession(info) orelse return ns_drag_operation_none;
    if (session.exited.load(.acquire) or !fileDropAvailable(info)) return ns_drag_operation_none;
    return ns_drag_operation_copy;
}

fn viewPrepareFileDrag(self: objc.Id, selector: objc.Sel, info: objc.Id) callconv(.c) objc.BOOL {
    return @intFromBool(viewFileDraggingUpdated(self, selector, info) == ns_drag_operation_copy);
}

fn fileDropPayload(info: objc.Id) ![]u8 {
    const pasteboard = fileDropPasteboard(info);
    if (pasteboard == null) return error.InvalidPasteboard;
    const items = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        pasteboard,
        objc.sel("pasteboardItems"),
    );
    if (items == null) return error.InvalidPasteboard;
    const count = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSUInteger)(
        items,
        objc.sel("count"),
    );
    if (count == 0 or count > 65_536) return error.InvalidPasteboard;

    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(app.gpa);
    try paths.ensureTotalCapacity(app.gpa, count);
    var index: objc.NSUInteger = 0;
    while (index < count) : (index += 1) {
        const item = objc.msg(*const fn (objc.Id, objc.Sel, objc.NSUInteger) callconv(.c) objc.Id)(
            items,
            objc.sel("objectAtIndex:"),
            index,
        );
        if (item == null) return error.InvalidPasteboard;
        const encoded_url = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id)(
            item,
            objc.sel("stringForType:"),
            objc.nsString("public.file-url"),
        );
        if (encoded_url == null) return error.InvalidPasteboard;
        const url = objc.msg(*const fn (objc.Class, objc.Sel, objc.Id) callconv(.c) objc.Id)(
            objc.cls("NSURL"),
            objc.sel("URLWithString:"),
            encoded_url,
        );
        if (url == null or objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.BOOL)(
            url,
            objc.sel("isFileURL"),
        ) == 0) return error.InvalidPasteboard;
        const ns_path = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
            url,
            objc.sel("path"),
        );
        const path = nsStringUtf8(ns_path) orelse return error.InvalidPasteboard;
        paths.appendAssumeCapacity(path);
    }
    return path_drop.format(app.gpa, paths.items);
}

fn focusFileDropSession(session: *daemon_client.Session) void {
    if (session.id == activeSession().id) return;
    if (!selectSessionAndRememberPair(session.id)) return NSBeep();
    activateSelectedSession();
}

fn viewPerformFileDrag(_: objc.Id, _: objc.Sel, info: objc.Id) callconv(.c) objc.BOOL {
    const session = fileDropSession(info) orelse return 0;
    if (session.exited.load(.acquire)) return 0;
    const payload = fileDropPayload(info) catch {
        NSBeep();
        return 0;
    };
    defer app.gpa.free(payload);

    app.client.paste(session.id, payload) catch {
        NSBeep();
        return 0;
    };
    focusFileDropSession(session);
    _ = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.BOOL)(
        app.window,
        objc.sel("makeFirstResponder:"),
        app.view,
    );
    session.grid_dirty.store(true, .release);
    scheduleRender();
    return 1;
}

fn viewFrameChanged(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    clearHyperlinkHover();
    syncSizes();
    if (app.in_live_resize) {
        // Re-layout in lockstep with the drag: grid resize, SIGWINCH, and
        // a synchronous frame inside this transaction.
        renderNow();
    } else {
        scheduleRender();
    }
}

fn callSuperVoid(self: objc.Id, selector: objc.Sel) void {
    var super_ctx: objc.Super = .{ .receiver = self, .super_class = objc.cls("NSView") };
    objc.msgSuper(*const fn (*objc.Super, objc.Sel) callconv(.c) void)(&super_ctx, selector);
}

fn viewWillStartLiveResize(self: objc.Id, selector: objc.Sel) callconv(.c) void {
    callSuperVoid(self, selector);
    app.in_live_resize = true;
    objc.setU(app.layer, objc.sel("setPresentsWithTransaction:"), 1);
}

fn viewDidEndLiveResize(self: objc.Id, selector: objc.Sel) callconv(.c) void {
    callSuperVoid(self, selector);
    app.in_live_resize = false;
    objc.setU(app.layer, objc.sel("setPresentsWithTransaction:"), 0);
    // Settle frame at the final size, back on the async path.
    syncSizes();
    scheduleRender();
}

// -- NSTextInputClient -------------------------------------------------------

fn textObjectString(string: objc.Id) objc.Id {
    if (string == null) return null;
    var s = string;
    const is_attributed = objc.msg(*const fn (objc.Id, objc.Sel, objc.Class) callconv(.c) objc.BOOL)(
        string,
        objc.sel("isKindOfClass:"),
        objc.cls("NSAttributedString"),
    );
    if (is_attributed != 0) {
        s = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(s, objc.sel("string"));
    }
    return s;
}

fn replacementCount(range: objc.NSRange) usize {
    if (range.location == objc.NSNotFound) return 0;
    return @min(range.length, vt.keyboard.max_text_bytes);
}

fn tiInsertText(_: objc.Id, _: objc.Sel, string: objc.Id, replacement: objc.NSRange) callconv(.c) void {
    app.preedit.clear();
    scheduleRender();
    const text = nsStringUtf8(textObjectString(string)) orelse return;
    _ = std.unicode.Utf8View.init(text) catch return;
    if (app.key_text.active) {
        app.key_text.append(text, replacementCount(replacement));
        return;
    }
    sendReplacementBackspaces(replacementCount(replacement));
    ptyText(text);
}

fn tiDoCommand(_: objc.Id, _: objc.Sel, _: objc.Sel) callconv(.c) void {
    // keyDown submits the original semantic event after AppKit returns.
    // This callback exists to prevent NSBeep, never to race a raw PTY write.
}

fn tiSetMarkedText(
    _: objc.Id,
    _: objc.Sel,
    string: objc.Id,
    selected: objc.NSRange,
    _: objc.NSRange,
) callconv(.c) void {
    app.preedit.clear();
    const s = textObjectString(string);
    const text = nsStringUtf8(s) orelse {
        scheduleRender();
        return;
    };
    _ = std.unicode.Utf8View.init(text) catch return;
    var copy_len = @min(text.len, app.preedit.bytes.len);
    while (copy_len > 0 and copy_len < text.len and (text[copy_len] & 0xc0) == 0x80) copy_len -= 1;
    @memcpy(app.preedit.bytes[0..copy_len], text[0..copy_len]);
    app.preedit.len = @intCast(copy_len);

    const retained = objc.nsStringFromBytes(app.preedit.text());
    if (retained != null) {
        const utf16_len = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSUInteger)(
            retained,
            objc.sel("length"),
        );
        app.preedit.marked_utf16_len = @intCast(@min(utf16_len, std.math.maxInt(u16)));
        objc.release(retained);
    }
    const selected_location = @min(selected.location, app.preedit.marked_utf16_len);
    const selected_length = @min(selected.length, app.preedit.marked_utf16_len - selected_location);
    app.preedit.selected_utf16 = .{ .location = selected_location, .length = selected_length };

    if (s != null and selected_location != 0) {
        const prefix = objc.msg(*const fn (objc.Id, objc.Sel, objc.NSUInteger) callconv(.c) objc.Id)(
            s,
            objc.sel("substringToIndex:"),
            selected_location,
        );
        if (nsStringUtf8(prefix)) |bytes|
            app.preedit.selected_utf8 = @intCast(@min(bytes.len, copy_len));
    }
    scheduleRender();
}

fn tiUnmarkText(_: objc.Id, _: objc.Sel) callconv(.c) void {
    app.preedit.clear();
    scheduleRender();
}

fn tiHasMarkedText(_: objc.Id, _: objc.Sel) callconv(.c) objc.BOOL {
    return @intFromBool(app.preedit.active());
}

fn tiMarkedRange(_: objc.Id, _: objc.Sel) callconv(.c) objc.NSRange {
    if (app.preedit.active()) return .{ .location = 0, .length = app.preedit.marked_utf16_len };
    return .{ .location = objc.NSNotFound, .length = 0 };
}

fn tiSelectedRange(_: objc.Id, _: objc.Sel) callconv(.c) objc.NSRange {
    if (app.preedit.active()) return app.preedit.selected_utf16;
    return .{ .location = objc.NSNotFound, .length = 0 };
}

fn tiAttributedSubstring(_: objc.Id, _: objc.Sel, _: objc.NSRange, actual: ?*objc.NSRange) callconv(.c) objc.Id {
    if (!app.preedit.active()) return null;
    if (actual) |range| range.* = .{ .location = 0, .length = app.preedit.marked_utf16_len };
    const string = objc.nsStringFromBytes(app.preedit.text());
    if (string == null) return null;
    defer objc.release(string);
    const attributed = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSAttributedString"),
        objc.sel("alloc"),
    );
    const initialized = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        attributed,
        objc.sel("initWithString:"),
        string,
    );
    return objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(initialized, objc.sel("autorelease"));
}

fn tiValidAttributes(_: objc.Id, _: objc.Sel) callconv(.c) objc.Id {
    return objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSArray"),
        objc.sel("array"),
    );
}

/// Positions the IME candidate window at the cursor cell.
fn tiFirstRect(_: objc.Id, _: objc.Sel, range: objc.NSRange, actual: ?*objc.NSRange) callconv(.c) objc.CGRect {
    const m = app.renderer.cellMetrics();
    const session = activeSession();
    var row: f32 = 0;
    var col: f32 = 0;
    var pane_origin_x: f32 = 0;
    {
        session.mutex.lockUncancelable(session.io);
        defer session.mutex.unlock(session.io);
        if (session.render_snapshot) |snapshot| {
            var cell: renderer_mod.PreeditCell = .{ .row = snapshot.row, .col = snapshot.col };
            if (app.preedit.active()) cell = renderer_mod.preeditCaretCell(
                app.preedit.text(),
                app.preedit.selected_utf8,
                snapshot.row,
                snapshot.col,
                snapshot.cols,
            );
            row = @floatFromInt(cell.row);
            col = @floatFromInt(cell.col);
        }
    }
    if (activeDisplayIndex()) |index| switch (app.display_items.items[index]) {
        .single => {},
        .pair => |pair| if (zoomedPairMember(pair) == null) {
            if (activePairGeometry(pair)) |geometry|
                pane_origin_x = if (session.id == pair.right) geometry.right_origin else geometry.left_origin;
        },
    };
    if (actual) |value| value.* = if (app.preedit.active())
        .{ .location = 0, .length = app.preedit.marked_utf16_len }
    else
        range;
    // Grid is top-left based; NSView coords are bottom-left.
    const view_h = app.view_size[1];
    const local: objc.CGRect = .{
        .origin = .{
            .x = @floatCast(pane_origin_x + col * m.cell_width),
            .y = @floatCast(view_h - (row + 1) * m.cell_height),
        },
        .size = .{ .width = @floatCast(m.cell_width), .height = @floatCast(m.cell_height) },
    };
    const in_window = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect, objc.Id) callconv(.c) objc.CGRect)(
        app.view,
        objc.sel("convertRect:toView:"),
        local,
        null,
    );
    return objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect) callconv(.c) objc.CGRect)(
        app.window,
        objc.sel("convertRectToScreen:"),
        in_window,
    );
}

fn tiCharIndex(_: objc.Id, _: objc.Sel, _: objc.CGPoint) callconv(.c) objc.NSUInteger {
    return objc.NSNotFound;
}

// -- app delegate ------------------------------------------------------------

fn installDelegate(ns_app: objc.Id) void {
    const class = objc.allocateClass(objc.cls("NSObject"), "BoringTerminalAppDelegate");
    objc.addMethod(
        class,
        objc.sel("applicationShouldTerminateAfterLastWindowClosed:"),
        @ptrCast(@constCast(&delegateShouldTerminateAfterLastWindowClosed)),
        "c@:@",
    );
    objc.addMethod(
        class,
        objc.sel("applicationShouldTerminate:"),
        @ptrCast(@constCast(&delegateApplicationShouldTerminate)),
        "Q@:@",
    );
    objc.addMethod(
        class,
        objc.sel("windowShouldClose:"),
        @ptrCast(@constCast(&delegateWindowShouldClose)),
        "c@:@",
    );
    objc.addMethod(
        class,
        objc.sel("windowDidBecomeKey:"),
        @ptrCast(@constCast(&delegateWindowDidBecomeKey)),
        "v@:@",
    );
    objc.addMethod(
        class,
        objc.sel("windowDidResignKey:"),
        @ptrCast(@constCast(&delegateWindowDidResignKey)),
        "v@:@",
    );
    objc.addMethod(
        class,
        objc.sel("windowDidResize:"),
        @ptrCast(@constCast(&delegateWindowDidResize)),
        "v@:@",
    );
    objc.addMethod(
        class,
        objc.sel("applicationWillTerminate:"),
        @ptrCast(@constCast(&delegateWillTerminate)),
        "v@:@",
    );
    objc.registerClass(class);
    const delegate = objc.allocInit(class);
    objc.setId(ns_app, objc.sel("setDelegate:"), delegate);
    objc.setId(app.window, objc.sel("setDelegate:"), delegate);
}

fn delegateShouldTerminateAfterLastWindowClosed(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) objc.BOOL {
    return 1;
}

fn delegateApplicationShouldTerminate(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) objc.NSUInteger {
    // Quitting only detaches the viewer; daemon-owned sessions survive.
    return 1; // NSTerminateNow
}

fn delegateWindowShouldClose(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) objc.BOOL {
    // Closing the last window has the same non-destructive detach semantics.
    return 1;
}

fn delegateWindowDidBecomeKey(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    app.window_is_key = true;
    updateSessionFocus();
    renderNow();
}

fn delegateWindowDidResignKey(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    app.window_is_key = false;
    app.preedit.clear();
    updateSessionFocus();
    scheduleRender();
}

fn delegateWindowDidResize(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    // Re-evaluate the preferred width after a temporary narrow-window clamp.
    // The terminal view's resulting frame notification owns grid sync/render.
    layoutSessionBar();
}

fn delegateWillTerminate(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    app.terminating.store(true, .release);
    app.render_pending.store(false, .release);
    app.window_is_key = false;
    updateSessionFocus();
    if (app.config_watcher) |watcher| {
        app.config_watcher = null;
        watcher.destroy();
    }
    const finalize_update = app.client.updatePending() and
        app.client.daemonIdentity().lifecycle_supported;

    // Every ordinary quit retires GPU-visible staging before closing the
    // capability connection. Daemon-owned sessions and PTYs are untouched.
    stopDisplayLink();
    stopSyncOutputTimer();
    app.client.stopEvents();
    app.renderer.prepareForClientShutdown();
    for (app.sessions.sessions.items) |session| session.destroy();
    app.sessions.sessions.clearRetainingCapacity();
    app.client.deinit();
    app.renderer.deinit();

    // Finalize a lifecycle-capable update only after every viewer-owned worker
    // and attach lane has gone away.
    if (!finalize_update) return;
    _ = daemon_client.finalizePendingUpdateIfIdle(app.gpa, app.io, app.env) catch |err| {
        std.log.warn("background-service idle finalization deferred: {s}", .{@errorName(err)});
        return;
    };
}

const ShortcutHelpEntry = struct {
    action: []const u8,
    keys: []const u8,
};

const session_shortcut_help = [_]ShortcutHelpEntry{
    .{ .action = "New Session", .keys = "⌘T" },
    .{ .action = "New Session Beside Current", .keys = "⌘D" },
    .{ .action = "Close Focused Session", .keys = "⌘W" },
    .{ .action = "Focus Left / Right Pane", .keys = "⌥⌘← / ⌥⌘→" },
    .{ .action = "Move Pane Left / Right", .keys = "⇧⌥⌘← / ⇧⌥⌘→" },
    .{ .action = "Focus Previous / Next Group", .keys = "⌥⌘↑ / ⌥⌘↓" },
    .{ .action = "Move Group Up / Down", .keys = "⇧⌥⌘↑ / ⇧⌥⌘↓" },
    .{ .action = "Zoom / Show Both Panes", .keys = "⇧⌘↩" },
    .{ .action = "Previous Session", .keys = "⌘⇧[" },
    .{ .action = "Next Session", .keys = "⌘⇧]" },
    .{ .action = "Switch to Session 1–9", .keys = "⌘1…⌘9" },
    .{ .action = "Show Session Number Hints", .keys = "Hold ⌘" },
};

const terminal_shortcut_help = [_]ShortcutHelpEntry{
    .{ .action = "Copy Selection", .keys = "⌘C" },
    .{ .action = "Paste", .keys = "⌘V" },
    .{ .action = "Clear to Start", .keys = "⌘K" },
    .{ .action = "Find in Session", .keys = "⌘F" },
    .{ .action = "Next Match", .keys = "⌘G" },
    .{ .action = "Previous Match", .keys = "⇧⌘G" },
    .{ .action = "Increase / Decrease Text Size", .keys = "⌘+ / ⌘−" },
    .{ .action = "Reset Text Size", .keys = "⌘0" },
};

const application_shortcut_help = [_]ShortcutHelpEntry{
    .{ .action = "Toggle Session Bar", .keys = "⌘B" },
    .{ .action = "Open Configuration", .keys = "⌘," },
    .{ .action = "Keyboard Shortcuts", .keys = "⌘?" },
    .{ .action = "Quit Boring Terminal", .keys = "⌘Q" },
};

fn addShortcutsPanelLabel(
    parent: objc.Id,
    text: []const u8,
    frame: objc.CGRect,
    font: objc.Id,
    color: objc.Id,
    alignment: objc.NSUInteger,
) void {
    const ns_text = objc.nsStringFromBytes(text);
    defer objc.release(ns_text);
    const label = objc.msg(*const fn (objc.Class, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        objc.cls("NSTextField"),
        objc.sel("labelWithString:"),
        ns_text,
    );
    if (label == null) return;
    setViewFrame(label, frame);
    objc.setId(label, objc.sel("setFont:"), font);
    objc.setId(label, objc.sel("setTextColor:"), color);
    objc.setU(label, objc.sel("setAlignment:"), alignment);
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        parent,
        objc.sel("addSubview:"),
        label,
    );
}

fn addShortcutsSection(
    parent: objc.Id,
    heading: []const u8,
    entries: []const ShortcutHelpEntry,
    y: *f64,
    heading_font: objc.Id,
    body_font: objc.Id,
    key_font: objc.Id,
    label_color: objc.Id,
    secondary_color: objc.Id,
) void {
    addShortcutsPanelLabel(
        parent,
        heading,
        .{ .origin = .{ .x = 24, .y = y.* }, .size = .{ .width = 300, .height = 18 } },
        heading_font,
        secondary_color,
        0,
    );
    y.* -= 26;
    for (entries) |entry| {
        addShortcutsPanelLabel(
            parent,
            entry.action,
            .{ .origin = .{ .x = 32, .y = y.* }, .size = .{ .width = 310, .height = 19 } },
            body_font,
            label_color,
            0,
        );
        addShortcutsPanelLabel(
            parent,
            entry.keys,
            .{ .origin = .{ .x = 348, .y = y.* }, .size = .{ .width = 120, .height = 19 } },
            key_font,
            label_color,
            2,
        );
        y.* -= 25;
    }
    y.* -= 10;
}

fn createShortcutsPanel() objc.Id {
    const content_height: f64 = 520;
    const content: objc.CGRect = .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 492, .height = content_height },
    };
    const panel_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSPanel"),
        objc.sel("alloc"),
    );
    const panel = objc.msg(
        *const fn (objc.Id, objc.Sel, objc.CGRect, objc.NSUInteger, objc.NSUInteger, objc.BOOL) callconv(.c) objc.Id,
    )(
        panel_alloc,
        objc.sel("initWithContentRect:styleMask:backing:defer:"),
        content,
        3, // titled | closable
        2, // buffered
        0,
    );
    if (panel == null) return null;
    objc.setId(panel, objc.sel("setTitle:"), objc.nsString("Keyboard Shortcuts"));
    objc.setU(panel, objc.sel("setReleasedWhenClosed:"), 0);
    objc.setU(panel, objc.sel("setRestorable:"), 0);
    objc.setU(panel, objc.sel("setMovableByWindowBackground:"), 1);
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGSize) callconv(.c) void)(
        panel,
        objc.sel("setContentMinSize:"),
        content.size,
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGSize) callconv(.c) void)(
        panel,
        objc.sel("setContentMaxSize:"),
        content.size,
    );
    const parent = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(panel, objc.sel("contentView"));
    if (parent == null) {
        objc.release(panel);
        return null;
    }

    const heading_font = objc.msg(*const fn (objc.Class, objc.Sel, objc.CGFloat, objc.CGFloat) callconv(.c) objc.Id)(
        objc.cls("NSFont"),
        objc.sel("systemFontOfSize:weight:"),
        12,
        0.3,
    );
    const body_font = objc.msg(*const fn (objc.Class, objc.Sel, objc.CGFloat) callconv(.c) objc.Id)(
        objc.cls("NSFont"),
        objc.sel("systemFontOfSize:"),
        13,
    );
    const key_font = objc.msg(*const fn (objc.Class, objc.Sel, objc.CGFloat, objc.CGFloat) callconv(.c) objc.Id)(
        objc.cls("NSFont"),
        objc.sel("monospacedSystemFontOfSize:weight:"),
        12.5,
        0,
    );
    const label_color = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSColor"),
        objc.sel("labelColor"),
    );
    const secondary_color = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSColor"),
        objc.sel("secondaryLabelColor"),
    );

    const entry_count = session_shortcut_help.len + terminal_shortcut_help.len + application_shortcut_help.len;
    const document_height: f64 = 168 + @as(f64, @floatFromInt(entry_count)) * 25;
    const scroll_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSScrollView"),
        objc.sel("alloc"),
    );
    const scroll = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect) callconv(.c) objc.Id)(
        scroll_alloc,
        objc.sel("initWithFrame:"),
        content,
    );
    if (scroll == null) {
        objc.release(panel);
        return null;
    }
    objc.setU(scroll, objc.sel("setDrawsBackground:"), 0);
    objc.setU(scroll, objc.sel("setBorderType:"), 0);
    objc.setU(scroll, objc.sel("setHasHorizontalScroller:"), 0);
    objc.setU(scroll, objc.sel("setHasVerticalScroller:"), 1);
    objc.setU(scroll, objc.sel("setAutohidesScrollers:"), 1);
    objc.setU(scroll, objc.sel("setScrollerStyle:"), 1);

    const document_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSView"),
        objc.sel("alloc"),
    );
    const document = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect) callconv(.c) objc.Id)(
        document_alloc,
        objc.sel("initWithFrame:"),
        .{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = content.size.width, .height = document_height },
        },
    );
    if (document == null) {
        objc.release(scroll);
        objc.release(panel);
        return null;
    }
    objc.setId(scroll, objc.sel("setDocumentView:"), document);
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        parent,
        objc.sel("addSubview:"),
        scroll,
    );

    var y: f64 = document_height - 36;
    addShortcutsSection(document, "SESSIONS", &session_shortcut_help, &y, heading_font, body_font, key_font, label_color, secondary_color);
    addShortcutsSection(document, "TERMINAL", &terminal_shortcut_help, &y, heading_font, body_font, key_font, label_color, secondary_color);
    addShortcutsSection(document, "APPLICATION", &application_shortcut_help, &y, heading_font, body_font, key_font, label_color, secondary_color);
    const clip = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(scroll, objc.sel("contentView"));
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGPoint) callconv(.c) void)(
        clip,
        objc.sel("scrollToPoint:"),
        .{ .x = 0, .y = document_height - content_height },
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        scroll,
        objc.sel("reflectScrolledClipView:"),
        clip,
    );
    objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(panel, objc.sel("center"));
    return panel;
}

fn viewShowKeyboardShortcuts(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    if (app.shortcuts_panel == null) app.shortcuts_panel = createShortcutsPanel();
    const panel = app.shortcuts_panel orelse return NSBeep();
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        panel,
        objc.sel("makeKeyAndOrderFront:"),
        null,
    );
}

fn updateSearchCount() void {
    if (!app.search_visible) return;
    const query = searchFieldText() orelse return;
    if (query.len == 0) {
        app.search_bar.setStatus(.idle);
        return;
    }
    if (searchValidationMessage(query)) |message|
        return app.search_bar.setStatus(.{ .invalid = message });
    const id = app.search_session_id orelse return;
    const session = sessionById(id) orelse return;
    const status = session.searchStatus();
    if (status.pending) return app.search_bar.setStatus(.searching);
    if (status.total == 0) return app.search_bar.setStatus(.no_results);
    if (status.selected_index) |index| return app.search_bar.setStatus(.{ .result = .{
        .index = index + 1,
        .total = status.total,
        .truncated = status.truncated,
    } });
    app.search_bar.setStatus(.no_results);
}

fn closeSearch(focus_terminal: bool) void {
    if (app.search_session_id) |id| if (sessionById(id)) |session| session.clearSearch();
    app.search_visible = false;
    app.search_session_id = null;
    app.search_bar.hideAndClear();
    if (focus_terminal and app.window != null and app.view != null) {
        _ = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.BOOL)(
            app.window,
            objc.sel("makeFirstResponder:"),
            app.view,
        );
    }
    scheduleRender();
}

fn showSearch() void {
    if (!app.client.supportsSearch()) return NSBeep();
    if (app.search_bar.overlay == null or app.search_bar.field == null) return NSBeep();
    const id = activeSession().id;
    if (app.search_visible and app.search_session_id != id) closeSearch(false);
    app.search_visible = true;
    app.search_session_id = id;
    layoutSearchOverlay();
    app.search_bar.showAndFocus(app.window);
}

fn searchFieldText() ?[]const u8 {
    return app.search_bar.query();
}

fn searchValidationMessage(query: []const u8) ?[]const u8 {
    vt.search.validateQuery(query) catch |err| return switch (err) {
        error.QueryTooLong => "Too long",
        error.InvalidUtf8 => "Invalid text",
        error.MultilineQuery => "Single line only",
        error.EmptyQuery => null,
    };
    return null;
}

fn queueSearch(operation: daemon_protocol.SearchOperation) void {
    const query = searchFieldText() orelse return;
    const id = app.search_session_id orelse return;
    const session = sessionById(id) orelse return;
    if (app.search_bar.hasMarkedText()) return;
    if (query.len == 0) {
        session.clearSearch();
        app.search_bar.setStatus(.idle);
        scheduleRender();
        return;
    }
    if (searchValidationMessage(query)) |message| {
        session.clearSearch();
        app.search_bar.setStatus(.{ .invalid = message });
        scheduleRender();
        return;
    }
    session.setSearch(query, operation) catch |err| {
        std.log.err("validated search request failed: {}", .{err});
        NSBeep();
        return;
    };
    app.search_bar.setStatus(.searching);
    app.search_bar.ensureSelectionVisible();
}

fn viewShowFind(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    showSearch();
}

fn viewFindNext(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    if (!app.search_visible) return showSearch();
    queueSearch(.next);
}

fn viewFindPrevious(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    if (!app.search_visible) return showSearch();
    queueSearch(.previous);
}

fn viewCloseFind(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    closeSearch(true);
}

fn viewSearchChanged(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    queueSearch(.initial);
    app.search_bar.ensureSelectionVisible();
}

fn viewSearchCommand(
    _: objc.Id,
    _: objc.Sel,
    _: objc.Id,
    _: objc.Id,
    command: objc.Sel,
) callconv(.c) objc.BOOL {
    if (command == objc.sel("cancelOperation:")) {
        closeSearch(true);
        return 1;
    }
    if (command == objc.sel("insertNewline:") or
        command == objc.sel("insertNewlineIgnoringFieldEditor:"))
    {
        const ns_app = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
            objc.cls("NSApplication"),
            objc.sel("sharedApplication"),
        );
        const event = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
            ns_app,
            objc.sel("currentEvent"),
        );
        const modifiers = if (event == null) 0 else objc.msg(
            *const fn (objc.Id, objc.Sel) callconv(.c) objc.NSUInteger,
        )(event, objc.sel("modifierFlags"));
        queueSearch(if (modifiers & mod_shift != 0) .previous else .next);
        return 1;
    }
    return 0;
}

// -- menu --------------------------------------------------------------------

fn buildMenu(ns_app: objc.Id) void {
    const main_menu = objc.allocInit(objc.cls("NSMenu"));

    // App menu: the one config file and Quit.
    const app_item = objc.allocInit(objc.cls("NSMenuItem"));
    objc.setId(app_item, objc.sel("setTitle:"), objc.nsString("Boring Terminal"));
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        main_menu,
        objc.sel("addItem:"),
        app_item,
    );
    const app_menu = objc.allocInit(objc.cls("NSMenu"));
    addMenuItem(app_menu, "Open Configuration", "openConfiguration:", ",");
    if (app.client.updatePending())
        addMenuItem(app_menu, "Background Service Update Pending…", "showBackgroundServiceUpdate:", "");
    addMenuSeparator(app_menu);
    addMenuItem(app_menu, "Quit Boring Terminal", "terminate:", "q");
    objc.setId(app_item, objc.sel("setSubmenu:"), app_menu);

    // Edit menu: Paste (responder chain finds the view's paste:).
    const edit_item = objc.allocInit(objc.cls("NSMenuItem"));
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        main_menu,
        objc.sel("addItem:"),
        edit_item,
    );
    const edit_menu = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(objc.cls("NSMenu"), objc.sel("alloc")),
        objc.sel("initWithTitle:"),
        objc.nsString("Edit"),
    );
    addMenuItem(edit_menu, "Copy", "copy:", "c");
    addMenuItem(edit_menu, "Paste", "paste:", "v");
    addMenuItem(edit_menu, "Select All", "selectAll:", "a");
    addMenuItem(edit_menu, "Clear to Start", "clearSession:", "k");
    addMenuSeparator(edit_menu);
    const find_item = objc.allocInit(objc.cls("NSMenuItem"));
    objc.setId(find_item, objc.sel("setTitle:"), objc.nsString("Find"));
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        edit_menu,
        objc.sel("addItem:"),
        find_item,
    );
    const find_menu = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(objc.cls("NSMenu"), objc.sel("alloc")),
        objc.sel("initWithTitle:"),
        objc.nsString("Find"),
    );
    addTargetedModifiedMenuItem(find_menu, "Find…", "showFind:", "f", mod_command, app.view);
    addTargetedModifiedMenuItem(find_menu, "Find Next", "findNext:", "g", mod_command, app.view);
    addTargetedModifiedMenuItem(find_menu, "Find Previous", "findPrevious:", "g", mod_command | mod_shift, app.view);
    objc.setId(find_item, objc.sel("setSubmenu:"), find_menu);
    objc.setId(edit_item, objc.sel("setSubmenu:"), edit_menu);

    // View menu: the vertical session sidebar has one optional state: hidden.
    const view_item = objc.allocInit(objc.cls("NSMenuItem"));
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        main_menu,
        objc.sel("addItem:"),
        view_item,
    );
    const view_menu = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(objc.cls("NSMenu"), objc.sel("alloc")),
        objc.sel("initWithTitle:"),
        objc.nsString("View"),
    );
    addMenuItem(view_menu, "Toggle Session Bar", "toggleSessionBar:", "b");
    addMenuSeparator(view_menu);
    addModifiedMenuItem(view_menu, "Bigger Text", "increaseFontSize:", "+", mod_command);
    addModifiedMenuItem(view_menu, "Smaller Text", "decreaseFontSize:", "-", mod_command);
    addModifiedMenuItem(view_menu, "Actual Size", "resetFontSize:", "0", mod_command);
    objc.setId(view_item, objc.sel("setSubmenu:"), view_menu);

    // Session menu: creation and direct position-based switching (RFC 0006).
    const session_item = objc.allocInit(objc.cls("NSMenuItem"));
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        main_menu,
        objc.sel("addItem:"),
        session_item,
    );
    const session_menu = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(objc.cls("NSMenu"), objc.sel("alloc")),
        objc.sel("initWithTitle:"),
        objc.nsString("Session"),
    );
    addMenuItem(session_menu, "New Session", "newSession:", "t");
    addMenuItem(session_menu, "New Session Beside Current", "newSessionBeside:", "d");
    addMenuItem(session_menu, "Close Session", "closeSession:", "w");
    addModifiedMenuItem(session_menu, "Previous Session", "previousSession:", "[", mod_command | mod_shift);
    addModifiedMenuItem(session_menu, "Next Session", "nextSession:", "]", mod_command | mod_shift);
    addMenuSeparator(session_menu);
    addMenuItem(session_menu, "Pair With Previous Session", "pairWithPreviousSession:", "");
    addMenuItem(session_menu, "Pair With Next Session", "pairWithNextSession:", "");
    addMenuItem(session_menu, "Separate Sessions", "separateSessions:", "");
    addMenuItem(session_menu, "Swap Paired Session Sides", "swapSessionSides:", "");
    addModifiedMenuItem(session_menu, "Focus Left Pane", "focusLeftPane:", "\u{f702}", mod_command | mod_option);
    addModifiedMenuItem(session_menu, "Focus Right Pane", "focusRightPane:", "\u{f703}", mod_command | mod_option);
    addModifiedMenuItem(session_menu, "Move Pane Left", "movePaneLeft:", "\u{f702}", mod_command | mod_option | mod_shift);
    addModifiedMenuItem(session_menu, "Move Pane Right", "movePaneRight:", "\u{f703}", mod_command | mod_option | mod_shift);
    addModifiedMenuItem(session_menu, "Focus Previous Session Group", "focusPreviousSessionGroup:", "\u{f700}", mod_command | mod_option);
    addModifiedMenuItem(session_menu, "Focus Next Session Group", "focusNextSessionGroup:", "\u{f701}", mod_command | mod_option);
    addModifiedMenuItem(session_menu, "Move Session Group Up", "moveSessionGroupUp:", "\u{f700}", mod_command | mod_option | mod_shift);
    addModifiedMenuItem(session_menu, "Move Session Group Down", "moveSessionGroupDown:", "\u{f701}", mod_command | mod_option | mod_shift);
    addModifiedMenuItem(session_menu, "Zoom Focused Pane", "togglePairZoom:", "\r", mod_command | mod_shift);
    addMenuSeparator(session_menu);
    addTaggedMenuItem(session_menu, "Session 1", "selectNumberedSession:", "1", 1);
    addTaggedMenuItem(session_menu, "Session 2", "selectNumberedSession:", "2", 2);
    addTaggedMenuItem(session_menu, "Session 3", "selectNumberedSession:", "3", 3);
    addTaggedMenuItem(session_menu, "Session 4", "selectNumberedSession:", "4", 4);
    addTaggedMenuItem(session_menu, "Session 5", "selectNumberedSession:", "5", 5);
    addTaggedMenuItem(session_menu, "Session 6", "selectNumberedSession:", "6", 6);
    addTaggedMenuItem(session_menu, "Session 7", "selectNumberedSession:", "7", 7);
    addTaggedMenuItem(session_menu, "Session 8", "selectNumberedSession:", "8", 8);
    addTaggedMenuItem(session_menu, "Session 9", "selectNumberedSession:", "9", 9);
    objc.setId(session_item, objc.sel("setSubmenu:"), session_menu);

    const help_item = objc.allocInit(objc.cls("NSMenuItem"));
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        main_menu,
        objc.sel("addItem:"),
        help_item,
    );
    const help_menu = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(objc.cls("NSMenu"), objc.sel("alloc")),
        objc.sel("initWithTitle:"),
        objc.nsString("Help"),
    );
    addTargetedModifiedMenuItem(
        help_menu,
        "Keyboard Shortcuts",
        "showKeyboardShortcuts:",
        "/",
        mod_command | mod_shift,
        app.view,
    );
    objc.setId(help_item, objc.sel("setSubmenu:"), help_menu);
    objc.setId(ns_app, objc.sel("setHelpMenu:"), help_menu);

    objc.setId(ns_app, objc.sel("setMainMenu:"), main_menu);
}

fn addMenuSeparator(menu: objc.Id) void {
    const separator = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSMenuItem"),
        objc.sel("separatorItem"),
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        menu,
        objc.sel("addItem:"),
        separator,
    );
}

fn addMenuItem(menu: objc.Id, title: [*:0]const u8, action: [*:0]const u8, key: [*:0]const u8) void {
    const item_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSMenuItem"),
        objc.sel("alloc"),
    );
    const item = objc.msg(
        *const fn (objc.Id, objc.Sel, objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id,
    )(
        item_alloc,
        objc.sel("initWithTitle:action:keyEquivalent:"),
        objc.nsString(title),
        objc.sel(action),
        objc.nsString(key),
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        menu,
        objc.sel("addItem:"),
        item,
    );
}

fn addTaggedMenuItem(
    menu: objc.Id,
    title: [*:0]const u8,
    action: [*:0]const u8,
    key: [*:0]const u8,
    tag: objc.NSUInteger,
) void {
    const item_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSMenuItem"),
        objc.sel("alloc"),
    );
    const item = objc.msg(
        *const fn (objc.Id, objc.Sel, objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id,
    )(
        item_alloc,
        objc.sel("initWithTitle:action:keyEquivalent:"),
        objc.nsString(title),
        objc.sel(action),
        objc.nsString(key),
    );
    objc.setU(item, objc.sel("setTag:"), tag);
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        menu,
        objc.sel("addItem:"),
        item,
    );
}

fn addModifiedMenuItem(
    menu: objc.Id,
    title: [*:0]const u8,
    action: [*:0]const u8,
    key: [*:0]const u8,
    modifiers: objc.NSUInteger,
) void {
    const item_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSMenuItem"),
        objc.sel("alloc"),
    );
    const item = objc.msg(
        *const fn (objc.Id, objc.Sel, objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id,
    )(
        item_alloc,
        objc.sel("initWithTitle:action:keyEquivalent:"),
        objc.nsString(title),
        objc.sel(action),
        objc.nsString(key),
    );
    objc.setU(item, objc.sel("setKeyEquivalentModifierMask:"), modifiers);
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        menu,
        objc.sel("addItem:"),
        item,
    );
}

fn addTargetedModifiedMenuItem(
    menu: objc.Id,
    title: [*:0]const u8,
    action: [*:0]const u8,
    key: [*:0]const u8,
    modifiers: objc.NSUInteger,
    target: objc.Id,
) void {
    const item_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSMenuItem"),
        objc.sel("alloc"),
    );
    const item = objc.msg(
        *const fn (objc.Id, objc.Sel, objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id,
    )(
        item_alloc,
        objc.sel("initWithTitle:action:keyEquivalent:"),
        objc.nsString(title),
        objc.sel(action),
        objc.nsString(key),
    );
    objc.setU(item, objc.sel("setKeyEquivalentModifierMask:"), modifiers);
    objc.setId(item, objc.sel("setTarget:"), target);
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        menu,
        objc.sel("addItem:"),
        item,
    );
}
