//! The deliberately small Boring Terminal configuration surface.
//! Parsing is pure; filesystem loading is viewer-owned (RFC 0013).

const std = @import("std");

pub const default_font_size: f32 = 13;
pub const min_font_size: f32 = 6;
pub const max_font_size: f32 = 72;
pub const max_file_bytes: usize = 64 * 1024;
pub const starter_file =
    \\# Boring Terminal configuration
    \\# font-family = "SF Mono"
    \\# font-size = 13
    \\
;

pub const Config = struct {
    font_family: ?[]u8 = null,
    font_size: f32 = default_font_size,

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        if (self.font_family) |family| alloc.free(family);
        self.* = undefined;
    }

    pub fn eql(a: Config, b: Config) bool {
        if (a.font_size != b.font_size) return false;
        if (a.font_family == null or b.font_family == null) return a.font_family == null and b.font_family == null;
        return std.mem.eql(u8, a.font_family.?, b.font_family.?);
    }
};

pub fn supportDirectory(
    alloc: std.mem.Allocator,
    env: *const std.process.Environ.Map,
) ![]u8 {
    const home = env.get("HOME") orelse return error.HomeNotSet;
    return std.fmt.allocPrint(
        alloc,
        "{s}/Library/Application Support/boringterminal",
        .{home},
    );
}

pub fn path(
    alloc: std.mem.Allocator,
    env: *const std.process.Environ.Map,
) ![]u8 {
    const directory = try supportDirectory(alloc, env);
    defer alloc.free(directory);
    return std.fs.path.join(alloc, &.{ directory, "config" });
}

pub fn load(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) !Config {
    const config_path = try path(alloc, env);
    defer alloc.free(config_path);
    return loadPath(alloc, io, config_path);
}

pub fn loadPath(alloc: std.mem.Allocator, io: std.Io, config_path: []const u8) !Config {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        config_path,
        alloc,
        .limited(max_file_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer alloc.free(bytes);
    return parse(alloc, bytes);
}

/// The config remains optional at launch. The explicit menu action calls this
/// before opening it, creating a no-op starter without ever truncating an
/// existing file.
pub fn ensureFile(io: std.Io, directory: []const u8, config_path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, directory);
    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = config_path,
        .data = starter_file,
        .flags = .{ .exclusive = true },
    }) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

pub fn parse(alloc: std.mem.Allocator, source: []const u8) !Config {
    var config: Config = .{};
    errdefer config.deinit(alloc);

    var saw_family = false;
    var saw_size = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const separator = std.mem.indexOfScalar(u8, line, '=') orelse
            return error.InvalidConfigLine;
        const key = std.mem.trim(u8, line[0..separator], " \t");
        const value = std.mem.trim(u8, line[separator + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) return error.InvalidConfigLine;

        if (std.mem.eql(u8, key, "font-family")) {
            if (saw_family) return error.DuplicateConfigKey;
            saw_family = true;
            config.font_family = try parseString(alloc, value);
        } else if (std.mem.eql(u8, key, "font-size")) {
            if (saw_size) return error.DuplicateConfigKey;
            saw_size = true;
            const unquoted = try stringView(value);
            const size = std.fmt.parseFloat(f32, unquoted) catch return error.InvalidFontSize;
            if (!std.math.isFinite(size) or size < min_font_size or size > max_font_size)
                return error.InvalidFontSize;
            config.font_size = size;
        } else {
            return error.UnknownConfigKey;
        }
    }

    return config;
}

fn parseString(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    const value = try stringView(raw);
    if (value.len == 0) return error.InvalidConfigValue;
    return alloc.dupe(u8, value);
}

fn stringView(raw: []const u8) ![]const u8 {
    if (raw[0] != '"') {
        if (std.mem.indexOfScalar(u8, raw, '"') != null or
            std.mem.indexOfScalar(u8, raw, '#') != null)
            return error.InvalidConfigValue;
        return raw;
    }
    if (raw.len < 2 or raw[raw.len - 1] != '"') return error.InvalidConfigValue;
    const value = raw[1 .. raw.len - 1];
    if (std.mem.indexOfScalar(u8, value, '"') != null) return error.InvalidConfigValue;
    return value;
}

test "font config parses quoted and bare values" {
    const alloc = std.testing.allocator;
    var quoted = try parse(alloc,
        \\# boring on purpose
        \\font-family = "SF Mono"
        \\font-size = 14.5
    );
    defer quoted.deinit(alloc);
    try std.testing.expectEqualStrings("SF Mono", quoted.font_family.?);
    try std.testing.expectEqual(@as(f32, 14.5), quoted.font_size);

    var bare = try parse(alloc, "font-family=Menlo\nfont-size=12\n");
    defer bare.deinit(alloc);
    try std.testing.expectEqualStrings("Menlo", bare.font_family.?);
    try std.testing.expectEqual(@as(f32, 12), bare.font_size);
}

test "empty font config keeps deterministic defaults" {
    var config = try parse(std.testing.allocator, "\n# defaults\n");
    defer config.deinit(std.testing.allocator);
    try std.testing.expect(config.font_family == null);
    try std.testing.expectEqual(default_font_size, config.font_size);
}

test "config equality includes optional family and size" {
    try std.testing.expect(Config.eql(.{}, .{}));
    try std.testing.expect(!Config.eql(.{}, .{ .font_size = 14 }));
    try std.testing.expect(Config.eql(
        .{ .font_family = @constCast("Menlo"), .font_size = 14 },
        .{ .font_family = @constCast("Menlo"), .font_size = 14 },
    ));
    try std.testing.expect(!Config.eql(
        .{ .font_family = @constCast("Menlo") },
        .{ .font_family = @constCast("SF Mono") },
    ));
}

test "font config rejects partial or ambiguous candidates" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.UnknownConfigKey, parse(alloc, "theme=dark"));
    try std.testing.expectError(
        error.DuplicateConfigKey,
        parse(alloc, "font-size=12\nfont-size=13"),
    );
    try std.testing.expectError(error.InvalidFontSize, parse(alloc, "font-size=5"));
    try std.testing.expectError(error.InvalidConfigValue, parse(alloc, "font-family=SF # Mono"));
    try std.testing.expectError(error.InvalidConfigLine, parse(alloc, "font-size"));
}

test "explicit config creation is safe and never overwrites" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const directory = try std.fs.path.join(alloc, &.{ root_buf[0..root_len], "support" });
    defer alloc.free(directory);
    const config_path = try std.fs.path.join(alloc, &.{ directory, "config" });
    defer alloc.free(config_path);

    try ensureFile(io, directory, config_path);
    const created = try std.Io.Dir.cwd().readFileAlloc(io, config_path, alloc, .limited(max_file_bytes));
    defer alloc.free(created);
    try std.testing.expectEqualStrings(starter_file, created);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = "font-size = 15\n" });
    try ensureFile(io, directory, config_path);
    const preserved = try std.Io.Dir.cwd().readFileAlloc(io, config_path, alloc, .limited(max_file_bytes));
    defer alloc.free(preserved);
    try std.testing.expectEqualStrings("font-size = 15\n", preserved);
}
