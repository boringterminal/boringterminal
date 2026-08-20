//! VT module root: a Terminal (heap, address-stable) driven by a Parser.
//! Everything here is pure per RFC 0001 — the host owns the PTY and the
//! window; this module owns bytes-in, grid+actions-out.

const std = @import("std");

pub const parser = @import("vt/parser.zig");
pub const terminal = @import("vt/terminal.zig");
pub const color = @import("vt/color.zig");
pub const utf8 = @import("vt/utf8.zig");
pub const mouse = @import("vt/mouse.zig");
pub const keyboard = @import("vt/keyboard.zig");
pub const paste = @import("vt/paste.zig");
pub const graphics = @import("vt/graphics.zig");
pub const hyperlink = @import("vt/hyperlink.zig");
pub const search = @import("vt/search.zig");
pub const termcap = @import("vt/termcap.zig");

pub const Terminal = terminal.Terminal;
pub const Cell = terminal.Cell;
pub const Flags = terminal.Flags;
pub const max_grapheme_codepoints = terminal.max_grapheme_codepoints;
pub const Action = terminal.Action;
pub const Color = color.Color;
pub const RGB = color.RGB;
pub const ColorScheme = color.Scheme;
pub const default_color_scheme = color.default_scheme;

pub const Vt = struct {
    alloc: std.mem.Allocator,
    term: *Terminal,
    p: parser.Parser(Terminal),

    pub fn init(alloc: std.mem.Allocator, cols: u16, rows: u16) !Vt {
        const term = try alloc.create(Terminal);
        errdefer alloc.destroy(term);
        term.* = try Terminal.init(alloc, cols, rows);
        errdefer term.deinit();
        return .{
            .alloc = alloc,
            .term = term,
            .p = try parser.Parser(Terminal).init(alloc, term),
        };
    }

    pub fn deinit(self: *Vt) void {
        self.p.deinit(self.alloc);
        self.term.deinit();
        self.alloc.destroy(self.term);
    }

    pub fn feed(self: *Vt, bytes: []const u8) void {
        self.p.feed(bytes);
        if (bytes.len != 0) self.term.bumpStateEpoch();
    }

    /// Feed through the first graphics action, or consume the complete slice.
    /// The host uses the returned boundary to complete resource work before
    /// parsing bytes whose cursor semantics can depend on that work.
    pub fn feedUntilGraphicsAction(self: *Vt, bytes: []const u8) usize {
        for (bytes, 0..) |byte, index| {
            self.p.feedByte(byte);
            const actions = self.term.drainActions();
            if (actions.len != 0 and actions[actions.len - 1] == .graphics) {
                self.term.bumpStateEpoch();
                return index + 1;
            }
        }
        if (bytes.len != 0) self.term.bumpStateEpoch();
        return bytes.len;
    }
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("vt/tests.zig");
}
