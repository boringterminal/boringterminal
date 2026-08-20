//! Pure ordered presentation registry for RFC 0014. PTYs remain independent;
//! this stores only whether one or two session ids occupy a sidebar row.

const std = @import("std");

pub const default_ratio: u16 = 32768;

pub const FocusedMember = enum(u8) {
    left,
    right,
};

pub const Pair = struct {
    left: u64,
    right: u64,
    focused: FocusedMember,
    ratio: u16,
    zoomed: bool = false,

    pub fn focusedId(self: Pair) u64 {
        return switch (self.focused) {
            .left => self.left,
            .right => self.right,
        };
    }
};

pub const Item = union(enum(u8)) {
    single: u64,
    pair: Pair,

    pub fn contains(self: Item, id: u64) bool {
        return switch (self) {
            .single => |single| single == id,
            .pair => |pair| pair.left == id or pair.right == id,
        };
    }
};

pub const Registry = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Item) = .empty,

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Registry) void {
        self.items.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn appendSingle(self: *Registry, id: u64) !void {
        if (id == 0 or self.find(id) != null) return error.InvalidSession;
        try self.items.append(self.gpa, .{ .single = id });
    }

    /// Atomically replace one existing single with a fresh right-hand member.
    /// The new id has not previously been inserted into the registry.
    pub fn appendBeside(self: *Registry, existing_id: u64, new_id: u64) !void {
        if (existing_id == 0 or new_id == 0 or existing_id == new_id or
            self.find(new_id) != null) return error.InvalidSession;
        const index = self.findSingle(existing_id) orelse return error.NotSingle;
        self.items.items[index] = .{ .pair = .{
            .left = existing_id,
            .right = new_id,
            .focused = .right,
            .ratio = default_ratio,
        } };
    }

    /// The target becomes the left member and retains its visual position.
    pub fn pair(self: *Registry, left: u64, right: u64, focused_id: ?u64) !void {
        if (left == 0 or right == 0 or left == right) return error.InvalidPair;
        const left_index = self.findSingle(left) orelse return error.NotSingle;
        const right_index = self.findSingle(right) orelse return error.NotSingle;
        const focused: FocusedMember = if (focused_id == right) .right else .left;
        self.items.items[left_index] = .{ .pair = .{
            .left = left,
            .right = right,
            .focused = focused,
            .ratio = default_ratio,
        } };
        _ = self.items.orderedRemove(right_index);
    }

    pub fn separate(self: *Registry, member_id: u64) !void {
        const index = self.findPair(member_id) orelse return error.NotPaired;
        const pair_item = self.items.items[index].pair;
        try self.items.ensureUnusedCapacity(self.gpa, 1);
        self.items.items[index] = .{ .single = pair_item.left };
        self.items.insertAssumeCapacity(index + 1, .{ .single = pair_item.right });
    }

    pub fn rememberFocus(self: *Registry, member_id: u64) !void {
        const index = self.findPair(member_id) orelse return error.NotPaired;
        var pair_item = &self.items.items[index].pair;
        pair_item.focused = if (pair_item.left == member_id) .left else .right;
    }

    pub fn setRatio(self: *Registry, member_id: u64, ratio: u16) !void {
        if (ratio == 0 or ratio == std.math.maxInt(u16)) return error.InvalidRatio;
        const index = self.findPair(member_id) orelse return error.NotPaired;
        self.items.items[index].pair.ratio = ratio;
    }

    pub fn setZoom(self: *Registry, member_id: u64, zoomed: bool) !void {
        const index = self.findPair(member_id) orelse return error.NotPaired;
        var pair_item = &self.items.items[index].pair;
        if (zoomed)
            pair_item.focused = if (pair_item.left == member_id) .left else .right;
        pair_item.zoomed = zoomed;
    }

    /// Swap a pair's visible sides while preserving focus by session id.
    pub fn swap(self: *Registry, member_id: u64) !void {
        const index = self.findPair(member_id) orelse return error.NotPaired;
        var pair_item = &self.items.items[index].pair;
        std.mem.swap(u64, &pair_item.left, &pair_item.right);
        pair_item.focused = switch (pair_item.focused) {
            .left => .right,
            .right => .left,
        };
    }

    /// Move one member out of its pair and atomically pair it with a single.
    /// The source pair collapses in place; the new pair occupies the target's
    /// position. No allocation is needed and failure leaves the registry
    /// untouched.
    pub fn transferMember(
        self: *Registry,
        member_id: u64,
        target_id: u64,
        member_on_left: bool,
        focused_id: ?u64,
    ) !void {
        if (member_id == 0 or target_id == 0 or member_id == target_id)
            return error.InvalidPair;
        const source_index = self.findPair(member_id) orelse return error.NotPaired;
        const target_index = self.findSingle(target_id) orelse return error.NotSingle;
        const old_pair = self.items.items[source_index].pair;
        const survivor = if (old_pair.left == member_id) old_pair.right else old_pair.left;
        const left = if (member_on_left) member_id else target_id;
        const right = if (member_on_left) target_id else member_id;
        const focused: FocusedMember = if (focused_id == right) .right else .left;

        self.items.items[source_index] = .{ .single = survivor };
        self.items.items[target_index] = .{ .pair = .{
            .left = left,
            .right = right,
            .focused = focused,
            .ratio = default_ratio,
        } };
    }

    /// Separate one member and place it at its final display-item index under
    /// the same registry lock.
    pub fn extractMember(self: *Registry, member_id: u64, destination: usize) !void {
        const source_index = self.findPair(member_id) orelse return error.NotPaired;
        if (destination > self.items.items.len) return error.InvalidDestination;
        try self.items.ensureUnusedCapacity(self.gpa, 1);
        const pair_item = self.items.items[source_index].pair;
        self.items.items[source_index] = .{ .single = pair_item.left };
        self.items.insertAssumeCapacity(source_index + 1, .{ .single = pair_item.right });
        const member_index = self.find(member_id) orelse unreachable;
        const item = self.items.orderedRemove(member_index);
        self.items.insertAssumeCapacity(destination, item);
    }

    /// `destination` is the final zero-based index after the move.
    pub fn move(self: *Registry, member_id: u64, destination: usize) !void {
        if (destination >= self.items.items.len) return error.InvalidDestination;
        const source = self.find(member_id) orelse return error.InvalidSession;
        if (source == destination) return;
        const item = self.items.orderedRemove(source);
        self.items.insertAssumeCapacity(destination, item);
    }

    /// Removes membership and atomically collapses a pair to its survivor.
    pub fn removeSession(self: *Registry, id: u64) !void {
        const index = self.find(id) orelse return error.InvalidSession;
        switch (self.items.items[index]) {
            .single => _ = self.items.orderedRemove(index),
            .pair => |pair_item| {
                const survivor = if (pair_item.left == id) pair_item.right else pair_item.left;
                self.items.items[index] = .{ .single = survivor };
            },
        }
    }

    pub fn find(self: *const Registry, id: u64) ?usize {
        for (self.items.items, 0..) |item, index| if (item.contains(id)) return index;
        return null;
    }

    fn findSingle(self: *const Registry, id: u64) ?usize {
        for (self.items.items, 0..) |item, index| switch (item) {
            .single => |single| if (single == id) return index,
            .pair => {},
        };
        return null;
    }

    fn findPair(self: *const Registry, id: u64) ?usize {
        for (self.items.items, 0..) |item, index| switch (item) {
            .single => {},
            .pair => |pair_item| if (pair_item.left == id or pair_item.right == id) return index,
        };
        return null;
    }
};

