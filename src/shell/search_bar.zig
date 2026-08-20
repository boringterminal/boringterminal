//! Reusable native search-bar chrome and editing (RFC 0017).
//!
//! Matching and result ownership stay with the host. This component owns one
//! NSSearchField and the AppKit invariants around its shared field editor.

const std = @import("std");
const objc = @import("../render/objc.zig");

const preferred_width: f32 = 350;
const bar_height: f32 = 32;
const margin: f32 = 10;
const field_min_width: f32 = 96;
const full_controls_min_width: f32 = 300;
const navigation_min_width: f32 = 240;
const context_ivar = "_boringSearchBar";
const layout_attribute_center_y: objc.NSUInteger = 10;
const stack_distribution_fill: objc.NSUInteger = 0;

pub const Status = union(enum) {
    idle,
    searching,
    no_results,
    invalid: []const u8,
    result: struct {
        index: u32,
        total: u32,
        truncated: bool,
    },
};

pub const Options = struct {
    parent: objc.Id,
    target: objc.Id,
    placeholder: [*:0]const u8,
    query_action: objc.Sel,
    previous_action: objc.Sel,
    next_action: objc.Sel,
    close_action: objc.Sel,
    movable: bool = true,
};

pub const Layout = struct {
    width: f32,
    show_status: bool,
    show_navigation: bool,
};

pub fn calculateLayout(available_width: f32) Layout {
    const width = @max(@as(f32, 1), @min(preferred_width, available_width));
    const show_status = width >= full_controls_min_width;
    const show_navigation = width >= navigation_min_width;
    return .{
        .width = width,
        .show_status = show_status,
        .show_navigation = show_navigation,
    };
}

