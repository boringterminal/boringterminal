//! The single viewer-side dispatch point for the selected attach dialect.

const std = @import("std");
const protocol = @import("../../daemon/protocol.zig");
const vt = @import("../../vt.zig");
const v10 = @import("compat/v10.zig");
const v13 = @import("compat/v13.zig");
const legacy_metadata = @import("compat/metadata_v10_v13.zig");
const c = std.c;

pub const Dialect = enum(u16) {
    v10 = v10.version,
    v13 = v13.version,
    current = protocol.version,

    pub fn number(self: Dialect) u16 {
        return @intFromEnum(self);
    }

    pub fn isCompatibility(self: Dialect) bool {
        return self != .current;
    }

    pub fn supportsSearch(self: Dialect) bool {
        return self != .v10;
    }

    pub fn supportsCreateBeside(self: Dialect) bool {
        return self != .v10;
    }

    pub fn supportsPersistentPairZoom(self: Dialect) bool {
        return self == .current;
    }
};

pub const KeyEncoding = union(enum) {
    semantic: void,
    raw: []const u8,
    ignored,
};

const retained_probe_order = [_]Dialect{ .v13, .v10 };

pub fn retainedProbeOrder() []const Dialect {
    return &retained_probe_order;
}

pub fn bestSupported(peer: []const u16) ?Dialect {
    for (peer) |number| if (number == Dialect.current.number()) return .current;
    for (retained_probe_order) |candidate|
        for (peer) |number| if (number == candidate.number()) return candidate;
    return null;
}

pub fn writeFrame(fd: c.fd_t, dialect: Dialect, tag: protocol.Tag, payload: []const u8) !void {
    try protocol.writeFrameVersion(fd, dialect.number(), tag, payload);
}

pub fn readFrame(fd: c.fd_t, dialect: Dialect, alloc: std.mem.Allocator) !protocol.Frame {
    return protocol.readFrameVersion(fd, dialect.number(), alloc);
}

pub fn encodeKeyEvent(
    dialect: Dialect,
    enc: *protocol.Encoder,
    event: vt.keyboard.Event,
) !KeyEncoding {
    switch (dialect) {
        .current => {
            try protocol.encodeKeyEvent(enc, event);
            return .{ .semantic = {} };
        },
        .v13 => switch (v13.classifyKey(event)) {
            .semantic => |code| {
                try v13.encodeSemanticKey(enc, code, event);
                return .{ .semantic = {} };
            },
            .raw => |bytes| return .{ .raw = bytes },
            .ignored => return .ignored,
        },
        .v10 => switch (v10.classifyKey(event)) {
            .semantic => |code| {
                try v10.encodeSemanticKey(enc, code, event);
                return .{ .semantic = {} };
            },
            .raw => |bytes| return .{ .raw = bytes },
            .ignored => return .ignored,
        },
    }
}

pub fn encodeMouseEvent(
    dialect: Dialect,
    enc: *protocol.Encoder,
    event: vt.mouse.Event,
) !void {
    switch (dialect) {
        .current => try protocol.encodeMouseEvent(enc, event),
        .v13 => try v13.encodeMouseEvent(enc, event),
        .v10 => try v10.encodeMouseEvent(enc, event),
    }
}

pub fn decodeSnapshot(
    dialect: Dialect,
    dec: *protocol.Decoder,
    alloc: std.mem.Allocator,
) !protocol.Snapshot {
    return switch (dialect) {
        .current, .v13 => protocol.Snapshot.decode(dec, alloc),
        .v10 => v10.decodeSnapshot(dec, alloc),
    };
}

pub fn decodeMetadata(
    dialect: Dialect,
    dec: *protocol.Decoder,
    alloc: std.mem.Allocator,
) !protocol.Metadata {
    return switch (dialect) {
        .current => protocol.decodeMetadata(dec, alloc),
        .v13, .v10 => legacy_metadata.decodeMetadata(dec, alloc),
    };
}

pub fn decodeRegistry(
    dialect: Dialect,
    dec: *protocol.Decoder,
    alloc: std.mem.Allocator,
) !protocol.RegistrySnapshot {
    return switch (dialect) {
        .current => protocol.decodeRegistry(dec, alloc),
        .v13, .v10 => legacy_metadata.decodeRegistry(dec, alloc),
    };
}

test "selected dialect numbers are exact" {
    try std.testing.expectEqual(@as(u16, 10), Dialect.v10.number());
    try std.testing.expectEqual(@as(u16, 13), Dialect.v13.number());
    try std.testing.expectEqual(protocol.version, Dialect.current.number());
}

test "selection prefers the newest common dialect" {
    try std.testing.expectEqual(Dialect.current, bestSupported(&.{ 13, protocol.version }).?);
    try std.testing.expectEqual(Dialect.v13, bestSupported(&.{13}).?);
    try std.testing.expectEqual(Dialect.v10, bestSupported(&.{10}).?);
    try std.testing.expect(bestSupported(&.{12}) == null);
}

test "persistent pair zoom is current-dialect only" {
    try std.testing.expect(Dialect.current.supportsPersistentPairZoom());
    try std.testing.expect(!Dialect.v13.supportsPersistentPairZoom());
    try std.testing.expect(!Dialect.v10.supportsPersistentPairZoom());
}
