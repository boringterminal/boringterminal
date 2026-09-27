//! Native recovery chrome. All state changes stay with the window host.
const objc = @import("../render/objc.zig");

pub const Notice = struct {
    view: objc.Id = null,
    label: objc.Id = null,
    detail: objc.Id = null,
    primary: objc.Id = null,
    secondary: objc.Id = null,
    visible: bool = false,
    banner: bool = false,

    pub fn init(self: *Notice, parent: objc.Id, target: objc.Id, primary: [*:0]const u8, secondary: [*:0]const u8) !void {
        self.view = objc.allocInit(objc.cls("NSVisualEffectView"));
        if (self.view == null) return error.ViewCreate;
        objc.setU(self.view, objc.sel("setMaterial:"), 6);
        objc.setU(self.view, objc.sel("setBlendingMode:"), 1);
        objc.setU(self.view, objc.sel("setState:"), 1);
        self.label = makeLabel();
        self.detail = makeLabel();
        const font = objc.msg(*const fn (objc.Class, objc.Sel, objc.CGFloat, objc.CGFloat) callconv(.c) objc.Id)(objc.cls("NSFont"), objc.sel("systemFontOfSize:weight:"), 13, 0.23);
        objc.setId(self.label, objc.sel("setFont:"), font);
        const detail_font = objc.msg(*const fn (objc.Class, objc.Sel, objc.CGFloat) callconv(.c) objc.Id)(objc.cls("NSFont"), objc.sel("systemFontOfSize:"), 12);
        objc.setId(self.detail, objc.sel("setFont:"), detail_font);
        const secondary_color = objc.msg(*const fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(objc.cls("NSColor"), objc.sel("secondaryLabelColor"));
        objc.setId(self.detail, objc.sel("setTextColor:"), secondary_color);
        self.primary = makeButton(target, primary);
        self.secondary = makeButton(target, secondary);
        for ([_]objc.Id{ self.label, self.detail, self.primary, self.secondary }) |child| {
            if (child == null) return error.ViewCreate;
            objc.setId(self.view, objc.sel("addSubview:"), child);
        }
        objc.setId(parent, objc.sel("addSubview:"), self.view);
        objc.release(self.view); // parent owns it
        self.hide();
    }

    pub fn hide(self: *Notice) void {
        self.visible = false;
        if (self.view != null) objc.setU(self.view, objc.sel("setHidden:"), 1);
    }

    pub fn show(self: *Notice, frame: objc.CGRect, title: []const u8, detail: []const u8, first: []const u8, second: []const u8, enabled: bool, tag: u64) void {
        if (self.view == null) return;
        self.visible = true;
        objc.setU(self.view, objc.sel("setHidden:"), 0);
        setFrame(self.view, frame);
        setText(self.label, "setStringValue:", title);
        setText(self.detail, "setStringValue:", detail);
        setText(self.view, "setAccessibilityLabel:", title);
        setText(self.detail, "setToolTip:", detail);
        const w = @max(1, frame.size.width - 32);
        const h = frame.size.height;
        const compact = w < 250;
        if (self.banner and frame.size.width >= 660) {
            setFrame(self.label, rect(16, h / 2 + 1, w - 252, 22));
            setFrame(self.detail, rect(16, h / 2 - 21, w - 252, 22));
            setFrame(self.primary, rect(frame.size.width - 250, h / 2 - 14, 142, 28));
            setFrame(self.secondary, rect(frame.size.width - 102, h / 2 - 14, 88, 28));
        } else {
            const buttons_height: f64 = if (compact and second.len != 0) 58 else 28;
            const detail_height: f64 = if (h < 115 and !self.banner) 0 else 30;
            const base = @max(8, (h - (buttons_height + detail_height + 32)) / 2);
            setFrame(self.label, rect(16, base + buttons_height + detail_height, w, 32));
            setFrame(self.detail, rect(16, base + buttons_height, w, detail_height));
            setFrame(self.primary, rect(14, if (compact and second.len != 0) base + 29 else base, @min(w, 142), 28));
            setFrame(self.secondary, rect(if (compact) 14 else 164, base, @min(w, 110), 28));
        }
        objc.setU(self.detail, objc.sel("setHidden:"), @intFromBool(h < 115 and !self.banner));
        inline for (.{ .{ self.primary, first }, .{ self.secondary, second } }) |button| {
            setText(button[0], "setTitle:", button[1]);
            objc.setU(button[0], objc.sel("setHidden:"), @intFromBool(button[1].len == 0));
            objc.setU(button[0], objc.sel("setEnabled:"), @intFromBool(enabled));
            objc.setU(button[0], objc.sel("setTag:"), tag);
        }
    }
};

pub fn rect(x: f64, y: f64, w: f64, h: f64) objc.CGRect {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
}

fn setFrame(view: objc.Id, frame: objc.CGRect) void {
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect) callconv(.c) void)(view, objc.sel("setFrame:"), frame);
}

fn setText(view: objc.Id, comptime selector: [*:0]const u8, text: []const u8) void {
    const string = objc.nsStringFromBytes(text);
    defer objc.release(string);
    objc.setId(view, objc.sel(selector), string);
}

fn makeLabel() objc.Id {
    const label = objc.msg(*const fn (objc.Class, objc.Sel, objc.Id) callconv(.c) objc.Id)(objc.cls("NSTextField"), objc.sel("labelWithString:"), objc.nsString(""));
    objc.setU(label, objc.sel("setLineBreakMode:"), 0); // wrap words
    objc.setU(label, objc.sel("setMaximumNumberOfLines:"), 2);
    objc.setU(label, objc.sel("setSelectable:"), 1);
    return label;
}

fn makeButton(target: objc.Id, selector: [*:0]const u8) objc.Id {
    const button = objc.msg(*const fn (objc.Class, objc.Sel, objc.Id, objc.Id, objc.Sel) callconv(.c) objc.Id)(objc.cls("NSButton"), objc.sel("buttonWithTitle:target:action:"), objc.nsString(""), target, objc.sel(selector));
    objc.setU(button, objc.sel("setBezelStyle:"), 1); // native rounded push button
    objc.setU(button, objc.sel("setBordered:"), 1);
    return button;
}
