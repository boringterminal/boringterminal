//! Bounded workspace intent, independent of PTYs and attach dialects (RFC 0025).
const std = @import("std");

pub const format_version = 1;
pub const max_entries = 1024;
pub const max_file_bytes = 4 * 1024 * 1024;
pub const max_title_bytes = 512;
pub const max_cwd_bytes = 1024;

pub const CwdSource = enum { initial, process, osc7 };
pub const Entry = struct {
    id: u64,
    title: []const u8 = "Boring Terminal",
    cwd: ?[]const u8 = null,
    cwd_source: CwdSource = .initial,
    cwd_observed_at: i64 = 0,
};

pub const Item = struct {
    left: u64,
    right: ?u64 = null,
    focus_right: bool = false,
    ratio: u16 = 32768,
    zoomed: bool = false,

    pub fn contains(self: Item, id: u64) bool {
        return self.left == id or self.right == id;
    }
};

pub const Workspace = struct {
    entries: []const Entry = &.{},
    items: []const Item = &.{},
    selected: ?u64 = null,

    pub fn find(self: Workspace, id: u64) ?Entry {
        for (self.entries) |entry| if (entry.id == id) return entry;
        return null;
    }

    pub fn validate(self: Workspace) !void {
        if (self.entries.len > max_entries or self.items.len > max_entries)
            return error.RecoveryLimit;
        for (self.entries, 0..) |entry, index| {
            if (entry.id == 0 or !validText(entry.title, max_title_bytes))
                return error.InvalidRecovery;
            if (entry.cwd) |cwd| if (!validCwd(cwd)) return error.InvalidRecovery;
            for (self.entries[0..index]) |other|
                if (entry.id == other.id) return error.InvalidRecovery;
            var occurrences: usize = 0;
            for (self.items) |item| {
                occurrences += @intFromBool(item.left == entry.id);
                occurrences += @intFromBool(item.right == entry.id);
            }
            if (occurrences != 1) return error.InvalidRecovery;
        }
        for (self.items) |item| {
            if (self.find(item.left) == null) return error.InvalidRecovery;
            if (item.right) |right| {
                if (right == item.left or self.find(right) == null or
                    item.ratio == 0 or item.ratio == 65535)
                    return error.InvalidRecovery;
            } else if (item.focus_right or item.zoomed or item.ratio != 32768)
                return error.InvalidRecovery;
        }
        if (self.selected) |id| if (self.find(id) == null) return error.InvalidRecovery;
    }

    /// Deep copies strings as well as arrays into the transaction's arena.
    pub fn clone(self: Workspace, alloc: std.mem.Allocator) !Workspace {
        const entries = try alloc.dupe(Entry, self.entries);
        for (entries) |*entry| {
            entry.title = try alloc.dupe(u8, entry.title);
            if (entry.cwd) |cwd| entry.cwd = try alloc.dupe(u8, cwd);
        }
        return .{
            .entries = entries,
            .items = try alloc.dupe(Item, self.items),
            .selected = self.selected,
        };
    }

    pub fn append(self: Workspace, alloc: std.mem.Allocator, other: Workspace) !Workspace {
        if (self.entries.len + other.entries.len > max_entries) return error.RecoveryLimit;
        const left = try self.clone(alloc);
        const right = try other.clone(alloc);
        return .{
            .entries = try std.mem.concat(alloc, Entry, &.{ left.entries, right.entries }),
            .items = try std.mem.concat(alloc, Item, &.{ left.items, right.items }),
            .selected = right.selected orelse left.selected,
        };
    }

    /// Removal collapses a pair, preserving its surviving member's position.
    pub fn removing(self: Workspace, alloc: std.mem.Allocator, id: u64) !Workspace {
        var entries: std.ArrayList(Entry) = .empty;
        var items: std.ArrayList(Item) = .empty;
        for (self.entries) |entry| if (entry.id != id) try entries.append(alloc, entry);
        for (self.items) |item| {
            if (!item.contains(id)) {
                try items.append(alloc, item);
            } else if (item.right) |right| {
                try items.append(alloc, .{ .left = if (item.left == id) right else item.left });
            }
        }
        const selected = if (self.selected == id)
            (if (entries.items.len == 0) null else entries.items[0].id)
        else
            self.selected;
        return (Workspace{ .entries = entries.items, .items = items.items, .selected = selected }).clone(alloc);
    }
};

