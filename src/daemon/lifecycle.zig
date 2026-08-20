//! Stable daemon lifecycle protocol from RFC 0019. This surface is separate
//! from the evolving BTD1 terminal attach dialect.

const std = @import("std");
const c = std.c;

pub const version: u16 = 1;
pub const max_payload: usize = 4096;
pub const max_product_version: usize = 64;
pub const max_dialects: usize = 16;
pub const magic = "BTL1";
const header_len = 12;

pub const Tag = enum(u16) {
    status = 1,
    stop_if_idle = 2,
    terminate_all = 3,

    status_result = 64,
    ok = 65,
    busy = 66,
    protocol_error = 67,
};

pub const Frame = struct {
    tag: Tag,
    payload: []u8,

    pub fn deinit(self: *Frame, alloc: std.mem.Allocator) void {
        alloc.free(self.payload);
        self.* = undefined;
    }
};

pub const Status = struct {
    product_version: []const u8,
    dialects: []const u16,
    session_count: u32,
    attach_connection_count: u32,
    draining: bool,
};

pub const DecodedStatus = struct {
    product_version: []const u8,
    dialects: [max_dialects]u16 = [_]u16{0} ** max_dialects,
    dialect_count: u8,
    session_count: u32,
    attach_connection_count: u32,
    draining: bool,

    pub fn supportedDialects(self: *const DecodedStatus) []const u16 {
        return self.dialects[0..self.dialect_count];
    }
};

pub fn isMagic(prefix: *const [4]u8) bool {
    return std.mem.eql(u8, prefix, magic);
}

pub fn writeFrame(fd: c.fd_t, tag: Tag, payload: []const u8) !void {
    if (payload.len > max_payload) return error.PayloadTooLarge;
    var header: [header_len]u8 = undefined;
    @memcpy(header[0..4], magic);
    std.mem.writeInt(u16, header[4..6], version, .little);
    std.mem.writeInt(u16, header[6..8], @intFromEnum(tag), .little);
    std.mem.writeInt(u32, header[8..12], @intCast(payload.len), .little);
    try sendAll(fd, &header);
    try sendAll(fd, payload);
}

pub fn readFrame(fd: c.fd_t, alloc: std.mem.Allocator) !Frame {
    var header: [header_len]u8 = undefined;
    try readExact(fd, &header);
    if (!std.mem.eql(u8, header[0..4], magic)) return error.InvalidMagic;
    if (std.mem.readInt(u16, header[4..6], .little) != version)
        return error.VersionMismatch;
    const tag = std.enums.fromInt(Tag, std.mem.readInt(u16, header[6..8], .little)) orelse
        return error.UnknownTag;
    const len = std.mem.readInt(u32, header[8..12], .little);
    if (len > max_payload) return error.PayloadTooLarge;
    const payload = try alloc.alloc(u8, len);
    errdefer alloc.free(payload);
    try readExact(fd, payload);
    return .{ .tag = tag, .payload = payload };
}

pub fn encodeStatus(alloc: std.mem.Allocator, status: Status) ![]u8 {
    if (status.product_version.len == 0 or status.product_version.len > max_product_version or
        status.dialects.len == 0 or status.dialects.len > max_dialects)
        return error.InvalidStatus;
    const len = 1 + status.product_version.len + 1 + status.dialects.len * 2 + 4 + 4 + 1;
    const payload = try alloc.alloc(u8, len);
    errdefer alloc.free(payload);
    var pos: usize = 0;
    payload[pos] = @intCast(status.product_version.len);
    pos += 1;
    @memcpy(payload[pos..][0..status.product_version.len], status.product_version);
    pos += status.product_version.len;
    payload[pos] = @intCast(status.dialects.len);
    pos += 1;
    for (status.dialects) |dialect| {
        if (dialect == 0) return error.InvalidStatus;
        std.mem.writeInt(u16, payload[pos..][0..2], dialect, .little);
        pos += 2;
    }
    std.mem.writeInt(u32, payload[pos..][0..4], status.session_count, .little);
    pos += 4;
    std.mem.writeInt(u32, payload[pos..][0..4], status.attach_connection_count, .little);
    pos += 4;
    payload[pos] = @intFromBool(status.draining);
    return payload;
}

pub fn decodeStatus(payload: []const u8) !DecodedStatus {
    var pos: usize = 0;
    const product_len = try takeByte(payload, &pos);
    if (product_len == 0 or product_len > max_product_version or
        product_len > payload.len - pos) return error.InvalidStatus;
    const product_version = payload[pos..][0..product_len];
    pos += product_len;
    const dialect_count = try takeByte(payload, &pos);
    if (dialect_count == 0 or dialect_count > max_dialects) return error.InvalidStatus;
    const dialect_bytes = std.math.mul(usize, dialect_count, 2) catch return error.InvalidStatus;
    if (dialect_bytes > payload.len - pos) return error.InvalidStatus;
    var dialects = [_]u16{0} ** max_dialects;
    for (dialects[0..dialect_count]) |*dialect| {
        dialect.* = std.mem.readInt(u16, payload[pos..][0..2], .little);
        if (dialect.* == 0) return error.InvalidStatus;
        pos += 2;
    }
    if (payload.len - pos != 9) return error.InvalidStatus;
    const session_count = std.mem.readInt(u32, payload[pos..][0..4], .little);
    pos += 4;
    const attach_connection_count = std.mem.readInt(u32, payload[pos..][0..4], .little);
    pos += 4;
    const draining = switch (payload[pos]) {
        0 => false,
        1 => true,
        else => return error.InvalidStatus,
    };
    return .{
        .product_version = product_version,
        .dialects = dialects,
        .dialect_count = dialect_count,
        .session_count = session_count,
        .attach_connection_count = attach_connection_count,
        .draining = draining,
    };
}

fn takeByte(payload: []const u8, pos: *usize) !u8 {
    if (pos.* >= payload.len) return error.InvalidStatus;
    defer pos.* += 1;
    return payload[pos.*];
}

fn readExact(fd: c.fd_t, out: []u8) !void {
    var rest = out;
    while (rest.len != 0) {
        const n = c.read(fd, rest.ptr, rest.len);
        if (n == 0) return error.EndOfStream;
        if (n < 0) {
            if (c.errno(n) == .INTR) continue;
            return error.ReadFailed;
        }
        rest = rest[@intCast(n)..];
    }
}

fn sendAll(fd: c.fd_t, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len != 0) {
        const n = c.send(fd, rest.ptr, rest.len, c.MSG.NOSIGNAL);
        if (n < 0) {
            if (c.errno(n) == .INTR) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        rest = rest[@intCast(n)..];
    }
}

test "lifecycle status codec is bounded and exact" {
    const alloc = std.testing.allocator;
    const dialects = [_]u16{ 14, 13, 12 };
    const encoded = try encodeStatus(alloc, .{
        .product_version = "0.4.0",
        .dialects = &dialects,
        .session_count = 7,
        .attach_connection_count = 3,
        .draining = false,
    });
    defer alloc.free(encoded);
    const decoded = try decodeStatus(encoded);
    try std.testing.expectEqualStrings("0.4.0", decoded.product_version);
    try std.testing.expectEqual(@as(usize, 3), decoded.supportedDialects().len);
    try std.testing.expectEqual(@as(u16, 14), decoded.supportedDialects()[0]);
    try std.testing.expectEqual(@as(u16, 12), decoded.supportedDialects()[2]);
    try std.testing.expectEqual(@as(u32, 7), decoded.session_count);
}
