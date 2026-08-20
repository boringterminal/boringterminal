//! esctest harness (milestone 2a, docs/references/conformance-testing.md):
//! runs vendored esctest2 with its tty on a PTY bridged to the headless vt.
//! Bytes esctest writes drive the parser; vt's pty_write actions (DECRQCRA
//! checksums, CPR, XTWINOPS reports) flow back. resize_request actions are
//! honored here — this harness IS the resize policy for a windowless vt.
//!
//! Usage: zig build esctest -- [extra esctest args, e.g. --include=DECRQCRA]

const std = @import("std");
const vt = @import("vt.zig");
const pty_mod = @import("shell/pty.zig");

const esctest_py = "tests/vendor/esctest2/esctest/esctest.py";
const logfile = ".zig-cache/esctest.log";

/// Ratchet scope: the families our vt implements. Widen this regex as
/// sequences land; the expected-failures file must be regenerated in the
/// same change.
const ratchet_include = "--include=test_(CUP|CUB_|CUF_|CUD_|CUU_|CR_|LF_|IND_|RI_|ED_|EL_|ICH_|DCH_|ECH_|IL_|DL_|HTS|TBC|CHA_|VPA_|CHT_|CBT_|REP_|DECRQSS_(DECSTBM|SGR))";
const expected_failures_path = "tests/conformance/expected-failures.txt";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const stdout = std.Io.File.stdout();

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    const python = findPython(init.environ_map) orelse {
        try stdout.writeStreamingAll(io, "esctest-host: python3 not found in PATH\n");
        std.process.exit(2);
    };
    try argv.appendSlice(gpa, &.{
        python,
        esctest_py,
        "--expected-terminal",
        "xterm",
        // Modern xterm checksum semantics: positive sums, blanks = 0x20
        // (matches our DECRQCRA; see terminal.zig).
        "--xterm-checksum",
        "334",
        "--logfile",
        logfile,
        "--timeout",
        "2",
    });
    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();
    _ = args.next();
    var extra_args: usize = 0;
    while (args.next()) |a| {
        try argv.append(gpa, a);
        extra_args += 1;
    }
    // No args = ratchet mode: fixed scope, enforced expectations.
    const ratchet = extra_args == 0;
    if (ratchet) try argv.append(gpa, ratchet_include);

    var pty = try pty_mod.Pty.spawn(gpa, .{
        .argv = argv.items,
        .env = init.environ_map,
        .cols = 80,
        .rows = 25,
    });
    defer pty.closeFd();

    var v = try vt.Vt.init(gpa, 80, 25);
    defer v.deinit();

    var buf: [65536]u8 = undefined;
    while (true) {
        const n = pty.read(&buf);
        if (n == 0) break;
        v.feed(buf[0..n]);
        for (v.term.drainActions()) |action| switch (action) {
            .pty_write => |w| pty.writeBlockingForTestHost(w),
            .resize_request => |r| {
                v.term.resize(r.cols, r.rows) catch {};
                pty.resize(r.cols, r.rows, r.cols * 8, r.rows * 16);
            },
            .graphics => {},
            .bell, .set_title, .cwd_report, .notify, .prompt_mark => {},
        };
        v.term.clearActions();
    }
    const status = pty.waitStatus();

    const log = std.Io.Dir.cwd().readFileAlloc(io, logfile, gpa, .limited(16 * 1024 * 1024)) catch {
        try stdout.writeStreamingAll(io, "esctest-host: no logfile produced\n");
        std.process.exit(2);
    };
    defer gpa.free(log);

    if (!ratchet) {
        try stdout.writeStreamingAll(io, log);
        const line = try std.fmt.allocPrint(gpa, "esctest-host: esctest exited {d}\n", .{status});
        defer gpa.free(line);
        try stdout.writeStreamingAll(io, line);
        std.process.exit(status);
    }

    // Ratchet: actual failures must equal the expected set, both ways.
    // A fixed test missing from the file is a demand to tighten it; an
    // unexpected failure is a regression. Never delete to go green —
    // AGENTS.md rules apply.
    var actual = std.StringArrayHashMapUnmanaged(void){};
    defer actual.deinit(gpa);
    var log_lines = std.mem.splitScalar(u8, log, '\n');
    while (log_lines.next()) |line| {
        const prefix = "*** TEST ";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const rest = line[prefix.len..];
        const end = std.mem.indexOf(u8, rest, " FAILED") orelse continue;
        try actual.put(gpa, rest[0..end], {});
    }

    var expected = std.StringArrayHashMapUnmanaged(void){};
    defer expected.deinit(gpa);
    const exp_file = std.Io.Dir.cwd().readFileAlloc(io, expected_failures_path, gpa, .limited(1024 * 1024)) catch {
        try stdout.writeStreamingAll(io, "esctest-host: missing " ++ expected_failures_path ++ "\n");
        std.process.exit(2);
    };
    defer gpa.free(exp_file);
    var exp_lines = std.mem.splitScalar(u8, exp_file, '\n');
    while (exp_lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try expected.put(gpa, line, {});
    }

    var bad = false;
    for (actual.keys()) |name| {
        if (!expected.contains(name)) {
            bad = true;
            const msg = try std.fmt.allocPrint(gpa, "RATCHET REGRESSION: {s} now fails\n", .{name});
            defer gpa.free(msg);
            try stdout.writeStreamingAll(io, msg);
        }
    }
    for (expected.keys()) |name| {
        if (!actual.contains(name)) {
            bad = true;
            const msg = try std.fmt.allocPrint(gpa, "RATCHET TIGHTEN: {s} passes now — remove it from {s}\n", .{ name, expected_failures_path });
            defer gpa.free(msg);
            try stdout.writeStreamingAll(io, msg);
        }
    }

    var summary_it = std.mem.splitScalar(u8, log, '\n');
    while (summary_it.next()) |line| {
        if (std.mem.indexOf(u8, line, "tests passed") != null) {
            try stdout.writeStreamingAll(io, line);
            try stdout.writeStreamingAll(io, "\n");
        }
    }
    if (bad) {
        try stdout.writeStreamingAll(io, "esctest-host: RATCHET FAILED\n");
        std.process.exit(1);
    }
    try stdout.writeStreamingAll(io, "esctest-host: ratchet holds\n");
    std.process.exit(0);
}

fn findPython(env: *const std.process.Environ.Map) ?[:0]const u8 {
    const path = env.get("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path, ':');
    var buf: [1024]u8 = undefined;
    while (it.next()) |dir| {
        const candidate = std.fmt.bufPrintSentinel(&buf, "{s}/python3", .{dir}, 0) catch continue;
        if (std.c.access(candidate.ptr, 1) == 0) { // X_OK
            return std.heap.page_allocator.dupeZ(u8, candidate) catch null;
        }
    }
    return null;
}
