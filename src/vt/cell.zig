//! Cell, flags, and attribute types — split from terminal.zig so the
//! storage layer (grid.zig) and semantics layer share them without cycles.

const colors = @import("color.zig");

pub const Color = colors.Color;

pub const Flags = packed struct(u16) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    hidden: bool = false,
    strike: bool = false,
    wide: bool = false,
    wide_spacer: bool = false,
    /// Blank filler left when a wide char moved whole to the next row at
    /// a wrap boundary — padding, not content; reflow strips it on rejoin.
    wide_pad: bool = false,
    /// True when `cp` was printed rather than supplied by an erased/empty
    /// cell. This distinguishes a printable space from storage blankness for
    /// grapheme attachment and exact reflow.
    content: bool = false,
    _pad: u5 = 0,
};

pub const Cell = struct {
    cp: u21 = ' ',
    /// Offset/length of codepoints after `cp` in the owning terminal or
    /// snapshot's grapheme arena. A zero length means the scalar fast path;
    /// offsets are deliberately process-local (RFC 0003 / RFC 0012).
    grapheme_offset: u32 = 0,
    grapheme_len: u8 = 0,
    flags: Flags = .{},
    fg: Color = .default,
    bg: Color = .default,
    underline_color: Color = .default,
    /// One-based id in the owning terminal/snapshot hyperlink table.
    /// Zero means ordinary text (RFC 0018).
    hyperlink_id: u32 = 0,

    /// A cell reflow may trim from a logical line's tail: default-blank
    /// with no attributes.
    pub fn isTrimmable(self: Cell) bool {
        return self.cp == ' ' and self.grapheme_len == 0 and self.bg == .default and
            self.fg == .default and self.underline_color == .default and
            self.hyperlink_id == 0 and
            self.flags == Flags{};
    }

    pub fn hasGrapheme(self: Cell) bool {
        return self.grapheme_len != 0;
    }
};

pub const Attrs = struct {
    flags: Flags = .{},
    fg: Color = .default,
    bg: Color = .default,
    underline_color: Color = .default,
};