pub const SearchBar = struct {
    overlay: objc.Id = null,
    stack: objc.Id = null,
    handle: objc.Id = null,
    field: objc.Id = null,
    status_label: objc.Id = null,
    previous_button: objc.Id = null,
    next_button: objc.Id = null,
    close_button: objc.Id = null,
    host: objc.CGRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } },
    movable: bool = true,
    visible: bool = false,
    drag_active: bool = false,
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    drag_anchor_x: f32 = 0,
    drag_anchor_y: f32 = 0,
    drag_start_x: f32 = 0,
    drag_start_y: f32 = 0,

    pub fn init(self: *SearchBar, options: Options) !void {
        self.* = .{ .movable = options.movable };

        const overlay_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
            objc.cls("NSVisualEffectView"),
            objc.sel("alloc"),
        );
        self.overlay = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect) callconv(.c) objc.Id)(
            overlay_alloc,
            objc.sel("initWithFrame:"),
            .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = preferred_width, .height = bar_height } },
        );
        if (self.overlay == null) return error.ViewCreate;
        objc.setU(self.overlay, objc.sel("setMaterial:"), 6); // popover
        objc.setU(self.overlay, objc.sel("setBlendingMode:"), 1); // within window
        objc.setU(self.overlay, objc.sel("setState:"), 1);
        objc.setU(self.overlay, objc.sel("setWantsLayer:"), 1);
        objc.setU(self.overlay, objc.sel("setHidden:"), 1);
        objc.setId(self.overlay, objc.sel("setAccessibilityLabel:"), objc.nsString("Find Bar"));
        const overlay_layer = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
            self.overlay,
            objc.sel("layer"),
        );
        objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat) callconv(.c) void)(
            overlay_layer,
            objc.sel("setCornerRadius:"),
            7,
        );
        objc.setU(overlay_layer, objc.sel("setMasksToBounds:"), 1);
        const separator = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
            objc.cls("NSColor"),
            objc.sel("separatorColor"),
        );
        const separator_cg = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
            separator,
            objc.sel("CGColor"),
        );
        objc.setId(overlay_layer, objc.sel("setBorderColor:"), separator_cg);
        objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat) callconv(.c) void)(
            overlay_layer,
            objc.sel("setBorderWidth:"),
            0.5,
        );

        if (self.movable) {
            self.handle = makeHandle(self);
            if (self.handle == null) return error.ViewCreate;
        }

        const field_alloc = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
            objc.cls("NSSearchField"),
            objc.sel("alloc"),
        );
        self.field = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect) callconv(.c) objc.Id)(
            field_alloc,
            objc.sel("initWithFrame:"),
            .{ .origin = .{ .x = 18, .y = 4 }, .size = .{ .width = 163, .height = 24 } },
        );
        if (self.field == null) return error.ViewCreate;
        objc.setId(self.field, objc.sel("setPlaceholderString:"), objc.nsString(options.placeholder));
        objc.setId(self.field, objc.sel("setAccessibilityLabel:"), objc.nsString(options.placeholder));
        objc.setId(self.field, objc.sel("setTarget:"), options.target);
        objc.msg(*const fn (objc.Id, objc.Sel, objc.Sel) callconv(.c) void)(
            self.field,
            objc.sel("setAction:"),
            options.query_action,
        );
        objc.setId(self.field, objc.sel("setDelegate:"), options.target);
        objc.setU(self.field, objc.sel("setSendsSearchStringImmediately:"), 1);
        objc.setU(self.field, objc.sel("setAllowsExpansionToolTips:"), 1);
        const cell = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
            self.field,
            objc.sel("cell"),
        );
        objc.setU(cell, objc.sel("setUsesSingleLineMode:"), 1);
        objc.setU(cell, objc.sel("setScrollable:"), 1);
        objc.setU(cell, objc.sel("setWraps:"), 0);

        self.status_label = objc.msg(*const fn (objc.Class, objc.Sel, objc.Id) callconv(.c) objc.Id)(
            objc.cls("NSTextField"),
            objc.sel("labelWithString:"),
            objc.nsString(""),
        );
        if (self.status_label == null) return error.ViewCreate;
        objc.setU(self.status_label, objc.sel("setAlignment:"), 2);
        const status_font = objc.msg(*const fn (objc.Class, objc.Sel, objc.CGFloat, objc.CGFloat) callconv(.c) objc.Id)(
            objc.cls("NSFont"),
            objc.sel("systemFontOfSize:weight:"),
            13,
            0,
        );
        objc.setId(self.status_label, objc.sel("setFont:"), status_font);
        objc.setId(self.status_label, objc.sel("setTextColor:"), objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
            objc.cls("NSColor"),
            objc.sel("secondaryLabelColor"),
        ));
        objc.setId(self.status_label, objc.sel("setAccessibilityLabel:"), objc.nsString("Search Results"));

        self.previous_button = makeChevronButton(options.target, .up, options.previous_action, "Previous Match", "Previous Match (⇧⌘G)");
        self.next_button = makeChevronButton(options.target, .down, options.next_action, "Next Match", "Next Match (⌘G)");
        self.close_button = makeButton(options.target, "×", options.close_action, "Close Find", "Close Find (Esc)");
        for ([_]objc.Id{ self.previous_button, self.next_button, self.close_button }) |button| {
            if (button == null) return error.ViewCreate;
        }

        var arranged: [6]objc.Id = undefined;
        var arranged_len: usize = 0;
        if (self.handle != null) {
            arranged[arranged_len] = self.handle;
            arranged_len += 1;
        }
        for ([_]objc.Id{
            self.field,
            self.status_label,
            self.previous_button,
            self.next_button,
            self.close_button,
        }) |view| {
            arranged[arranged_len] = view;
            arranged_len += 1;
        }
        const arranged_views = objc.msg(*const fn (objc.Class, objc.Sel, [*]const objc.Id, objc.NSUInteger) callconv(.c) objc.Id)(
            objc.cls("NSArray"),
            objc.sel("arrayWithObjects:count:"),
            arranged[0..arranged_len].ptr,
            arranged_len,
        );
        self.stack = objc.msg(*const fn (objc.Class, objc.Sel, objc.Id) callconv(.c) objc.Id)(
            objc.cls("NSStackView"),
            objc.sel("stackViewWithViews:"),
            arranged_views,
        );
        if (self.stack == null) return error.ViewCreate;
        objc.setU(self.stack, objc.sel("setTranslatesAutoresizingMaskIntoConstraints:"), 0);
        objc.setU(self.stack, objc.sel("setOrientation:"), 0); // horizontal
        objc.setU(self.stack, objc.sel("setAlignment:"), layout_attribute_center_y);
        objc.setU(self.stack, objc.sel("setDistribution:"), stack_distribution_fill);
        objc.setU(self.stack, objc.sel("setDetachesHiddenViews:"), 1);
        objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat) callconv(.c) void)(
            self.stack,
            objc.sel("setSpacing:"),
            4,
        );
        objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat, objc.Id) callconv(.c) void)(
            self.stack,
            objc.sel("setCustomSpacing:afterView:"),
            0,
            self.previous_button,
        );
        if (self.handle != null) objc.msg(
            *const fn (objc.Id, objc.Sel, objc.CGFloat, objc.Id) callconv(.c) void,
        )(
            self.stack,
            objc.sel("setCustomSpacing:afterView:"),
            2,
            self.handle,
        );

        if (self.handle != null) constrainSize(self.handle, 12, 24);
        constrainMinimumWidth(self.field, field_min_width, 500);
        constrainWidth(self.status_label, 66);
        for ([_]objc.Id{ self.previous_button, self.next_button, self.close_button }) |button|
            constrainSize(button, 24, 24);
        setHorizontalLayoutPriority(self.field, 1, 250);
        setHorizontalLayoutPriority(self.status_label, 750, 750);
        for ([_]objc.Id{ self.previous_button, self.next_button, self.close_button }) |button|
            setHorizontalLayoutPriority(button, 750, 750);
        addSubview(self.overlay, self.stack);
        constrainEdge(self.stack, "leadingAnchor", self.overlay, "leadingAnchor", 4);
        constrainEdge(self.stack, "trailingAnchor", self.overlay, "trailingAnchor", -4);
        constrainEdge(self.stack, "topAnchor", self.overlay, "topAnchor", 4);
        constrainEdge(self.stack, "bottomAnchor", self.overlay, "bottomAnchor", -4);
        addSubview(options.parent, self.overlay);
    }

    pub fn deinit(self: *SearchBar) void {
        if (self.handle != null) objc.setPointerIvar(self.handle, context_ivar, null);
        if (self.overlay != null)
            objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(self.overlay, objc.sel("removeFromSuperview"));
        if (self.field != null) objc.release(self.field);
        if (self.handle != null) objc.release(self.handle);
        if (self.overlay != null) objc.release(self.overlay);
        self.* = .{};
    }

    pub fn layout(self: *SearchBar, host: objc.CGRect) void {
        if (self.overlay == null) return;
        self.host = host;
        const available = @max(@as(f32, 1), @as(f32, @floatCast(host.size.width)) - margin * 2);
        const frames = calculateLayout(available);
        const default_x: f32 = @floatCast(host.origin.x + host.size.width - frames.width - margin);
        const default_y: f32 = @floatCast(host.origin.y + host.size.height - bar_height - margin);
        const min_x: f32 = @floatCast(host.origin.x + margin);
        const min_y: f32 = @floatCast(host.origin.y + margin);
        const origin_x = @min(@max(default_x + self.offset_x, min_x), default_x);
        const origin_y = @min(@max(default_y + self.offset_y, min_y), default_y);
        self.offset_x = origin_x - default_x;
        self.offset_y = origin_y - default_y;
        setFrame(self.overlay, .{
            .origin = .{ .x = origin_x, .y = origin_y },
            .size = .{ .width = frames.width, .height = bar_height },
        });
        objc.setU(self.status_label, objc.sel("setHidden:"), @intFromBool(!frames.show_status));
        objc.setU(self.previous_button, objc.sel("setHidden:"), @intFromBool(!frames.show_navigation));
        objc.setU(self.next_button, objc.sel("setHidden:"), @intFromBool(!frames.show_navigation));
        objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(self.overlay, objc.sel("layoutSubtreeIfNeeded"));
        self.ensureSelectionVisible();
    }

    pub fn showAndFocus(self: *SearchBar, window: objc.Id) void {
        if (self.overlay == null or self.field == null) return;
        self.visible = true;
        objc.setU(self.overlay, objc.sel("setHidden:"), 0);
        _ = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.BOOL)(
            window,
            objc.sel("makeFirstResponder:"),
            self.field,
        );
        objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
            self.field,
            objc.sel("selectText:"),
            null,
        );
        self.ensureSelectionVisible();
    }

    pub fn hideAndClear(self: *SearchBar) void {
        self.visible = false;
        self.drag_active = false;
        self.offset_x = 0;
        self.offset_y = 0;
        self.replaceEditorText("");
        if (self.overlay != null) objc.setU(self.overlay, objc.sel("setHidden:"), 1);
        self.setStatus(.idle);
    }

    pub fn query(self: *const SearchBar) ?[]const u8 {
        if (self.field == null) return null;
        // While editing, the window's shared NSTextView field editor is the
        // authoritative value. Reading the cell can lag an immediate-search
        // callback and made long edits appear to stop at the visible edge.
        const value = if (self.currentEditor()) |editor|
            objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
                editor,
                objc.sel("string"),
            )
        else
            objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
                self.field,
                objc.sel("stringValue"),
            );
        return stringUtf8(value);
    }

    pub fn hasMarkedText(self: *const SearchBar) bool {
        const editor = self.currentEditor() orelse return false;
        return objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.BOOL)(
            editor,
            objc.sel("hasMarkedText"),
        ) != 0;
    }

    pub fn ensureSelectionVisible(self: *const SearchBar) void {
        const editor = self.currentEditor() orelse return;
        const selected = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.NSRange)(
            editor,
            objc.sel("selectedRange"),
        );
        objc.msg(*const fn (objc.Id, objc.Sel, objc.NSRange) callconv(.c) void)(
            editor,
            objc.sel("scrollRangeToVisible:"),
            selected,
        );
    }

    pub fn setStatus(self: *SearchBar, status: Status) void {
        if (self.status_label == null) return;
        var buf: [64]u8 = undefined;
        const text: []const u8 = switch (status) {
            .idle => "",
            .searching => "…",
            .no_results => "No results",
            .invalid => |reason| reason,
            .result => |result| if (result.truncated)
                std.fmt.bufPrint(&buf, "{d} of {d}+", .{ result.index, result.total }) catch ""
            else
                std.fmt.bufPrint(&buf, "{d} of {d}", .{ result.index, result.total }) catch "",
        };
        const value = objc.nsStringFromBytes(text);
        if (value == null) return;
        defer objc.release(value);
        objc.setId(self.status_label, objc.sel("setStringValue:"), value);
        objc.setId(self.status_label, objc.sel("setAccessibilityValue:"), value);
        // The compact tiers visually hide the label; mirror its value onto
        // the containing accessibility group so the state remains exposed.
        objc.setId(self.overlay, objc.sel("setAccessibilityValue:"), value);
    }

    fn currentEditor(self: *const SearchBar) ?objc.Id {
        if (self.field == null) return null;
        const editor = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
            self.field,
            objc.sel("currentEditor"),
        );
        return if (editor == null) null else editor;
    }

    fn replaceEditorText(self: *SearchBar, text: []const u8) void {
        if (self.field == null) return;
        const value = objc.nsStringFromBytes(text);
        if (value == null) return;
        defer objc.release(value);
        if (self.currentEditor()) |editor| {
            objc.setId(editor, objc.sel("setString:"), value);
            objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(
                self.field,
                objc.sel("validateEditing"),
            );
        } else {
            objc.setId(self.field, objc.sel("setStringValue:"), value);
        }
    }
};