test "pair, move, separate, and close preserve bounded membership" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.appendSingle(1);
    try registry.appendSingle(2);
    try registry.appendSingle(3);

    try registry.pair(2, 1, 1);
    try std.testing.expectEqual(@as(usize, 2), registry.items.items.len);
    try std.testing.expectEqual(@as(u64, 2), registry.items.items[0].pair.left);
    try std.testing.expectEqual(@as(u64, 1), registry.items.items[0].pair.focusedId());
    try registry.setRatio(2, 40000);
    try registry.move(3, 0);
    try std.testing.expectEqual(@as(u64, 3), registry.items.items[0].single);

    try registry.separate(1);
    try std.testing.expectEqual(@as(usize, 3), registry.items.items.len);
    try registry.pair(2, 1, 2);
    try registry.removeSession(2);
    try std.testing.expectEqual(@as(u64, 1), registry.items.items[1].single);
}

test "append beside replaces one single and focuses the fresh right member" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.appendSingle(1);
    try registry.appendSingle(2);

    try registry.appendBeside(1, 3);
    try std.testing.expectEqual(@as(usize, 2), registry.items.items.len);
    const pair_item = registry.items.items[0].pair;
    try std.testing.expectEqual(@as(u64, 1), pair_item.left);
    try std.testing.expectEqual(@as(u64, 3), pair_item.right);
    try std.testing.expectEqual(@as(u64, 3), pair_item.focusedId());
    try std.testing.expectEqual(default_ratio, pair_item.ratio);

    try std.testing.expectError(error.NotSingle, registry.appendBeside(1, 4));
    try std.testing.expectError(error.InvalidSession, registry.appendBeside(2, 3));
    try std.testing.expectEqual(@as(usize, 2), registry.items.items.len);
}

