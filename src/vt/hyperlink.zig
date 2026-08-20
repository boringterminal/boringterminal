//! Bounded OSC 8 hyperlink metadata owned by the pure terminal.
//!
//! Cells carry only a compact 1-based id. URI/id bytes live once in this
//! table and never cross the daemon boundary with their process-local ids.

const std = @import("std");

pub const max_uri_bytes: usize = 2083;
pub const max_explicit_id_bytes: usize = 250;
pub const max_entries: usize = 16_384;
pub const max_metadata_bytes: usize = 8 * 1024 * 1024;

pub const Link = struct {
    /// Empty means an implicit per-opening identity.
    explicit_id: []u8,
    uri: []u8,

    pub fn deinit(self: *Link, alloc: std.mem.Allocator) void {
        alloc.free(self.explicit_id);
        alloc.free(self.uri);
        self.* = undefined;
    }

    pub fn byteLen(self: Link) usize {
        return self.explicit_id.len + self.uri.len;
    }
};

pub fn validPrintableAscii(bytes: []const u8) bool {
    for (bytes) |byte| if (byte < 0x20 or byte > 0x7e) return false;
    return true;
}

test "hyperlink portable bytes are printable ASCII" {
    try std.testing.expect(validPrintableAscii("https://example.com/a;b?c=d"));
    try std.testing.expect(!validPrintableAscii("line\nfeed"));
    try std.testing.expect(!validPrintableAscii("caf\xc3\xa9"));
}