var handle_class: objc.Class = null;

fn ensureHandleClass() objc.Class {
    if (handle_class != null) return handle_class;
    const class = objc.allocateClass(objc.cls("NSView"), "BoringTerminalSearchBarHandleView");
    objc.addPointerIvar(class, context_ivar);
    objc.addMethod(class, objc.sel("mouseDown:"), @ptrCast(@constCast(&handleMouseDown)), "v@:@");
    objc.addMethod(class, objc.sel("mouseDragged:"), @ptrCast(@constCast(&handleMouseDragged)), "v@:@");
    objc.addMethod(class, objc.sel("mouseUp:"), @ptrCast(@constCast(&handleMouseUp)), "v@:@");
    objc.addMethod(class, objc.sel("resetCursorRects"), @ptrCast(@constCast(&handleResetCursorRects)), "v@:");
    objc.registerClass(class);
    handle_class = class;
    return class;
}

fn barFromHandle(handle: objc.Id) ?*SearchBar {
    return @ptrCast(@alignCast(objc.getPointerIvar(handle, context_ivar) orelse return null));
}

fn eventPoint(event: objc.Id) objc.CGPoint {
    return objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGPoint)(
        event,
        objc.sel("locationInWindow"),
    );
}

fn handleMouseDown(self: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    const bar = barFromHandle(self) orelse return;
    const point = eventPoint(event);
    bar.drag_active = true;
    bar.drag_anchor_x = @floatCast(point.x);
    bar.drag_anchor_y = @floatCast(point.y);
    bar.drag_start_x = bar.offset_x;
    bar.drag_start_y = bar.offset_y;
    setCursor("closedHandCursor");
}

