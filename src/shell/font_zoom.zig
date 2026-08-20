//! Pure temporary text-size state for RFC 0013.

const std = @import("std");
const config = @import("../config.zig");

pub const State = struct {
    override: ?f32 = null,

    pub fn effective(self: State, configured: f32) f32 {
        return self.override orelse configured;
    }

    pub fn isOverridden(self: State) bool {
        return self.override != null;
    }

    pub fn set(self: *State, configured: f32, requested: f32) void {
        const bounded = std.math.clamp(requested, config.min_font_size, config.max_font_size);
        self.override = if (bounded == configured) null else bounded;
    }

    pub fn reset(self: *State) void {
        self.override = null;
    }

    pub fn adjusted(self: State, configured: f32, delta: f32) ?f32 {
        const current = self.effective(configured);
        const next = std.math.clamp(current + delta, config.min_font_size, config.max_font_size);
        return if (next == current) null else next;
    }
};

test "temporary text zoom is bounded and resettable" {
    var state: State = .{};
    try std.testing.expectEqual(@as(f32, 14), state.effective(14));
    state.set(14, state.adjusted(14, 1).?);
    try std.testing.expect(state.isOverridden());
    try std.testing.expectEqual(@as(f32, 15), state.effective(14));
    state.reset();
    try std.testing.expectEqual(@as(f32, 14), state.effective(14));

    state.set(14, config.max_font_size);
    try std.testing.expect(state.adjusted(14, 1) == null);
    state.set(14, config.min_font_size);
    try std.testing.expect(state.adjusted(14, -1) == null);
}
