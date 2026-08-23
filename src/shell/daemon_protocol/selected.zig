//! The single viewer-side dispatch point for the selected attach dialect.

const std = @import("std");
const protocol = @import("../../daemon/protocol.zig");
const vt = @import("../../vt.zig");
const v13 = @import("compat/v13.zig");
const v18 = @import("compat/v18.zig");
const legacy_metadata = @import("compat/metadata_v10_v13.zig");
const c = std.c;

pub const Dialect = enum(u16) {
    v13 = v13.version,
    v18 = v18.version,
    current = protocol.version,

    pub fn number(self: Dialect) u16 {
        return @intFromEnum(self);
    }

    pub fn isCompatibility(self: Dialect) bool {
        return self != .current;
    }

    pub fn supportsSearch(_: Dialect) bool {
        return true;
    }

    pub fn supportsCreateBeside(_: Dialect) bool {
        return true;
    }

    pub fn supportsPersistentPairZoom(self: Dialect) bool {
        return self == .current or self == .v18;
    }
};

pub const KeyEncoding = union(enum) {
    semantic: void,
    raw: []const u8,
    ignored,
};

const retained_probe_order = [_]Dialect{ .v18, .v13 };

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
        .current, .v18 => {
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
    }
}

pub fn encodeMouseEvent(
    dialect: Dialect,
    enc: *protocol.Encoder,
    event: vt.mouse.Event,
) !void {
    switch (dialect) {
        .current, .v18 => try protocol.encodeMouseEvent(enc, event),
        .v13 => try v13.encodeMouseEvent(enc, event),
    }
}

pub fn decodeSnapshot(
    dialect: Dialect,
    dec: *protocol.Decoder,
    alloc: std.mem.Allocator,
) !protocol.Snapshot {
    return switch (dialect) {
        .current => protocol.Snapshot.decode(dec, alloc),
        .v18 => v18.decodeSnapshot(dec, alloc),
        .v13 => v18.decodeTextOnlySnapshot(dec, alloc),
    };
}

pub fn decodeMetadata(
    dialect: Dialect,
    dec: *protocol.Decoder,
    alloc: std.mem.Allocator,
) !protocol.Metadata {
    return switch (dialect) {
        .current, .v18 => protocol.decodeMetadata(dec, alloc),
        .v13 => legacy_metadata.decodeMetadata(dec, alloc),
    };
}

pub fn decodeRegistry(
    dialect: Dialect,
    dec: *protocol.Decoder,
    alloc: std.mem.Allocator,
) !protocol.RegistrySnapshot {
    return switch (dialect) {
        .current, .v18 => protocol.decodeRegistry(dec, alloc),
        .v13 => legacy_metadata.decodeRegistry(dec, alloc),
    };
}

test "selected dialect numbers are exact" {
    try std.testing.expectEqual(@as(u16, 13), Dialect.v13.number());
    try std.testing.expectEqual(@as(u16, 18), Dialect.v18.number());
    try std.testing.expectEqual(protocol.version, Dialect.current.number());
}

test "selection prefers the newest common dialect" {
    try std.testing.expectEqual(Dialect.current, bestSupported(&.{ 18, protocol.version }).?);
    try std.testing.expectEqual(Dialect.v18, bestSupported(&.{18}).?);
    try std.testing.expectEqual(Dialect.v13, bestSupported(&.{13}).?);
    try std.testing.expect(bestSupported(&.{10}) == null);
    try std.testing.expect(bestSupported(&.{12}) == null);
}

test "persistent pair zoom is current-dialect only" {
    try std.testing.expect(Dialect.current.supportsPersistentPairZoom());
    try std.testing.expect(Dialect.v18.supportsPersistentPairZoom());
    try std.testing.expect(!Dialect.v13.supportsPersistentPairZoom());
}
