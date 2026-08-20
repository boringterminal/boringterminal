//! Pure viewer-side projections of RFC 0014's daemon-owned DisplayItems.

const std = @import("std");
const protocol = @import("../daemon/protocol.zig");

pub const pair_divider_width: f32 = 1;
pub const pair_divider_hit_width: f32 = 9;
pub const min_pane_cols: u16 = 20;

pub const PairCandidate = struct { left: u64, right: u64 };
pub const Direction = enum { previous, next };

pub fn geometryReady(
    actual_cols: u16,
    actual_rows: u16,
    requested_cols: u16,
    requested_rows: u16,
    snapshot_generation: u64,
    requested_generation: u64,
) bool {
    return actual_cols == requested_cols and actual_rows == requested_rows and
        snapshot_generation == requested_generation;
}

pub fn focusedId(item: protocol.DisplayItem) u64 {
    return switch (item) {
        .single => |id| id,
        .pair => |pair| pair.focusedId(),
    };
}

test "geometry presentation waits for the requested grid" {
    try std.testing.expect(geometryReady(120, 40, 120, 40, 7, 7));
    try std.testing.expect(!geometryReady(60, 40, 120, 40, 7, 7));
    try std.testing.expect(!geometryReady(120, 39, 120, 40, 7, 7));
    try std.testing.expect(!geometryReady(120, 40, 120, 40, 6, 7));
}

pub fn contains(item: protocol.DisplayItem, id: u64) bool {
    return item.contains(id);
}

pub fn itemIndex(items: []const protocol.DisplayItem, session_id: u64) ?usize {
    for (items, 0..) |item, index| if (contains(item, session_id)) return index;
    return null;
}

pub fn sessionIdAtVisualIndex(items: []const protocol.DisplayItem, wanted: usize) ?u64 {
    var index: usize = 0;
    for (items) |item| switch (item) {
        .single => |id| {
            if (index == wanted) return id;
            index += 1;
        },
        .pair => |pair| {
            if (index == wanted) return pair.left;
            if (index + 1 == wanted) return pair.right;
            index += 2;
        },
    };
    return null;
}

/// Convert a boundary in the pre-move list (0...len) into the item's final
/// zero-based index after removing it from `source`.
pub fn moveDestination(source: usize, boundary: usize, len: usize) ?usize {
    if (len == 0 or source >= len or boundary > len) return null;
    const destination = if (boundary > source) boundary - 1 else boundary;
    if (destination >= len or destination == source) return null;
    return destination;
}

pub fn pairCandidate(
    items: []const protocol.DisplayItem,
    active_index: usize,
    direction: Direction,
) ?PairCandidate {
    if (active_index >= items.len) return null;
    const active = switch (items[active_index]) {
        .single => |id| id,
        .pair => return null,
    };
    return switch (direction) {
        .previous => if (active_index == 0) null else switch (items[active_index - 1]) {
            .single => |previous| .{ .left = previous, .right = active },
            .pair => null,
        },
        .next => if (active_index + 1 >= items.len) null else switch (items[active_index + 1]) {
            .single => |next| .{ .left = active, .right = next },
            .pair => null,
        },
    };
}

pub fn adjacentSessionId(
    items: []const protocol.DisplayItem,
    current: u64,
    direction: Direction,
) ?u64 {
    var count: usize = 0;
    for (items) |item| count += switch (item) {
        .single => 1,
        .pair => 2,
    };
    if (count < 2) return null;
    var current_position: ?usize = null;
    var position: usize = 0;
    for (items) |item| switch (item) {
        .single => |id| {
            if (id == current) current_position = position;
            position += 1;
        },
        .pair => |pair| {
            if (pair.left == current) current_position = position;
            if (pair.right == current) current_position = position + 1;
            position += 2;
        },
    };
    const current_index = current_position orelse return null;
    const wanted = switch (direction) {
        .previous => if (current_index == 0) count - 1 else current_index - 1,
        .next => (current_index + 1) % count,
    };
    position = 0;
    for (items) |item| switch (item) {
        .single => |id| {
            if (position == wanted) return id;
            position += 1;
        },
        .pair => |pair| {
            if (position == wanted) return pair.left;
            if (position + 1 == wanted) return pair.right;
            position += 2;
        },
    };
    unreachable;
}