fn handleMouseDragged(self: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    const bar = barFromHandle(self) orelse return;
    if (!bar.drag_active) return;
    const point = eventPoint(event);
    bar.offset_x = bar.drag_start_x + @as(f32, @floatCast(point.x)) - bar.drag_anchor_x;
    bar.offset_y = bar.drag_start_y + @as(f32, @floatCast(point.y)) - bar.drag_anchor_y;
    bar.layout(bar.host);
}

fn handleMouseUp(self: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    const bar = barFromHandle(self) orelse return;
    if (!bar.drag_active) return;
    bar.drag_active = false;
    setCursor("openHandCursor");
}

fn handleResetCursorRects(self: objc.Id, selector: objc.Sel) callconv(.c) void {
    var super_ctx: objc.Super = .{ .receiver = self, .super_class = objc.cls("NSView") };
    objc.msgSuper(*const fn (*objc.Super, objc.Sel) callconv(.c) void)(&super_ctx, selector);
    const bounds = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.CGRect)(
        self,
        objc.sel("bounds"),
    );
    const cursor = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSCursor"),
        objc.sel("openHandCursor"),
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect, objc.Id) callconv(.c) void)(
        self,
        objc.sel("addCursorRect:cursor:"),
        bounds,
        cursor,
    );
}

