//! Reproducible local benchmark for RFC 0022 transport candidates.
//!
//! Performance is intentionally not a CI ratchet: Metal timings vary by GPU,
//! display load, power state, and runner virtualization. Exact pixels are
//! covered by the ordinary test suite; this tool emits comparable local data.

const std = @import("std");
const probe = @import("graphics_transport");

const Size = struct { width: u32, height: u32 };

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    var warmup: usize = 20;
    var frames: usize = 120;
    var json = false;
    var only_size: ?Size = null;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--warmup")) {
            warmup = try std.fmt.parseInt(usize, args.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--frames")) {
            frames = try std.fmt.parseInt(usize, args.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--size")) {
            const value = args.next() orelse return error.MissingValue;
            const separator = std.mem.indexOfScalar(u8, value, 'x') orelse return error.InvalidSize;
            only_size = .{
                .width = try std.fmt.parseInt(u32, value[0..separator], 10),
                .height = try std.fmt.parseInt(u32, value[separator + 1 ..], 10),
            };
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else {
            return error.UnknownArgument;
        }
    }

    const standard_sizes = [_]Size{
        .{ .width = 1280, .height = 720 },
        .{ .width = 1920, .height = 1080 },
        .{ .width = 2560, .height = 1440 },
        .{ .width = 3840, .height = 2160 },
    };
    var results: std.ArrayList(probe.Stats) = .empty;
    defer results.deinit(alloc);
    const sizes: []const Size = if (only_size) |*size| size[0..1] else &standard_sizes;
    for (sizes) |size| {
        for (std.meta.tags(probe.Lifecycle)) |lifecycle| {
            for (std.meta.tags(probe.Path)) |path| {
                const stats = probe.benchmark(
                    io,
                    alloc,
                    size.width,
                    size.height,
                    warmup,
                    frames,
                    path,
                    lifecycle,
                ) catch |err| switch (err) {
                    error.UnsupportedTransportPath => continue,
                    else => return err,
                };
                try results.append(alloc, stats);
            }
        }
    }

    const stdout = std.Io.File.stdout();
    if (json) {
        try stdout.writeStreamingAll(io, "[\n");
        for (results.items, 0..) |stats, index| {
            const line = try std.fmt.allocPrint(
                alloc,
                "  {{\"path\":\"{s}\",\"lifecycle\":\"{s}\",\"width\":{d},\"height\":{d},\"frames\":{d},\"p50_ns\":{d},\"p95_ns\":{d},\"max_ns\":{d}}}{s}\n",
                .{ stats.path.label(), stats.lifecycle.label(), stats.width, stats.height, stats.frames, stats.p50_ns, stats.p95_ns, stats.max_ns, if (index + 1 == results.items.len) "" else "," },
            );
            defer alloc.free(line);
            try stdout.writeStreamingAll(io, line);
        }
        try stdout.writeStreamingAll(io, "]\n");
    } else {
        try stdout.writeStreamingAll(io, "lifecycle path                         size       p50 ms   p95 ms   max ms\n");
        for (results.items) |stats| {
            const line = try std.fmt.allocPrint(
                alloc,
                "{s: <9} {s: <28} {d: >4}x{d:<4} {d: >8.3} {d: >8.3} {d: >8.3}\n",
                .{
                    stats.lifecycle.label(),
                    stats.path.label(),
                    stats.width,
                    stats.height,
                    @as(f64, @floatFromInt(stats.p50_ns)) / std.time.ns_per_ms,
                    @as(f64, @floatFromInt(stats.p95_ns)) / std.time.ns_per_ms,
                    @as(f64, @floatFromInt(stats.max_ns)) / std.time.ns_per_ms,
                },
            );
            defer alloc.free(line);
            try stdout.writeStreamingAll(io, line);
        }
    }
}