/// Return the neighboring sidebar item without wrapping. A pair is one item;
/// its daemon-remembered focused member is the activation target.
pub fn adjacentDisplayItemId(
    items: []const protocol.DisplayItem,
    current: u64,
    direction: Direction,
) ?u64 {
    const index = itemIndex(items, current) orelse return null;
    const wanted = switch (direction) {
        .previous => if (index == 0) return null else index - 1,
        .next => if (index + 1 >= items.len) return null else index + 1,
    };
    return focusedId(items[wanted]);
}

/// Return the final daemon index for a one-row vertical move. This shares the
/// same non-wrapping edge behavior as adjacent display-item focus.
pub fn adjacentDisplayItemDestination(
    items: []const protocol.DisplayItem,
    current: u64,
    direction: Direction,
) ?usize {
    const index = itemIndex(items, current) orelse return null;
    return switch (direction) {
        .previous => if (index == 0) null else index - 1,
        .next => if (index + 1 >= items.len) null else index + 1,
    };
}

pub const PairGeometry = struct {
    left_origin: f32 = 0,
    left_width: f32,
    right_origin: f32,
    right_width: f32,
    height: f32,
    left_cols: u16,
    right_cols: u16,
    rows: u16,
};

pub fn pairGeometry(
    width: f32,
    height: f32,
    ratio: u16,
    cell_width: f32,
    cell_height: f32,
) ?PairGeometry {
    if (!std.math.isFinite(width) or !std.math.isFinite(height) or
        !std.math.isFinite(cell_width) or !std.math.isFinite(cell_height) or
        width <= 0 or height <= 0 or cell_width <= 0 or cell_height <= 0 or
        ratio == 0 or ratio == std.math.maxInt(u16)) return null;
    const available = width - pair_divider_width;
    const minimum = cell_width * @as(f32, @floatFromInt(min_pane_cols));
    if (available < minimum * 2) return null;
    const total_cols: u16 = @intFromFloat(@floor(available / cell_width));
    const normalized = @as(f32, @floatFromInt(ratio)) /
        @as(f32, @floatFromInt(std.math.maxInt(u16)));
    const desired_left: u16 = @intFromFloat(@round(@as(f32, @floatFromInt(total_cols)) * normalized));
    const left_cols = std.math.clamp(desired_left, min_pane_cols, total_cols - min_pane_cols);
    const left_width = @as(f32, @floatFromInt(left_cols)) * cell_width;
    const right_width = available - left_width;
    return .{
        .left_width = left_width,
        .right_origin = left_width + pair_divider_width,
        .right_width = right_width,
        .height = height,
        .left_cols = left_cols,
        .right_cols = total_cols - left_cols,
        .rows = @max(1, @as(u16, @intFromFloat(@floor(height / cell_height)))),
    };
}

pub fn ratioFromDivider(divider_x: f32, width: f32, cell_width: f32) ?u16 {
    const available = width - pair_divider_width;
    const minimum = cell_width * @as(f32, @floatFromInt(min_pane_cols));
    if (available < minimum * 2) return null;
    const clamped = std.math.clamp(divider_x, minimum, available - minimum);
    const aligned = @round(clamped / cell_width) * cell_width;
    const raw = @round(aligned / available * @as(f32, @floatFromInt(std.math.maxInt(u16))));
    return @intFromFloat(std.math.clamp(raw, 1, @as(f32, @floatFromInt(std.math.maxInt(u16) - 1))));
}