fn makeHandle(bar: *SearchBar) objc.Id {
    const alloced = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        ensureHandleClass(),
        objc.sel("alloc"),
    );
    const handle = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect) callconv(.c) objc.Id)(
        alloced,
        objc.sel("initWithFrame:"),
        .{ .origin = .{ .x = 4, .y = 4 }, .size = .{ .width = 12, .height = 24 } },
    );
    if (handle == null) return null;
    objc.setPointerIvar(handle, context_ivar, bar);
    objc.setU(handle, objc.sel("setWantsLayer:"), 1);
    objc.setId(handle, objc.sel("setToolTip:"), objc.nsString("Move Find Bar"));
    objc.setId(handle, objc.sel("setAccessibilityLabel:"), objc.nsString("Move Find Bar"));
    const layer = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(handle, objc.sel("layer"));
    const color = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSColor"),
        objc.sel("secondaryLabelColor"),
    );
    const cg_color = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        color,
        objc.sel("CGColor"),
    );
    for ([_]f64{ 7, 11.5, 16 }) |y| for ([_]f64{ 3.5, 7.5 }) |x| {
        const dot = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
            objc.cls("CALayer"),
            objc.sel("layer"),
        );
        objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect) callconv(.c) void)(
            dot,
            objc.sel("setFrame:"),
            .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = 1.25, .height = 1.25 } },
        );
        objc.setId(dot, objc.sel("setBackgroundColor:"), cg_color);
        objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat) callconv(.c) void)(
            dot,
            objc.sel("setCornerRadius:"),
            0.625,
        );
        objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
            layer,
            objc.sel("addSublayer:"),
            dot,
        );
    };
    return handle;
}