pub const State = struct {
    format_version: u32 = format_version,
    revision: u64 = 0,
    owner_epoch: u64 = 0,
    pending_generation: u64 = 0,
    current: Workspace = .{},
    pending: Workspace = .{},

    pub fn validate(self: State) !void {
        if (self.format_version != format_version) return error.UnsupportedRecoveryVersion;
        if (self.current.entries.len + self.pending.entries.len > max_entries)
            return error.RecoveryLimit;
        try self.current.validate();
        try self.pending.validate();
        for (self.current.entries) |entry|
            if (self.pending.find(entry.id) != null) return error.InvalidRecovery;
        if (self.pending.entries.len != 0 and self.pending_generation == 0)
            return error.InvalidRecovery;
    }

    pub fn clone(self: State, alloc: std.mem.Allocator) !State {
        var copy = self;
        copy.current = try self.current.clone(alloc);
        copy.pending = try self.pending.clone(alloc);
        return copy;
    }

    /// Repeated daemon loss accumulates unresolved work instead of replacing it
    /// with the latest empty startup. Call only after obtaining sole ownership.
    pub fn interrupted(self: State, alloc: std.mem.Allocator, epoch: u64) !State {
        if (epoch == 0) return error.InvalidRecovery;
        var next = try self.clone(alloc);
        next.pending = try self.pending.append(alloc, self.current);
        next.current = .{};
        next.owner_epoch = epoch;
        if (self.current.entries.len != 0) next.pending_generation = epoch;
        try next.validate();
        return next;
    }

    pub fn accept(self: State, alloc: std.mem.Allocator, generation: u64) !State {
        if (generation == 0 or generation != self.pending_generation)
            return error.StaleRecovery;
        var next = try self.clone(alloc);
        next.current = try self.current.append(alloc, self.pending);
        next.pending = .{};
        // Retain the token so retries are an idempotent no-op in this epoch.
        try next.validate();
        return next;
    }

    pub fn dismiss(self: State, alloc: std.mem.Allocator, generation: u64) !State {
        if (generation == 0 or generation != self.pending_generation)
            return error.StaleRecovery;
        var next = try self.clone(alloc);
        next.pending = .{};
        return next;
    }
};

pub const Document = struct {
    arena: *std.heap.ArenaAllocator,
    state: State,

    pub fn init(gpa: std.mem.Allocator) !Document {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(gpa);
        return .{ .arena = arena, .state = .{} };
    }

    pub fn allocator(self: Document) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *Document) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
        self.* = undefined;
    }

    pub fn copy(gpa: std.mem.Allocator, state: State) !Document {
        var doc = try init(gpa);
        errdefer doc.deinit();
        doc.state = try state.clone(doc.allocator());
        return doc;
    }

    pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) !Document {
        try checkJsonBounds(bytes);
        var doc = try init(gpa);
        errdefer doc.deinit();
        const header = try std.json.parseFromSliceLeaky(struct { format_version: u32 }, doc.allocator(), bytes, .{
            .ignore_unknown_fields = true,
        });
        if (header.format_version != format_version) return error.UnsupportedRecoveryVersion;
        doc.state = try std.json.parseFromSliceLeaky(State, doc.allocator(), bytes, .{ .allocate = .alloc_always });
        try doc.state.validate();
        return doc;
    }

    pub fn encode(self: Document, alloc: std.mem.Allocator) ![]u8 {
        try self.state.validate();
        const bytes = try std.json.Stringify.valueAlloc(alloc, self.state, .{});
        errdefer alloc.free(bytes);
        if (bytes.len > max_file_bytes) return error.RecoveryLimit;
        return bytes;
    }
};