test "display navigation treats pair members as adjacent visual stops" {
    const items = [_]protocol.DisplayItem{
        .{ .single = 1 },
        .{ .pair = .{ .left = 2, .right = 3, .focused = .right, .ratio = 32768 } },
        .{ .single = 4 },
    };
    try std.testing.expectEqual(@as(u64, 3), focusedId(items[1]));
    try std.testing.expectEqual(@as(u64, 3), adjacentSessionId(&items, 2, .next));
    try std.testing.expectEqual(@as(u64, 2), adjacentSessionId(&items, 3, .previous));
    try std.testing.expectEqual(@as(u64, 1), adjacentSessionId(&items, 4, .next));
    try std.testing.expectEqual(@as(u64, 1), sessionIdAtVisualIndex(&items, 0).?);
    try std.testing.expectEqual(@as(u64, 2), sessionIdAtVisualIndex(&items, 1).?);
    try std.testing.expectEqual(@as(u64, 3), sessionIdAtVisualIndex(&items, 2).?);
    try std.testing.expectEqual(@as(u64, 4), sessionIdAtVisualIndex(&items, 3).?);
    try std.testing.expect(sessionIdAtVisualIndex(&items, 4) == null);
}

test "vertical display navigation treats a pair as one non-wrapping row" {
    const items = [_]protocol.DisplayItem{
        .{ .single = 1 },
        .{ .pair = .{ .left = 2, .right = 3, .focused = .right, .ratio = 32768 } },
        .{ .single = 4 },
    };
    try std.testing.expectEqual(@as(u64, 3), adjacentDisplayItemId(&items, 1, .next).?);
    try std.testing.expectEqual(@as(u64, 1), adjacentDisplayItemId(&items, 2, .previous).?);
    try std.testing.expectEqual(@as(u64, 4), adjacentDisplayItemId(&items, 3, .next).?);
    try std.testing.expect(adjacentDisplayItemId(&items, 1, .previous) == null);
    try std.testing.expect(adjacentDisplayItemId(&items, 4, .next) == null);

    try std.testing.expectEqual(@as(usize, 0), adjacentDisplayItemDestination(&items, 3, .previous).?);
    try std.testing.expectEqual(@as(usize, 2), adjacentDisplayItemDestination(&items, 2, .next).?);
    try std.testing.expect(adjacentDisplayItemDestination(&items, 1, .previous) == null);
    try std.testing.expect(adjacentDisplayItemDestination(&items, 4, .next) == null);
}

test "pair candidates reject pairs and preserve target-left ordering" {
    const items = [_]protocol.DisplayItem{
        .{ .single = 1 },
        .{ .single = 2 },
        .{ .pair = .{ .left = 3, .right = 4, .focused = .left, .ratio = 32768 } },
    };
    try std.testing.expectEqual(PairCandidate{ .left = 1, .right = 2 }, pairCandidate(&items, 1, .previous).?);
    try std.testing.expect(pairCandidate(&items, 1, .next) == null);
    try std.testing.expect(pairCandidate(&items, 2, .previous) == null);
}

test "pair geometry enforces two twenty-column panes" {
    const geometry = pairGeometry(801, 400, 32768, 10, 20).?;
    try std.testing.expectEqual(@as(u16, 40), geometry.left_cols);
    try std.testing.expectEqual(@as(u16, 40), geometry.right_cols);
    try std.testing.expectEqual(@as(u16, 20), geometry.rows);
    try std.testing.expect(pairGeometry(400, 400, 32768, 10, 20) == null);
    try std.testing.expectEqual(@as(u16, 16384), ratioFromDivider(200, 801, 10).?);
}

test "display move boundaries normalize around the removed item" {
    try std.testing.expectEqual(@as(usize, 0), moveDestination(2, 0, 4).?);
    try std.testing.expectEqual(@as(usize, 3), moveDestination(0, 4, 4).?);
    try std.testing.expectEqual(@as(usize, 2), moveDestination(0, 3, 4).?);
    try std.testing.expect(moveDestination(1, 1, 4) == null);
    try std.testing.expect(moveDestination(1, 2, 4) == null);
}
