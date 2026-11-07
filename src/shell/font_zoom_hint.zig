//! Non-interactive native feedback for temporary terminal text scaling.
const std = @import("std");
const objc = @import("../render/objc.zig");

pub const Hint = struct {
    view: objc.Id = null,
    label: objc.Id = null,

    pub fn init(self: *Hint, parent: objc.Id) !void {
        var class = objc.cls("BoringFontZoomHint");
        if (class == null) {
            class = objc.allocateClass(objc.cls("NSVisualEffectView"), "BoringFontZoomHint");
            objc.addMethod(class, objc.sel("hitTest:"), @ptrCast(@constCast(&hitTest)), "@@:{CGPoint=dd}");
            objc.registerClass(class);
        }
        const view = objc.allocInit(class);
        if (view == null) return error.ViewCreate;
        defer objc.release(view);
        const label = objc.msg(*const fn (objc.Class, objc.Sel, objc.Id) callconv(.c) objc.Id)(
            objc.cls("NSTextField"),
            objc.sel("labelWithString:"),
            objc.nsString(""),
        );
        if (label == null) return error.ViewCreate;
        objc.setU(view, objc.sel("setMaterial:"), 6); // popover
        objc.setU(view, objc.sel("setBlendingMode:"), 1); // within window
        objc.setU(view, objc.sel("setState:"), 1);
        objc.setU(view, objc.sel("setWantsLayer:"), 1);
        const layer = objc.msg(*const fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(view, objc.sel("layer"));
        objc.msg(*const fn (objc.Id, objc.Sel, objc.CGFloat) callconv(.c) void)(layer, objc.sel("setCornerRadius:"), 8);
        objc.setU(layer, objc.sel("setMasksToBounds:"), 1);
        const font = objc.msg(*const fn (objc.Class, objc.Sel, objc.CGFloat, objc.CGFloat) callconv(.c) objc.Id)(
            objc.cls("NSFont"),
            objc.sel("systemFontOfSize:weight:"),
            13,
            0.23,
        );
        objc.setId(label, objc.sel("setFont:"), font);
        objc.setU(label, objc.sel("setAlignment:"), 1); // center
        objc.setU(label, objc.sel("setSelectable:"), 0);
        objc.setU(label, objc.sel("setMaximumNumberOfLines:"), 1);
        objc.setId(label, objc.sel("setAccessibilityLabel:"), objc.nsString("Text zoom"));
        objc.setId(view, objc.sel("addSubview:"), label);
        objc.setId(parent, objc.sel("addSubview:"), view);
        self.* = .{ .view = view, .label = label };
        self.hide();
    }

    pub fn show(self: *Hint, size: f32, configured: f32) void {
        if (self.view == null) return;
        const percent: u32 = @intFromFloat(@round(size / configured * 100));
        var buffer: [64]u8 = undefined;
        const text = if (size == @round(size))
            std.fmt.bufPrint(&buffer, "{d}% · {d:.0} pt", .{ percent, size }) catch return
        else
            std.fmt.bufPrint(&buffer, "{d}% · {d:.1} pt", .{ percent, size }) catch return;
        const value = objc.nsStringFromBytes(text);
        defer objc.release(value);
        objc.setId(self.label, objc.sel("setStringValue:"), value);
        objc.setId(self.label, objc.sel("setAccessibilityValue:"), value);
        objc.setU(self.view, objc.sel("setHidden:"), 0);
    }

    pub fn hide(self: *Hint) void {
        if (self.view != null) objc.setU(self.view, objc.sel("setHidden:"), 1);
    }

    pub fn layout(self: *Hint, terminal: objc.CGRect) void {
        if (self.view == null) return;
        const width = @max(0, @min(180, terminal.size.width - 16));
        const height = @max(0, @min(32, terminal.size.height));
        const bottom = @max(0, @min(12, terminal.size.height - height));
        setFrame(self.view, .{
            .origin = .{ .x = terminal.origin.x + (terminal.size.width - width) / 2, .y = terminal.origin.y + bottom },
            .size = .{ .width = width, .height = height },
        });
        setFrame(self.label, .{
            .origin = .{ .x = 8, .y = @max(0, (height - 18) / 2) },
            .size = .{ .width = @max(0, width - 16), .height = @min(18, height) },
        });
    }
};

fn setFrame(view: objc.Id, frame: objc.CGRect) void {
    objc.msg(*const fn (objc.Id, objc.Sel, objc.CGRect) callconv(.c) void)(view, objc.sel("setFrame:"), frame);
}

fn hitTest(_: objc.Id, _: objc.Sel, _: objc.CGPoint) callconv(.c) objc.Id {
    return null;
}