pub fn validText(text: []const u8, limit: usize) bool {
    if (text.len > limit or !std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

pub fn validCwd(path: []const u8) bool {
    return path.len != 0 and path[0] == '/' and validText(path, max_cwd_bytes);
}

fn checkJsonBounds(bytes: []const u8) !void {
    if (bytes.len > max_file_bytes) return error.RecoveryLimit;
    var depth: usize = 0;
    var string = false;
    var escape = false;
    for (bytes) |byte| {
        if (string) {
            if (escape) {
                escape = false;
            } else if (byte == '\\') {
                escape = true;
            } else if (byte == '"') string = false;
        } else switch (byte) {
            '"' => string = true,
            '{', '[' => {
                depth += 1;
                if (depth > 12) return error.RecoveryLimit;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidRecovery;
                depth -= 1;
            },
            else => {},
        }
    }
}

const test_workspace: Workspace = .{
    .entries = &.{ .{ .id = 11, .title = "first", .cwd = "/tmp/a" }, .{ .id = 12, .cwd = "/tmp/b" } },
    .items = &.{.{ .left = 11, .right = 12, .focus_right = true, .zoomed = true, .ratio = 40000 }},
    .selected = 12,
};

test "recovery survives repeated interrupted startups and accepts once" {
    var doc = try Document.init(std.testing.allocator);
    defer doc.deinit();
    doc.state.current = test_workspace;
    doc.state = try doc.state.interrupted(doc.allocator(), 100);
    try std.testing.expectEqual(@as(usize, 2), doc.state.pending.entries.len);
    doc.state = try doc.state.interrupted(doc.allocator(), 101);
    try std.testing.expectEqual(@as(u64, 100), doc.state.pending_generation);
    doc.state.current = .{ .entries = &.{.{ .id = 13 }}, .items = &.{.{ .left = 13 }} };
    doc.state = try doc.state.interrupted(doc.allocator(), 102);
    try std.testing.expectEqual(@as(usize, 3), doc.state.pending.entries.len);
    try std.testing.expectError(error.StaleRecovery, doc.state.accept(doc.allocator(), 100));
    doc.state = try doc.state.accept(doc.allocator(), 102);
    doc.state = try doc.state.accept(doc.allocator(), 102);
    try std.testing.expectEqual(@as(usize, 3), doc.state.current.entries.len);
    try std.testing.expectEqual(@as(usize, 0), doc.state.pending.entries.len);
    try std.testing.expect(doc.state.current.items[0].zoomed);
    try std.testing.expectEqual(@as(u64, 12), doc.state.current.selected.?);
}

test "recovery validates topology and removes pair members without resurrection" {
    var doc = try Document.init(std.testing.allocator);
    defer doc.deinit();
    try test_workspace.validate();
    const reduced = try test_workspace.removing(doc.allocator(), 12);
    try reduced.validate();
    try std.testing.expectEqual(@as(usize, 1), reduced.entries.len);
    try std.testing.expectEqual(@as(?u64, null), reduced.items[0].right);
    var invalid = test_workspace;
    invalid.items = &.{ .{ .left = 11, .right = 12 }, .{ .left = 12 } };
    try std.testing.expectError(error.InvalidRecovery, invalid.validate());
    invalid.items = &.{.{ .left = 11, .right = 90 }};
    try std.testing.expectError(error.InvalidRecovery, invalid.validate());
}

test "recovery disk codec is independent bounded and rejects future versions" {
    var doc = try Document.init(std.testing.allocator);
    defer doc.deinit();
    doc.state.current = test_workspace;
    const bytes = try doc.encode(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    var decoded = try Document.decode(std.testing.allocator, bytes);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("/tmp/a", decoded.state.current.entries[0].cwd.?);
    try std.testing.expectError(error.UnsupportedRecoveryVersion, Document.decode(std.testing.allocator, "{\"format_version\":2,\"future\":true}"));
    try std.testing.expectError(error.RecoveryLimit, Document.decode(std.testing.allocator, "[[[[[[[[[[[[[[]]]]]]]]]]]]]]"));
    try std.testing.expect(!validCwd("/tmp/a\n"));
    try std.testing.expect(!validCwd("relative"));
}