test "invalid display mutations are transactional" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.appendSingle(1);
    try registry.appendSingle(2);
    try registry.pair(1, 2, null);

    try std.testing.expectError(error.NotSingle, registry.pair(1, 2, 2));
    try std.testing.expectError(error.InvalidRatio, registry.setRatio(1, 0));
    try std.testing.expectEqual(@as(usize, 1), registry.items.items.len);
    try std.testing.expectEqual(@as(u64, 1), registry.items.items[0].pair.left);
    try std.testing.expectEqual(@as(u64, 2), registry.items.items[0].pair.right);
}

test "pair zoom follows focus identity and clears with replacement" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.appendSingle(1);
    try registry.appendSingle(2);
    try registry.appendSingle(3);
    try registry.pair(1, 2, 1);

    try registry.setZoom(2, true);
    try std.testing.expect(registry.items.items[0].pair.zoomed);
    try std.testing.expectEqual(@as(u64, 2), registry.items.items[0].pair.focusedId());
    try registry.swap(1);
    try std.testing.expect(registry.items.items[0].pair.zoomed);
    try std.testing.expectEqual(@as(u64, 2), registry.items.items[0].pair.focusedId());

    try registry.setZoom(1, false);
    try std.testing.expect(!registry.items.items[0].pair.zoomed);
    try std.testing.expectEqual(@as(u64, 2), registry.items.items[0].pair.focusedId());
    try registry.transferMember(2, 3, true, 2);
    try std.testing.expect(!registry.items.items[1].pair.zoomed);
}

test "swap and member transfer preserve focus, order, and membership" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.appendSingle(1);
    try registry.appendSingle(2);
    try registry.appendSingle(3);
    try registry.pair(1, 2, 2);

    try registry.swap(1);
    try std.testing.expectEqual(@as(u64, 2), registry.items.items[0].pair.left);
    try std.testing.expectEqual(@as(u64, 2), registry.items.items[0].pair.focusedId());

    try registry.transferMember(2, 3, false, 2);
    try std.testing.expectEqual(@as(u64, 1), registry.items.items[0].single);
    const transferred = registry.items.items[1].pair;
    try std.testing.expectEqual(@as(u64, 3), transferred.left);
    try std.testing.expectEqual(@as(u64, 2), transferred.right);
    try std.testing.expectEqual(@as(u64, 2), transferred.focusedId());
    try std.testing.expectEqual(default_ratio, transferred.ratio);
}

test "invalid member transfer is atomic" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.appendSingle(1);
    try registry.appendSingle(2);
    try registry.appendSingle(3);
    try registry.pair(1, 2, 1);

    try std.testing.expectError(error.NotSingle, registry.transferMember(1, 2, true, 1));
    try std.testing.expectError(error.NotPaired, registry.transferMember(3, 1, true, 3));
    try std.testing.expectEqual(@as(u64, 1), registry.items.items[0].pair.left);
    try std.testing.expectEqual(@as(u64, 2), registry.items.items[0].pair.right);
    try std.testing.expectEqual(@as(u64, 3), registry.items.items[1].single);
}

test "member extraction separates and lands at its final index" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.appendSingle(1);
    try registry.appendSingle(2);
    try registry.appendSingle(3);
    try registry.pair(1, 2, 1);
    try registry.extractMember(2, 2);
    try std.testing.expectEqual(@as(u64, 1), registry.items.items[0].single);
    try std.testing.expectEqual(@as(u64, 3), registry.items.items[1].single);
    try std.testing.expectEqual(@as(u64, 2), registry.items.items[2].single);
}