fn makeButton(
    target: objc.Id,
    title: [*:0]const u8,
    action: objc.Sel,
    accessibility_label: [*:0]const u8,
    tooltip: [*:0]const u8,
) objc.Id {
    const button = objc.msg(*const fn (objc.Class, objc.Sel, objc.Id, objc.Id, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSButton"),
        objc.sel("buttonWithTitle:target:action:"),
        objc.nsString(title),
        target,
        action,
    );
    if (button == null) return null;
    objc.setU(button, objc.sel("setBordered:"), 0);
    objc.setId(button, objc.sel("setToolTip:"), objc.nsString(tooltip));
    objc.setId(button, objc.sel("setAccessibilityLabel:"), objc.nsString(accessibility_label));
    const font = objc.msg(*const fn (objc.Class, objc.Sel, objc.CGFloat) callconv(.c) objc.Id)(
        objc.cls("NSFont"),
        objc.sel("systemFontOfSize:"),
        17,
    );
    objc.setId(button, objc.sel("setFont:"), font);
    return button;
}

const ChevronDirection = enum { up, down };

fn makeChevronButton(
    target: objc.Id,
    direction: ChevronDirection,
    action: objc.Sel,
    accessibility_label: [*:0]const u8,
    tooltip: [*:0]const u8,
) objc.Id {
    const image = makeChevronImage(direction);
    if (image == null) return null;
    defer objc.release(image);
    const button = objc.msg(*const fn (objc.Class, objc.Sel, objc.Id, objc.Id, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSButton"),
        objc.sel("buttonWithImage:target:action:"),
        image,
        target,
        action,
    );
    if (button == null) return null;
    objc.setU(button, objc.sel("setBordered:"), 0);
    objc.setU(button, objc.sel("setImagePosition:"), 1); // image only
    objc.setU(button, objc.sel("setImageScaling:"), 0); // proportionally down
    objc.setId(button, objc.sel("setToolTip:"), objc.nsString(tooltip));
    objc.setId(button, objc.sel("setAccessibilityLabel:"), objc.nsString(accessibility_label));
    const tint = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSColor"),
        objc.sel("secondaryLabelColor"),
    );
    objc.setId(button, objc.sel("setContentTintColor:"), tint);
    return button;
}

fn makeChevronImage(direction: ChevronDirection) objc.Id {
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
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat) callconv(.c) void)(
        path,
        objc.sel("setLineWidth:"),
        1.5,
    );
    objc.setU(path, objc.sel("setLineCapStyle:"), 1); // round
    objc.setU(path, objc.sel("setLineJoinStyle:"), 1); // round
    const edge_y: f64 = if (direction == .up) 3.25 else 6.75;
    const point_y: f64 = if (direction == .up) 6.75 else 3.25;
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGPoint) callconv(.c) void)(
        path,
        objc.sel("moveToPoint:"),
        .{ .x = 1.75, .y = edge_y },
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGPoint) callconv(.c) void)(
        path,
        objc.sel("lineToPoint:"),
        .{ .x = 5, .y = point_y },
    );
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGPoint) callconv(.c) void)(
        path,
        objc.sel("lineToPoint:"),
        .{ .x = 8.25, .y = edge_y },
    );
    objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(path, objc.sel("stroke"));
    objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(image, objc.sel("unlockFocus"));
    objc.setU(image, objc.sel("setTemplate:"), 1);
    return image;
}

fn setCursor(selector: [*:0]const u8) void {
    const cursor = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.cls("NSCursor"),
        objc.sel(selector),
    );
    objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) void)(cursor, objc.sel("set"));
}

