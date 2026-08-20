//! vtdiff: byte stream in, grid out (docs/references/conformance-testing.md).
//! Usage: vtdiff [--cols N] [--rows N] <file|->
//! Prints the final grid as text, the cursor, and the drained actions —
//! diffable against expected fixtures. Every reduced bug lands in
//! tests/corpus with this tool's output as the expectation.

const std = @import("std");
const vt = @import("vt");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    const stdout = std.Io.File.stdout();

    var cols: u16 = 80;
    var rows: u16 = 24;
    var path: ?[]const u8 = null;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();
    _ = args.next(); // argv[0]
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--cols")) {
            cols = try std.fmt.parseInt(u16, args.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--rows")) {
            rows = try std.fmt.parseInt(u16, args.next() orelse return error.MissingValue, 10);
        } else {
            path = arg;
        }
    }

    const input = blk: {
        const p = path orelse "-";
        if (std.mem.eql(u8, p, "-")) {
            const stdin = std.Io.File.stdin();
            var buf: std.ArrayList(u8) = .empty;
            var tmp: [4096]u8 = undefined;
            while (true) {
                const n = stdin.readStreaming(io, &.{&tmp}) catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => return err,
                };
                if (n == 0) break;
                try buf.appendSlice(alloc, tmp[0..n]);
            }
            break :blk try buf.toOwnedSlice(alloc);
        }
        break :blk try std.Io.Dir.cwd().readFileAlloc(io, p, alloc, .limited(64 * 1024 * 1024));
    };
    defer alloc.free(input);

    var v = try vt.Vt.init(alloc, cols, rows);
    defer v.deinit();
    v.feed(input);

    const dump = try v.term.dumpText(alloc);
    defer alloc.free(dump);
    try stdout.writeStreamingAll(io, dump);
    try stdout.writeStreamingAll(io, "\n");

    const cursor = try std.fmt.allocPrint(alloc, "-- cursor: row={d} col={d} pending_wrap={} alt={}\n", .{
        v.term.row, v.term.col, v.term.pending_wrap, v.term.on_alt,
    });
    defer alloc.free(cursor);
    try stdout.writeStreamingAll(io, cursor);

    for (v.term.drainActions()) |action| {
        switch (action) {
            .bell => try stdout.writeStreamingAll(io, "-- action: bell\n"),
            .set_title => |t| {
                try stdout.writeStreamingAll(io, "-- action: title \"");
                try stdout.writeStreamingAll(io, t);
                try stdout.writeStreamingAll(io, "\"\n");
            },
            .cwd_report => |uri| {
                try stdout.writeStreamingAll(io, "-- action: cwd_report \"");
                try stdout.writeStreamingAll(io, uri);
                try stdout.writeStreamingAll(io, "\"\n");
            },
            .notify => |notification| {
                const line = try std.fmt.allocPrint(
                    alloc,
                    "-- action: notify title=\"{s}\" body=\"{s}\"\n",
                    .{ notification.title, notification.body },
                );
                defer alloc.free(line);
                try stdout.writeStreamingAll(io, line);
            },
            .prompt_mark => |mark| {
                const line = try std.fmt.allocPrint(alloc, "-- action: prompt_mark {any}\n", .{mark});
                defer alloc.free(line);
                try stdout.writeStreamingAll(io, line);
            },
            .pty_write => |w| {
                const line = try std.fmt.allocPrint(alloc, "-- action: pty_write {any}\n", .{w});
                defer alloc.free(line);
                try stdout.writeStreamingAll(io, line);
            },
            .resize_request => |r| {
                const line = try std.fmt.allocPrint(alloc, "-- action: resize_request {d}x{d}\n", .{ r.cols, r.rows });
                defer alloc.free(line);
                try stdout.writeStreamingAll(io, line);
            },
            .graphics => try stdout.writeStreamingAll(io, "-- action: kitty_graphics\n"),
        }
    }
    v.term.clearActions();
}