fn addSubview(parent: objc.Id, child: objc.Id) void {
    objc.msg(*const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        parent,
        objc.sel("addSubview:"),
        child,
    );
}

fn setFrame(view: objc.Id, frame: objc.CGRect) void {
    if (view == null) return;
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect) callconv(.c) void)(
        view,
        objc.sel("setFrame:"),
        frame,
    );
}

fn anchor(view: objc.Id, selector: [*:0]const u8) objc.Id {
    return objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(
        view,
        objc.sel(selector),
    );
}

fn constantConstraint(view: objc.Id, anchor_selector: [*:0]const u8, constant: f64) objc.Id {
    return objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat) callconv(.c) objc.Id)(
        anchor(view, anchor_selector),
        objc.sel("constraintEqualToConstant:"),
        constant,
    );
}

fn activateConstraint(constraint: objc.Id) void {
    objc.setU(constraint, objc.sel("setActive:"), 1);
}

fn constrainEdge(
    view: objc.Id,
    view_anchor: [*:0]const u8,
    other: objc.Id,
    other_anchor: [*:0]const u8,
    constant: f64,
) void {
    const constraint = objc.msg(*const fn (objc.Id, objc.Sel, objc.Id, objc.CGFloat) callconv(.c) objc.Id)(
        anchor(view, view_anchor),
        objc.sel("constraintEqualToAnchor:constant:"),
        anchor(other, other_anchor),
        constant,
    );
    activateConstraint(constraint);
}

fn constrainWidth(view: objc.Id, width: f64) void {
    activateConstraint(constantConstraint(view, "widthAnchor", width));
}

fn constrainSize(view: objc.Id, width: f64, height: f64) void {
    constrainWidth(view, width);
    activateConstraint(constantConstraint(view, "heightAnchor", height));
}

fn constrainMinimumWidth(view: objc.Id, width: f64, priority: f32) void {
    const constraint = objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat) callconv(.c) objc.Id)(
        anchor(view, "widthAnchor"),
        objc.sel("constraintGreaterThanOrEqualToConstant:"),
        width,
    );
    objc.msg(*const fn (objc.Id, objc.Sel, f32) callconv(.c) void)(
        constraint,
        objc.sel("setPriority:"),
        priority,
    );
    activateConstraint(constraint);
}

fn setHorizontalLayoutPriority(view: objc.Id, hugging: f32, compression: f32) void {
    objc.msg(*const fn (objc.Id, objc.Sel, f32, objc.NSUInteger) callconv(.c) void)(
        view,
        objc.sel("setContentHuggingPriority:forOrientation:"),
        hugging,
        0,
    );
    objc.msg(*const fn (objc.Id, objc.Sel, f32, objc.NSUInteger) callconv(.c) void)(
        view,
        objc.sel("setContentCompressionResistancePriority:forOrientation:"),
        compression,
        0,
    );
}

fn stringUtf8(value: objc.Id) ?[]const u8 {
    if (value == null) return null;
    const c_string = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) ?[*:0]const u8)(
        value,
        objc.sel("UTF8String"),
    ) orelse return null;
    return std.mem.span(c_string);
}

test "preferred layout shows the complete native stack" {
    const layout = calculateLayout(350);
    try std.testing.expectEqual(@as(f32, 350), layout.width);
    try std.testing.expect(layout.show_status);
    try std.testing.expect(layout.show_navigation);
}

test "compact layout hides status before navigation" {
    const layout = calculateLayout(270);
    try std.testing.expect(!layout.show_status);
    try std.testing.expect(layout.show_navigation);
}

test "minimum layout leaves only the irreducible native controls" {
    const layout = calculateLayout(180);
    try std.testing.expect(!layout.show_status);
    try std.testing.expect(!layout.show_navigation);
}

test "outer width is capped and never becomes negative" {
    try std.testing.expectEqual(@as(f32, 350), calculateLayout(900).width);
    try std.testing.expectEqual(@as(f32, 1), calculateLayout(-20).width);
}
