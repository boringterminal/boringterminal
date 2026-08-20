//! Hermetic, source-independent Kitty keyboard corpus runner.
//!
//! Cases are authored from the public protocol and Boring Terminal RFCs. The
//! runner deliberately calls the production VT encoder and attach-dialect
//! dispatch instead of carrying a second keyboard implementation.

const std = @import("std");
const vt = @import("vt.zig");
const protocol = @import("daemon/protocol.zig");
const selected = @import("shell/daemon_protocol/selected.zig");
const key_normalizer = @import("shell/key_normalizer.zig");
const native_input = @import("shell/input.zig");
const pty_mod = @import("shell/pty.zig");

const corpus_root = "tests/kitty-keyboard";
const cases_root = corpus_root ++ "/cases";
const ratchet_path = corpus_root ++ "/ratchet.txt";
const exclusions_path = corpus_root ++ "/exclusions.txt";
const spec_url = "https://sw.kovidgoyal.net/kitty/keyboard-protocol/";
const spec_retrieved = "2026-08-19";
const max_case_bytes = 64 * 1024;

const Layer = enum { negotiation, encoder, dialect, matrix, pty };
const MatrixKind = enum {
    flag_powerset,
    modifier_powerset,
    native_key_actions,
    legacy_control_ascii,
    legacy_recovery,
    codec_boundaries,
};
const ProvenanceKind = enum { spec, @"rfc-policy", regression, @"black-box-corroborated" };
const Dispatch = enum { key, write, ignored };

const Provenance = struct {
    kind: ProvenanceKind,
    source: []const u8,
    spec_url: ?[]const u8 = null,
    spec_retrieved: ?[]const u8 = null,
    spec_sections: []const []const u8 = &.{},
    rfc: ?[]const u8 = null,
    regression: ?[]const u8 = null,
};

const Initial = struct {
    flags: u8 = 0,
    cursor_keys: bool = false,
};

const CaseModifiers = struct {
    shift: bool = false,
    alt: bool = false,
    control: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,

    fn production(self: CaseModifiers) vt.keyboard.Modifiers {
        return .{
            .shift = self.shift,
            .alt = self.alt,
            .control = self.control,
            .super = self.super,
            .caps_lock = self.caps_lock,
            .num_lock = self.num_lock,
        };
    }
};

const CaseEvent = struct {
    code: vt.keyboard.Code,
    codepoint: u21 = 0,
    shifted_codepoint: u21 = 0,
    base_layout_codepoint: u21 = 0,
    modifiers: CaseModifiers = .{},
    action: vt.keyboard.Action = .press,
    text_hex: []const u8 = "",

    fn production(self: CaseEvent, alloc: std.mem.Allocator) !vt.keyboard.Event {
        return .{
            .code = self.code,
            .codepoint = self.codepoint,
            .shifted_codepoint = self.shifted_codepoint,
            .base_layout_codepoint = self.base_layout_codepoint,
            .modifiers = self.modifiers.production(),
            .action = self.action,
            .text = try decodeHex(alloc, self.text_hex),
        };
    }
};

const Expect = struct {
    pty_hex: ?[]const u8 = null,
    suppressed: bool = false,
    flags: ?u8 = null,
    dispatches: []const Dispatch = &.{},
    request_payload_hexes: []const []const u8 = &.{},
};

const Step = struct {
    feed_hex: ?[]const u8 = null,
    event: ?CaseEvent = null,

    fn validateTag(self: Step) !void {
        if ((self.feed_hex != null) == (self.event != null)) return error.InvalidStepTag;
    }
};

const Case = struct {
    schema: u8,
    id: []const u8,
    layer: Layer,
    provenance: Provenance,
    dialect: ?u16 = null,
    initial: Initial = .{},
    split_every_byte: bool = false,
    steps: []const Step = &.{},
    expect: Expect = .{},
    matrix: ?MatrixKind = null,
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    const stdout = std.Io.File.stdout();

    var ids: std.ArrayList([]const u8) = .empty;
    defer {
        for (ids.items) |id| alloc.free(id);
        ids.deinit(alloc);
    }
    var seen: std.StringHashMap(void) = .init(alloc);
    defer seen.deinit();

    var dir = try std.Io.Dir.cwd().openDir(io, cases_root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".json")) continue;
        const bytes = try entry.dir.readFileAlloc(io, entry.basename, alloc, .limited(max_case_bytes));
        defer alloc.free(bytes);

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const case = std.json.parseFromSliceLeaky(
            Case,
            arena.allocator(),
            bytes,
            .{ .ignore_unknown_fields = false },
        ) catch |err| {
            try fail(io, "{s}: invalid case JSON: {s}", .{ entry.path, @errorName(err) });
            return error.ConformanceFailure;
        };
        validateCase(case) catch |err| {
            try fail(io, "{s}: invalid case metadata: {s}", .{ case.id, @errorName(err) });
            return error.ConformanceFailure;
        };
        if (seen.contains(case.id)) {
            try fail(io, "duplicate case id: {s}", .{case.id});
            return error.ConformanceFailure;
        }
        try addPassedId(alloc, &ids, &seen, case.id);

        runCase(alloc, arena.allocator(), case, &ids, &seen) catch |err| {
            try fail(io, "{s}: case failed: {s}", .{ case.id, @errorName(err) });
            return error.ConformanceFailure;
        };
    }

    if (ids.items.len == 0) {
        try fail(io, "no Kitty keyboard cases discovered under {s}", .{cases_root});
        return error.ConformanceFailure;
    }
    std.mem.sort([]const u8, ids.items, {}, lessThanString);
    verifyRatchet(alloc, io, ids.items, seen) catch |err| {
        try fail(io, "ratchet failed: {s}", .{@errorName(err)});
        return error.ConformanceFailure;
    };

    const summary = try std.fmt.allocPrint(
        alloc,
        "kitty-keyboard-conformance: {d} checks passed; ratchet exact\n",
        .{ids.items.len},
    );
    defer alloc.free(summary);
    try stdout.writeStreamingAll(io, summary);
}

fn validateCase(case: Case) !void {
    if (case.schema != 1) return error.UnsupportedSchema;
    if (!stableId(case.id)) return error.InvalidId;
    const layer_name = @tagName(case.layer);
    if (!std.mem.startsWith(u8, case.id, layer_name) or
        case.id.len <= layer_name.len or case.id[layer_name.len] != '.')
        return error.InvalidId;
    try validateProvenance(case.provenance);
    if (case.initial.flags & ~vt.keyboard.supported_flags != 0) return error.UnsupportedFlags;

    switch (case.layer) {
        .negotiation => {
            if (case.matrix != null or case.dialect != null or case.steps.len == 0 or
                case.expect.flags == null or case.expect.pty_hex == null or case.expect.suppressed or
                case.expect.dispatches.len != 0 or case.expect.request_payload_hexes.len != 0)
                return error.InvalidLayerShape;
            for (case.steps) |step| {
                try step.validateTag();
                if (step.feed_hex == null) return error.InvalidLayerShape;
                try validateHex(step.feed_hex.?);
            }
            try validateHex(case.expect.pty_hex.?);
        },
        .encoder => {
            if (case.matrix != null or case.dialect != null or case.steps.len != 1 or
                case.expect.flags != null or case.expect.dispatches.len != 0 or
                case.expect.request_payload_hexes.len != 0)
                return error.InvalidLayerShape;
            if (case.expect.suppressed == (case.expect.pty_hex != null)) return error.InvalidExpectation;
            if (case.expect.pty_hex) |hex| try validateHex(hex);
            try case.steps[0].validateTag();
            try validateEvent(case.steps[0].event orelse return error.InvalidLayerShape);
        },
        .dialect, .pty => {
            if (case.matrix != null) return error.InvalidLayerShape;
            const dialect = case.dialect orelse return error.InvalidLayerShape;
            if (dialect != 18 and dialect != 13 and dialect != 10) return error.UnsupportedDialect;
            if (case.steps.len == 0 or case.expect.flags != null or
                case.expect.suppressed or case.expect.pty_hex == null or
                case.expect.dispatches.len != case.steps.len or
                case.expect.request_payload_hexes.len != case.steps.len)
                return error.InvalidLayerShape;
            try validateHex(case.expect.pty_hex.?);
            for (case.steps, case.expect.request_payload_hexes) |step, hex| {
                try step.validateTag();
                try validateEvent(step.event orelse return error.InvalidLayerShape);
                try validateHex(hex);
            }
        },
        .matrix => {
            if (case.matrix == null or case.dialect != null or case.steps.len != 0 or
                case.initial.flags != 0 or case.initial.cursor_keys or case.split_every_byte or
                case.expect.pty_hex != null or case.expect.suppressed or case.expect.flags != null or
                case.expect.dispatches.len != 0 or case.expect.request_payload_hexes.len != 0)
                return error.InvalidLayerShape;
        },
    }
}

fn validateProvenance(provenance: Provenance) !void {
    if (provenance.source.len == 0) return error.MissingProvenance;
    switch (provenance.kind) {
        .spec, .regression => {
            if (provenance.spec_url == null or
                !std.mem.eql(u8, provenance.spec_url.?, spec_url) or
                provenance.spec_retrieved == null or
                !std.mem.eql(u8, provenance.spec_retrieved.?, spec_retrieved) or
                provenance.spec_sections.len == 0)
                return error.MissingSpecAnchor;
            for (provenance.spec_sections) |section| if (section.len == 0) return error.MissingSpecAnchor;
            if (provenance.kind == .regression and
                (provenance.regression == null or provenance.regression.?.len == 0))
                return error.MissingRegressionAnchor;
        },
        .@"rfc-policy" => if (provenance.rfc == null or provenance.rfc.?.len == 0)
            return error.MissingRfcAnchor,
        .@"black-box-corroborated" => return error.GuiOracleNotImplemented,
    }
}

fn validateEvent(event: CaseEvent) !void {
    try validateHex(event.text_hex);
    if (event.text_hex.len / 2 > vt.keyboard.max_text_bytes) return error.TextTooLarge;
    if (!validScalar(event.codepoint) or !validScalar(event.shifted_codepoint) or
        !validScalar(event.base_layout_codepoint))
        return error.InvalidScalar;
}

fn runCase(
    alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    case: Case,
    ids: *std.ArrayList([]const u8),
    seen: *std.StringHashMap(void),
) !void {
    switch (case.layer) {
        .negotiation => try runNegotiation(arena, case),
        .encoder => try runEncoder(arena, case),
        .dialect => try runDialect(arena, case, false),
        .pty => try runDialect(arena, case, true),
        .matrix => try runMatrix(alloc, arena, case.matrix.?, ids, seen),
    }
}

fn addPassedId(
    alloc: std.mem.Allocator,
    ids: *std.ArrayList([]const u8),
    seen: *std.StringHashMap(void),
    id: []const u8,
) !void {
    if (!stableId(id) or seen.contains(id)) return error.DuplicateOrInvalidId;
    const owned = try alloc.dupe(u8, id);
    errdefer alloc.free(owned);
    try ids.append(alloc, owned);
    try seen.put(owned, {});
}

fn runNegotiation(alloc: std.mem.Allocator, case: Case) !void {
    var input_list: std.ArrayList(u8) = .empty;
    defer input_list.deinit(alloc);
    for (case.steps) |step| {
        const bytes = try decodeHex(alloc, step.feed_hex.?);
        try input_list.appendSlice(alloc, bytes);
    }
    const input = input_list.items;
    const expected = try decodeHex(alloc, case.expect.pty_hex.?);
    try runNegotiationSplit(alloc, input, null, case.expect.flags.?, expected);
    if (case.split_every_byte) {
        var split: usize = 1;
        while (split < input.len) : (split += 1)
            try runNegotiationSplit(alloc, input, split, case.expect.flags.?, expected);
    }
}

fn runNegotiationSplit(
    alloc: std.mem.Allocator,
    input: []const u8,
    split: ?usize,
    expected_flags: u8,
    expected_pty: []const u8,
) !void {
    var machine = try vt.Vt.init(alloc, 12, 4);
    defer machine.deinit();
    if (split) |at| {
        machine.feed(input[0..at]);
        machine.feed(input[at..]);
    } else machine.feed(input);

    if (machine.term.keyboardFlags().bits() != expected_flags) return error.FlagsMismatch;
    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(alloc);
    for (machine.term.drainActions()) |action| switch (action) {
        .pty_write => |bytes| try actual.appendSlice(alloc, bytes),
        else => return error.UnexpectedAction,
    };
    if (!std.mem.eql(u8, actual.items, expected_pty)) return error.PtyBytesMismatch;
    machine.term.clearActions();
}

fn runEncoder(alloc: std.mem.Allocator, case: Case) !void {
    const event = try case.steps[0].event.?.production(alloc);
    const flags = vt.keyboard.Flags.supported(case.initial.flags);
    const expected = if (case.expect.pty_hex) |hex| try decodeHex(alloc, hex) else null;
    inline for (.{ @as(u8, 0xa5), @as(u8, 0x3c) }) |fill| {
        var buf: [64 * 1024]u8 = @splat(fill);
        const actual = try vt.keyboard.encode(&buf, flags, case.initial.cursor_keys, event);
        if (case.expect.suppressed) {
            if (actual != null) return error.ExpectedSuppression;
        } else {
            if (actual == null or !std.mem.eql(u8, actual.?, expected.?))
                return error.PtyBytesMismatch;
        }
    }
}

fn runDialect(alloc: std.mem.Allocator, case: Case, real_pty: bool) !void {
    const dialect: selected.Dialect = switch (case.dialect.?) {
        18 => if (protocol.version == 18) .current else return error.CurrentDialectChanged,
        13 => .v13,
        10 => .v10,
        else => unreachable,
    };
    const session_id: u64 = 42;
    var child_bytes: std.ArrayList(u8) = .empty;
    defer child_bytes.deinit(alloc);

    for (case.steps, case.expect.dispatches, case.expect.request_payload_hexes) |
        step,
        expected_dispatch,
        expected_hex,
    | {
        const event = try step.event.?.production(alloc);
        var semantic = protocol.Encoder.init(alloc);
        defer semantic.deinit();
        try semantic.int(u64, session_id);
        const classification = try selected.encodeKeyEvent(dialect, &semantic, event);

        var raw_request = protocol.Encoder.init(alloc);
        defer raw_request.deinit();
        var actual_payload: []const u8 = &.{};
        const actual_dispatch: Dispatch = switch (classification) {
            .semantic => blk: {
                actual_payload = semantic.slice();
                if (dialect == .current) {
                    var decoder: protocol.Decoder = .{ .bytes = semantic.slice()[@sizeOf(u64)..] };
                    const decoded = try protocol.decodeKeyEvent(&decoder);
                    if (!eventsEqual(event, decoded)) return error.CodecRoundTripMismatch;
                }
                var encoded_buf: [64 * 1024]u8 = undefined;
                const encoded = try vt.keyboard.encode(
                    &encoded_buf,
                    vt.keyboard.Flags.supported(case.initial.flags),
                    case.initial.cursor_keys,
                    event,
                );
                if (encoded) |bytes| try child_bytes.appendSlice(alloc, bytes);
                break :blk .key;
            },
            .raw => |bytes| blk: {
                try raw_request.int(u64, session_id);
                try raw_request.bytes(bytes);
                actual_payload = raw_request.slice();
                try child_bytes.appendSlice(alloc, bytes);
                break :blk .write;
            },
            .ignored => .ignored,
        };
        if (actual_dispatch != expected_dispatch) return error.DispatchMismatch;
        const expected_payload = try decodeHex(alloc, expected_hex);
        if (!std.mem.eql(u8, actual_payload, expected_payload)) return error.RequestPayloadMismatch;
    }
    const expected_child = try decodeHex(alloc, case.expect.pty_hex.?);
    if (!std.mem.eql(u8, child_bytes.items, expected_child)) return error.PtyBytesMismatch;
    if (real_pty) try runPtyFixture(alloc, child_bytes.items);
}

fn runPtyFixture(alloc: std.mem.Allocator, expected: []const u8) !void {
    if (expected.len == 0) return error.EmptyPtyFixture;
    const command = try std.fmt.allocPrint(
        alloc,
        "stty raw -echo; printf 'PTY_READY\\n'; " ++
            "bytes=$(dd bs=1 count={d} 2>/dev/null | od -An -tx1 | tr -d ' \\n'); " ++
            "stty sane; printf 'PTY_HEX:%s\\n' \"$bytes\"",
        .{expected.len},
    );
    defer alloc.free(command);
    var pty = try pty_mod.Pty.spawn(alloc, .{
        .argv = &.{ "/bin/sh", "-c", command },
    });
    defer pty.closeFd();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(alloc);
    var buf: [512]u8 = undefined;
    while (std.mem.indexOf(u8, output.items, "PTY_READY\n") == null) {
        const count = pty.read(&buf);
        if (count == 0) return error.PtyFixtureExitedEarly;
        try output.appendSlice(alloc, buf[0..count]);
    }
    pty.writeBlockingForTestHost(expected);
    while (true) {
        const count = pty.read(&buf);
        if (count == 0) break;
        try output.appendSlice(alloc, buf[0..count]);
    }
    if (pty.waitStatus() != 0) return error.PtyFixtureFailed;
    const expected_hex = try std.fmt.allocPrint(alloc, "PTY_HEX:{x}\r\n", .{expected});
    defer alloc.free(expected_hex);
    if (std.mem.indexOf(u8, output.items, expected_hex) == null) return error.PtyBytesMismatch;
}

const NativeKind = enum { key, modifier };
const KeyInventory = struct {
    name: []const u8,
    key_code: u16,
    code: vt.keyboard.Code,
    number: u21,
    final: u8,
    native_kind: NativeKind = .key,
};

const key_inventory = [_]KeyInventory{
    .{ .name = "escape", .key_code = 53, .code = .escape, .number = 27, .final = 'u' },
    .{ .name = "enter", .key_code = 36, .code = .enter, .number = 13, .final = 'u' },
    .{ .name = "tab", .key_code = 48, .code = .tab, .number = 9, .final = 'u' },
    .{ .name = "backspace", .key_code = 51, .code = .backspace, .number = 127, .final = 'u' },
    .{ .name = "insert", .key_code = 114, .code = .insert, .number = 2, .final = '~' },
    .{ .name = "delete", .key_code = 117, .code = .delete_forward, .number = 3, .final = '~' },
    .{ .name = "up", .key_code = 126, .code = .up, .number = 1, .final = 'A' },
    .{ .name = "down", .key_code = 125, .code = .down, .number = 1, .final = 'B' },
    .{ .name = "right", .key_code = 124, .code = .right, .number = 1, .final = 'C' },
    .{ .name = "left", .key_code = 123, .code = .left, .number = 1, .final = 'D' },
    .{ .name = "home", .key_code = 115, .code = .home, .number = 1, .final = 'H' },
    .{ .name = "end", .key_code = 119, .code = .end, .number = 1, .final = 'F' },
    .{ .name = "page-up", .key_code = 116, .code = .page_up, .number = 5, .final = '~' },
    .{ .name = "page-down", .key_code = 121, .code = .page_down, .number = 6, .final = '~' },
    .{ .name = "f1", .key_code = 122, .code = .f1, .number = 1, .final = 'P' },
    .{ .name = "f2", .key_code = 120, .code = .f2, .number = 1, .final = 'Q' },
    .{ .name = "f3", .key_code = 99, .code = .f3, .number = 13, .final = '~' },
    .{ .name = "f4", .key_code = 118, .code = .f4, .number = 1, .final = 'S' },
    .{ .name = "f5", .key_code = 96, .code = .f5, .number = 15, .final = '~' },
    .{ .name = "f6", .key_code = 97, .code = .f6, .number = 17, .final = '~' },
    .{ .name = "f7", .key_code = 98, .code = .f7, .number = 18, .final = '~' },
    .{ .name = "f8", .key_code = 100, .code = .f8, .number = 19, .final = '~' },
    .{ .name = "f9", .key_code = 101, .code = .f9, .number = 20, .final = '~' },
    .{ .name = "f10", .key_code = 109, .code = .f10, .number = 21, .final = '~' },
    .{ .name = "f11", .key_code = 103, .code = .f11, .number = 23, .final = '~' },
    .{ .name = "f12", .key_code = 111, .code = .f12, .number = 24, .final = '~' },
    .{ .name = "f13", .key_code = 105, .code = .f13, .number = 57376, .final = 'u' },
    .{ .name = "f14", .key_code = 107, .code = .f14, .number = 57377, .final = 'u' },
    .{ .name = "f15", .key_code = 113, .code = .f15, .number = 57378, .final = 'u' },
    .{ .name = "f16", .key_code = 106, .code = .f16, .number = 57379, .final = 'u' },
    .{ .name = "f17", .key_code = 64, .code = .f17, .number = 57380, .final = 'u' },
    .{ .name = "f18", .key_code = 79, .code = .f18, .number = 57381, .final = 'u' },
    .{ .name = "f19", .key_code = 80, .code = .f19, .number = 57382, .final = 'u' },
    .{ .name = "f20", .key_code = 90, .code = .f20, .number = 57383, .final = 'u' },
    .{ .name = "kp-0", .key_code = 82, .code = .kp_0, .number = 57399, .final = 'u' },
    .{ .name = "kp-1", .key_code = 83, .code = .kp_1, .number = 57400, .final = 'u' },
    .{ .name = "kp-2", .key_code = 84, .code = .kp_2, .number = 57401, .final = 'u' },
    .{ .name = "kp-3", .key_code = 85, .code = .kp_3, .number = 57402, .final = 'u' },
    .{ .name = "kp-4", .key_code = 86, .code = .kp_4, .number = 57403, .final = 'u' },
    .{ .name = "kp-5", .key_code = 87, .code = .kp_5, .number = 57404, .final = 'u' },
    .{ .name = "kp-6", .key_code = 88, .code = .kp_6, .number = 57405, .final = 'u' },
    .{ .name = "kp-7", .key_code = 89, .code = .kp_7, .number = 57406, .final = 'u' },
    .{ .name = "kp-8", .key_code = 91, .code = .kp_8, .number = 57407, .final = 'u' },
    .{ .name = "kp-9", .key_code = 92, .code = .kp_9, .number = 57408, .final = 'u' },
    .{ .name = "kp-decimal", .key_code = 65, .code = .kp_decimal, .number = 57409, .final = 'u' },
    .{ .name = "kp-divide", .key_code = 75, .code = .kp_divide, .number = 57410, .final = 'u' },
    .{ .name = "kp-multiply", .key_code = 67, .code = .kp_multiply, .number = 57411, .final = 'u' },
    .{ .name = "kp-subtract", .key_code = 78, .code = .kp_subtract, .number = 57412, .final = 'u' },
    .{ .name = "kp-add", .key_code = 69, .code = .kp_add, .number = 57413, .final = 'u' },
    .{ .name = "kp-enter", .key_code = 76, .code = .kp_enter, .number = 57414, .final = 'u' },
    .{ .name = "kp-equal", .key_code = 81, .code = .kp_equal, .number = 57415, .final = 'u' },
    .{ .name = "caps-lock", .key_code = 57, .code = .caps_lock, .number = 57358, .final = 'u', .native_kind = .modifier },
    .{ .name = "num-lock", .key_code = 71, .code = .num_lock, .number = 57360, .final = 'u' },
    .{ .name = "left-shift", .key_code = 56, .code = .left_shift, .number = 57441, .final = 'u', .native_kind = .modifier },
    .{ .name = "left-control", .key_code = 59, .code = .left_control, .number = 57442, .final = 'u', .native_kind = .modifier },
    .{ .name = "left-alt", .key_code = 58, .code = .left_alt, .number = 57443, .final = 'u', .native_kind = .modifier },
    .{ .name = "left-super", .key_code = 55, .code = .left_super, .number = 57444, .final = 'u', .native_kind = .modifier },
    .{ .name = "right-shift", .key_code = 60, .code = .right_shift, .number = 57447, .final = 'u', .native_kind = .modifier },
    .{ .name = "right-control", .key_code = 62, .code = .right_control, .number = 57448, .final = 'u', .native_kind = .modifier },
    .{ .name = "right-alt", .key_code = 61, .code = .right_alt, .number = 57449, .final = 'u', .native_kind = .modifier },
    .{ .name = "right-super", .key_code = 54, .code = .right_super, .number = 57450, .final = 'u', .native_kind = .modifier },
};

const PhysicalInventory = struct { key_code: u16, base: u21 };
const physical_inventory = [_]PhysicalInventory{
    .{ .key_code = 0, .base = 'a' },
    .{ .key_code = 1, .base = 's' },
    .{ .key_code = 2, .base = 'd' },
    .{ .key_code = 3, .base = 'f' },
    .{ .key_code = 4, .base = 'h' },
    .{ .key_code = 5, .base = 'g' },
    .{ .key_code = 6, .base = 'z' },
    .{ .key_code = 7, .base = 'x' },
    .{ .key_code = 8, .base = 'c' },
    .{ .key_code = 9, .base = 'v' },
    .{ .key_code = 11, .base = 'b' },
    .{ .key_code = 12, .base = 'q' },
    .{ .key_code = 13, .base = 'w' },
    .{ .key_code = 14, .base = 'e' },
    .{ .key_code = 15, .base = 'r' },
    .{ .key_code = 16, .base = 'y' },
    .{ .key_code = 17, .base = 't' },
    .{ .key_code = 18, .base = '1' },
    .{ .key_code = 19, .base = '2' },
    .{ .key_code = 20, .base = '3' },
    .{ .key_code = 21, .base = '4' },
    .{ .key_code = 22, .base = '6' },
    .{ .key_code = 23, .base = '5' },
    .{ .key_code = 24, .base = '=' },
    .{ .key_code = 25, .base = '9' },
    .{ .key_code = 26, .base = '7' },
    .{ .key_code = 27, .base = '-' },
    .{ .key_code = 28, .base = '8' },
    .{ .key_code = 29, .base = '0' },
    .{ .key_code = 30, .base = ']' },
    .{ .key_code = 31, .base = 'o' },
    .{ .key_code = 32, .base = 'u' },
    .{ .key_code = 33, .base = '[' },
    .{ .key_code = 34, .base = 'i' },
    .{ .key_code = 35, .base = 'p' },
    .{ .key_code = 37, .base = 'l' },
    .{ .key_code = 38, .base = 'j' },
    .{ .key_code = 39, .base = '\'' },
    .{ .key_code = 40, .base = 'k' },
    .{ .key_code = 41, .base = ';' },
    .{ .key_code = 42, .base = '\\' },
    .{ .key_code = 43, .base = ',' },
    .{ .key_code = 44, .base = '/' },
    .{ .key_code = 45, .base = 'n' },
    .{ .key_code = 46, .base = 'm' },
    .{ .key_code = 47, .base = '.' },
    .{ .key_code = 49, .base = ' ' },
    .{ .key_code = 50, .base = '`' },
};

fn runMatrix(
    alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    kind: MatrixKind,
    ids: *std.ArrayList([]const u8),
    seen: *std.StringHashMap(void),
) !void {
    switch (kind) {
        .flag_powerset => try runFlagPowerset(alloc, arena, ids, seen),
        .modifier_powerset => try runModifierPowerset(alloc, arena, ids, seen),
        .native_key_actions => try runNativeKeyActions(alloc, ids, seen),
        .legacy_control_ascii => try runLegacyControlAscii(alloc, ids, seen),
        .legacy_recovery => try runLegacyRecovery(alloc, ids, seen),
        .codec_boundaries => try runCodecBoundaries(alloc, ids, seen),
    }
}

fn runFlagPowerset(
    alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    ids: *std.ArrayList([]const u8),
    seen: *std.StringHashMap(void),
) !void {
    for (0..32) |raw| {
        const input_bytes = try std.fmt.allocPrint(arena, "\x1b[={d};1u\x1b[?u", .{raw});
        const expected = try std.fmt.allocPrint(arena, "\x1b[?{d}u", .{raw});
        try runNegotiationSplit(arena, input_bytes, null, @intCast(raw), expected);
        var split: usize = 1;
        while (split < input_bytes.len) : (split += 1)
            try runNegotiationSplit(arena, input_bytes, split, @intCast(raw), expected);
        const id = try std.fmt.allocPrint(arena, "matrix.flags.{d:0>2}", .{raw});
        try addPassedId(alloc, ids, seen, id);
    }
}

fn modifiersFromRaw(raw: u8) vt.keyboard.Modifiers {
    return .{
        .shift = raw & 1 != 0,
        .alt = raw & 2 != 0,
        .control = raw & 4 != 0,
        .super = raw & 8 != 0,
        .caps_lock = raw & 16 != 0,
        .num_lock = raw & 32 != 0,
    };
}

fn specModifierParameter(modifiers: vt.keyboard.Modifiers) u16 {
    return 1 + @as(u16, @intFromBool(modifiers.shift)) +
        2 * @as(u16, @intFromBool(modifiers.alt)) +
        4 * @as(u16, @intFromBool(modifiers.control)) +
        8 * @as(u16, @intFromBool(modifiers.super)) +
        64 * @as(u16, @intFromBool(modifiers.caps_lock)) +
        128 * @as(u16, @intFromBool(modifiers.num_lock));
}

fn runModifierPowerset(
    alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    ids: *std.ArrayList([]const u8),
    seen: *std.StringHashMap(void),
) !void {
    const flags: vt.keyboard.Flags = .{ .disambiguate = true, .report_all = true };
    for (0..64) |raw| {
        const modifiers = modifiersFromRaw(@intCast(raw));
        var buf: [128]u8 = undefined;
        const actual = (try vt.keyboard.encode(&buf, flags, false, .{
            .code = .codepoint,
            .codepoint = 'a',
            .modifiers = modifiers,
        })).?;
        const parameter = specModifierParameter(modifiers);
        const expected = if (parameter == 1)
            "\x1b[97u"
        else
            try std.fmt.allocPrint(arena, "\x1b[97;{d}u", .{parameter});
        if (!std.mem.eql(u8, actual, expected)) return error.ModifierMatrixMismatch;
        const id = try std.fmt.allocPrint(arena, "matrix.modifiers.{d:0>2}", .{raw});
        try addPassedId(alloc, ids, seen, id);
    }
}

fn modifierForCode(code: vt.keyboard.Code) vt.keyboard.Modifiers {
    var modifiers: vt.keyboard.Modifiers = .{};
    switch (code) {
        .caps_lock => modifiers.caps_lock = true,
        .left_shift, .right_shift => modifiers.shift = true,
        .left_control, .right_control => modifiers.control = true,
        .left_alt, .right_alt => modifiers.alt = true,
        .left_super, .right_super => modifiers.super = true,
        else => {},
    }
    return modifiers;
}

fn expectedInventoryBytes(
    out: []u8,
    entry: KeyInventory,
    action: vt.keyboard.Action,
    modifiers: vt.keyboard.Modifiers,
) ![]const u8 {
    const parameter = specModifierParameter(modifiers);
    const event_type: u8 = switch (action) {
        .press => 1,
        .repeat => 2,
        .release => 3,
    };
    if (entry.final == 'u') {
        if (action == .press and parameter == 1)
            return std.fmt.bufPrint(out, "\x1b[{d}u", .{entry.number});
        if (action == .press)
            return std.fmt.bufPrint(out, "\x1b[{d};{d}u", .{ entry.number, parameter });
        return std.fmt.bufPrint(out, "\x1b[{d};{d}:{d}u", .{ entry.number, parameter, event_type });
    }
    if (entry.final == '~') {
        if (action == .press and parameter == 1)
            return std.fmt.bufPrint(out, "\x1b[{d}~", .{entry.number});
        if (action == .press)
            return std.fmt.bufPrint(out, "\x1b[{d};{d}~", .{ entry.number, parameter });
        return std.fmt.bufPrint(out, "\x1b[{d};{d}:{d}~", .{ entry.number, parameter, event_type });
    }
    if (action == .press and parameter == 1)
        return std.fmt.bufPrint(out, "\x1b[{c}", .{entry.final});
    if (action == .press)
        return std.fmt.bufPrint(out, "\x1b[1;{d}{c}", .{ parameter, entry.final });
    return std.fmt.bufPrint(out, "\x1b[1;{d}:{d}{c}", .{ parameter, event_type, entry.final });
}

fn runNativeKeyActions(
    alloc: std.mem.Allocator,
    ids: *std.ArrayList([]const u8),
    seen: *std.StringHashMap(void),
) !void {
    var covered: [std.meta.fields(vt.keyboard.Code).len]bool = @splat(false);
    var covered_key_codes: [128]bool = @splat(false);
    const flags: vt.keyboard.Flags = .{
        .disambiguate = true,
        .report_events = true,
        .report_alternates = true,
        .report_all = true,
        .report_associated = true,
    };
    for (key_inventory) |entry| {
        if (entry.key_code >= covered_key_codes.len or covered_key_codes[entry.key_code])
            return error.DuplicateNativeKeyCode;
        covered_key_codes[entry.key_code] = true;
        const code_index: usize = @intFromEnum(entry.code);
        if (covered[code_index]) return error.DuplicateKeyInventory;
        covered[code_index] = true;

        if (entry.native_kind == .modifier) {
            const pressed = key_normalizer.normalizeModifier(
                entry.key_code,
                modifierForCode(entry.code),
                true,
            ) orelse return error.NativeMappingMissing;
            const released = key_normalizer.normalizeModifier(entry.key_code, .{}, false) orelse
                return error.NativeMappingMissing;
            if (pressed.code != entry.code or pressed.action != .press or
                released.code != entry.code or released.action != .release)
                return error.NativeMappingMismatch;
        }

        inline for ([_]vt.keyboard.Action{ .press, .repeat, .release }) |action| {
            var modifiers = modifierForCode(entry.code);
            if (action == .release) modifiers = .{};
            if (entry.native_kind == .key) {
                const normalized = key_normalizer.normalize(.{
                    .key_code = entry.key_code,
                    .modifiers = modifiers,
                    .action = action,
                }) orelse return error.NativeMappingMissing;
                if (normalized.code != entry.code or normalized.action != action)
                    return error.NativeMappingMismatch;
            }
            const event: vt.keyboard.Event = .{
                .code = entry.code,
                .modifiers = modifiers,
                .action = action,
            };
            var actual_buf: [128]u8 = undefined;
            const actual = (try vt.keyboard.encode(&actual_buf, flags, false, event)) orelse
                return error.UnexpectedSuppression;
            var expected_buf: [128]u8 = undefined;
            const expected = try expectedInventoryBytes(&expected_buf, entry, action, modifiers);
            if (!std.mem.eql(u8, actual, expected)) return error.KeyInventoryMismatch;
            var id_buf: [128]u8 = undefined;
            const id = try std.fmt.bufPrint(
                &id_buf,
                "matrix.keys.{s}.{s}",
                .{ entry.name, @tagName(action) },
            );
            try addPassedId(alloc, ids, seen, id);
        }
    }

    for (physical_inventory) |entry| {
        if (entry.key_code >= covered_key_codes.len or covered_key_codes[entry.key_code])
            return error.DuplicateNativeKeyCode;
        covered_key_codes[entry.key_code] = true;
        if (native_input.baseCodepointFromKeyCode(entry.key_code) != entry.base)
            return error.NativeMappingMismatch;
        inline for ([_]vt.keyboard.Action{ .press, .repeat, .release }) |action| {
            const normalized = key_normalizer.normalize(.{
                .key_code = entry.key_code,
                .primary = entry.base,
                .action = action,
            }) orelse return error.NativeMappingMissing;
            if (normalized.code != .codepoint or normalized.codepoint != entry.base or
                normalized.base_layout_codepoint != 0 or normalized.action != action)
                return error.NativeMappingMismatch;
            var actual_buf: [128]u8 = undefined;
            const actual = (try vt.keyboard.encode(&actual_buf, flags, false, normalized)) orelse
                return error.UnexpectedSuppression;
            var expected_buf: [128]u8 = undefined;
            const expected = switch (action) {
                .press => try std.fmt.bufPrint(&expected_buf, "\x1b[{d}u", .{entry.base}),
                .repeat => try std.fmt.bufPrint(&expected_buf, "\x1b[{d};1:2u", .{entry.base}),
                .release => try std.fmt.bufPrint(&expected_buf, "\x1b[{d};1:3u", .{entry.base}),
            };
            if (!std.mem.eql(u8, actual, expected)) return error.KeyInventoryMismatch;
            var id_buf: [128]u8 = undefined;
            const id = try std.fmt.bufPrint(
                &id_buf,
                "matrix.physical.{d:0>3}.{s}",
                .{ entry.key_code, @tagName(action) },
            );
            try addPassedId(alloc, ids, seen, id);
        }
    }

    for (0..covered_key_codes.len) |key_code| {
        const mapped = native_input.keyFromKeyCode(@intCast(key_code)) != null or
            native_input.modifierFromKeyCode(@intCast(key_code)) != null or
            native_input.baseCodepointFromKeyCode(@intCast(key_code)) != null or
            key_code == 36 or key_code == 48 or key_code == 51 or key_code == 53;
        if (mapped != covered_key_codes[key_code]) return error.IncompleteNativeKeyInventory;
    }
    inline for (std.meta.fields(vt.keyboard.Code)) |field| {
        const code: vt.keyboard.Code = @enumFromInt(field.value);
        if (code != .text and code != .codepoint and !covered[field.value])
            return error.IncompleteKeyInventory;
    }
}

fn specLegacyControlByte(char: u8) u8 {
    return switch (char) {
        'a'...'z' => char - 'a' + 1,
        'A'...'Z' => char - 'A' + 1,
        ' ' => 0,
        '2' => 0,
        '3', '[' => 0x1b,
        '4', '\\' => 0x1c,
        '5', ']' => 0x1d,
        '6', '^', '~' => 0x1e,
        '7', '/', '_' => 0x1f,
        '8', '?' => 0x7f,
        '@' => 0,
        else => char,
    };
}

fn runLegacyControlAscii(
    alloc: std.mem.Allocator,
    ids: *std.ArrayList([]const u8),
    seen: *std.StringHashMap(void),
) !void {
    var cp: u8 = 0x20;
    while (cp <= 0x7e) : (cp += 1) {
        var buf: [32]u8 = undefined;
        const actual = (try vt.keyboard.encode(&buf, .{}, false, .{
            .code = .codepoint,
            .codepoint = cp,
            .modifiers = .{ .control = true },
        })) orelse return error.UnexpectedSuppression;
        const expected = [_]u8{specLegacyControlByte(cp)};
        if (!std.mem.eql(u8, actual, &expected)) return error.LegacyControlMismatch;
        var id_buf: [64]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "matrix.legacy-control.{d:0>3}", .{cp});
        try addPassedId(alloc, ids, seen, id);
    }
}

fn legacyRecoveryEvent(name: []const u8, modifiers: vt.keyboard.Modifiers) vt.keyboard.Event {
    if (std.mem.eql(u8, name, "enter")) return .{ .code = .enter, .modifiers = modifiers };
    if (std.mem.eql(u8, name, "escape")) return .{ .code = .escape, .modifiers = modifiers };
    if (std.mem.eql(u8, name, "backspace")) return .{ .code = .backspace, .modifiers = modifiers };
    if (std.mem.eql(u8, name, "tab")) return .{ .code = .tab, .modifiers = modifiers };
    return .{ .code = .codepoint, .codepoint = ' ', .modifiers = modifiers };
}

fn expectedLegacyRecovery(
    out: []u8,
    name: []const u8,
    modifiers: vt.keyboard.Modifiers,
) ![]const u8 {
    if (std.mem.eql(u8, name, "enter")) return if (modifiers.alt) "\x1b\r" else "\r";
    if (std.mem.eql(u8, name, "escape")) return if (modifiers.alt) "\x1b\x1b" else "\x1b";
    if (std.mem.eql(u8, name, "backspace")) {
        const byte: u8 = if (modifiers.control) 0x08 else 0x7f;
        if (modifiers.alt) return std.fmt.bufPrint(out, "\x1b{c}", .{byte});
        out[0] = byte;
        return out[0..1];
    }
    if (std.mem.eql(u8, name, "tab")) {
        if (modifiers.shift) return if (modifiers.alt) "\x1b\x1b[Z" else "\x1b[Z";
        return if (modifiers.alt) "\x1b\t" else "\t";
    }
    const byte: u8 = if (modifiers.control) 0 else ' ';
    if (modifiers.alt) return std.fmt.bufPrint(out, "\x1b{c}", .{byte});
    out[0] = byte;
    return out[0..1];
}

fn runLegacyRecovery(
    alloc: std.mem.Allocator,
    ids: *std.ArrayList([]const u8),
    seen: *std.StringHashMap(void),
) !void {
    for ([_][]const u8{ "enter", "escape", "backspace", "tab", "space" }) |name| {
        for (0..8) |raw| {
            const modifiers: vt.keyboard.Modifiers = .{
                .shift = raw & 1 != 0,
                .alt = raw & 2 != 0,
                .control = raw & 4 != 0,
            };
            var actual_buf: [32]u8 = undefined;
            const actual = (try vt.keyboard.encode(
                &actual_buf,
                .{},
                false,
                legacyRecoveryEvent(name, modifiers),
            )) orelse return error.UnexpectedSuppression;
            var expected_buf: [32]u8 = undefined;
            const expected = try expectedLegacyRecovery(&expected_buf, name, modifiers);
            if (!std.mem.eql(u8, actual, expected)) return error.LegacyRecoveryMismatch;
            var id_buf: [96]u8 = undefined;
            const id = try std.fmt.bufPrint(
                &id_buf,
                "matrix.legacy-recovery.{s}.{d}",
                .{ name, raw },
            );
            try addPassedId(alloc, ids, seen, id);
        }
    }
}

fn appendRawKey(
    enc: *protocol.Encoder,
    code: u8,
    action: u8,
    modifiers: u8,
    codepoint: u32,
    shifted: u32,
    base: u32,
    text: []const u8,
) !void {
    try enc.byte(code);
    try enc.byte(action);
    try enc.byte(modifiers);
    try enc.int(u32, codepoint);
    try enc.int(u32, shifted);
    try enc.int(u32, base);
    try enc.bytes(text);
}

fn expectCodecError(bytes: []const u8, expected: anyerror) !void {
    var decoder: protocol.Decoder = .{ .bytes = bytes };
    if (protocol.decodeKeyEvent(&decoder)) |_| return error.ExpectedCodecRejection else |actual| if (actual != expected) return error.CodecErrorMismatch;
}

fn addCodecId(
    alloc: std.mem.Allocator,
    ids: *std.ArrayList([]const u8),
    seen: *std.StringHashMap(void),
    suffix: []const u8,
) !void {
    var buf: [128]u8 = undefined;
    const id = try std.fmt.bufPrint(&buf, "matrix.codec.{s}", .{suffix});
    try addPassedId(alloc, ids, seen, id);
}

fn runCodecBoundaries(
    alloc: std.mem.Allocator,
    ids: *std.ArrayList([]const u8),
    seen: *std.StringHashMap(void),
) !void {
    const max_text = try alloc.alloc(u8, vt.keyboard.max_text_bytes);
    defer alloc.free(max_text);
    @memset(max_text, 'a');
    var valid = protocol.Encoder.init(alloc);
    defer valid.deinit();
    try protocol.encodeKeyEvent(&valid, .{ .code = .text, .text = max_text });
    var valid_decoder: protocol.Decoder = .{ .bytes = valid.slice() };
    const decoded = try protocol.decodeKeyEvent(&valid_decoder);
    if (decoded.text.len != vt.keyboard.max_text_bytes) return error.CodecBoundaryMismatch;
    try addCodecId(alloc, ids, seen, "max-text-valid");

    const bad_cases = [_]struct {
        suffix: []const u8,
        code: u8,
        action: u8 = @intFromEnum(vt.keyboard.Action.press),
        modifiers: u8 = 0,
        codepoint: u32 = 0,
        shifted: u32 = 0,
        base: u32 = 0,
        text: []const u8 = "",
        expected: anyerror = error.InvalidKeyEvent,
        trailing: bool = false,
    }{
        .{ .suffix = "invalid-code", .code = 255 },
        .{ .suffix = "invalid-action", .code = @intFromEnum(vt.keyboard.Code.up), .action = 255 },
        .{ .suffix = "reserved-modifier", .code = @intFromEnum(vt.keyboard.Code.up), .modifiers = 0x40 },
        .{ .suffix = "scalar-overflow", .code = @intFromEnum(vt.keyboard.Code.codepoint), .codepoint = 0x110000 },
        .{ .suffix = "scalar-surrogate", .code = @intFromEnum(vt.keyboard.Code.codepoint), .codepoint = 0xd800 },
        .{ .suffix = "shifted-surrogate", .code = @intFromEnum(vt.keyboard.Code.codepoint), .codepoint = 'a', .shifted = 0xdfff },
        .{ .suffix = "base-surrogate", .code = @intFromEnum(vt.keyboard.Code.codepoint), .codepoint = 'a', .base = 0xd800 },
        .{ .suffix = "invalid-utf8", .code = @intFromEnum(vt.keyboard.Code.text), .text = "\xff" },
        .{ .suffix = "release-with-text", .code = @intFromEnum(vt.keyboard.Code.text), .action = @intFromEnum(vt.keyboard.Action.release), .text = "x" },
        .{ .suffix = "empty-text", .code = @intFromEnum(vt.keyboard.Code.text) },
        .{ .suffix = "zero-codepoint", .code = @intFromEnum(vt.keyboard.Code.codepoint) },
        .{ .suffix = "functional-with-scalar", .code = @intFromEnum(vt.keyboard.Code.up), .codepoint = 1 },
        .{ .suffix = "trailing-data", .code = @intFromEnum(vt.keyboard.Code.up), .expected = error.TrailingData, .trailing = true },
    };
    for (bad_cases) |bad| {
        var enc = protocol.Encoder.init(alloc);
        defer enc.deinit();
        try appendRawKey(
            &enc,
            bad.code,
            bad.action,
            bad.modifiers,
            bad.codepoint,
            bad.shifted,
            bad.base,
            bad.text,
        );
        if (bad.trailing) try enc.byte(0);
        try expectCodecError(enc.slice(), bad.expected);
        try addCodecId(alloc, ids, seen, bad.suffix);
    }

    var oversized = protocol.Encoder.init(alloc);
    defer oversized.deinit();
    try oversized.byte(@intFromEnum(vt.keyboard.Code.text));
    try oversized.byte(@intFromEnum(vt.keyboard.Action.press));
    try oversized.byte(0);
    try oversized.int(u32, 0);
    try oversized.int(u32, 0);
    try oversized.int(u32, 0);
    try oversized.int(u32, vt.keyboard.max_text_bytes + 1);
    try expectCodecError(oversized.slice(), error.InvalidKeyEvent);
    try addCodecId(alloc, ids, seen, "oversized-text");

    const oversized_text = try alloc.alloc(u8, vt.keyboard.max_text_bytes + 1);
    defer alloc.free(oversized_text);
    @memset(oversized_text, 'x');
    var encode = protocol.Encoder.init(alloc);
    defer encode.deinit();
    if (protocol.encodeKeyEvent(&encode, .{ .code = .text, .text = oversized_text }))
        return error.ExpectedCodecRejection
    else |err| if (err != error.InvalidKeyEvent)
        return error.CodecErrorMismatch;
    try addCodecId(alloc, ids, seen, "oversized-text-encode");
}

fn eventsEqual(a: vt.keyboard.Event, b: vt.keyboard.Event) bool {
    return a.code == b.code and a.codepoint == b.codepoint and
        a.shifted_codepoint == b.shifted_codepoint and
        a.base_layout_codepoint == b.base_layout_codepoint and
        a.modifiers == b.modifiers and a.action == b.action and
        std.mem.eql(u8, a.text, b.text);
}

fn verifyRatchet(
    alloc: std.mem.Allocator,
    io: std.Io,
    ids: []const []const u8,
    seen: std.StringHashMap(void),
) !void {
    const ratchet_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        ratchet_path,
        alloc,
        .limited(max_case_bytes),
    );
    defer alloc.free(ratchet_bytes);
    var ratchet: std.ArrayList([]const u8) = .empty;
    defer ratchet.deinit(alloc);
    var lines = std.mem.splitScalar(u8, ratchet_bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!stableId(line)) return error.InvalidRatchetId;
        if (ratchet.items.len != 0 and
            !std.mem.lessThan(u8, ratchet.items[ratchet.items.len - 1], line))
            return error.UnsortedOrDuplicateRatchet;
        try ratchet.append(alloc, line);
    }

    var exclusions = std.StringHashMap(void).init(alloc);
    defer exclusions.deinit();
    const exclusion_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        exclusions_path,
        alloc,
        .limited(max_case_bytes),
    );
    defer alloc.free(exclusion_bytes);
    var exclusion_lines = std.mem.splitScalar(u8, exclusion_bytes, '\n');
    while (exclusion_lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const id = fields.next() orelse return error.InvalidExclusion;
        const rfc = fields.next() orelse return error.InvalidExclusion;
        const reason = fields.next() orelse return error.InvalidExclusion;
        if (fields.next() != null or !stableId(id) or rfc.len == 0 or reason.len == 0)
            return error.InvalidExclusion;
        if (exclusions.contains(id)) return error.DuplicateExclusion;
        try exclusions.put(id, {});
    }

    for (ratchet.items) |id| if (exclusions.contains(id)) return error.RatchetExclusionOverlap;
    for (ids) |id| if (exclusions.contains(id)) return error.ExclusionUnexpectedlyPasses;
    if (ids.len != ratchet.items.len) return error.RatchetCountMismatch;
    for (ids, ratchet.items) |id, ratcheted| {
        if (!std.mem.eql(u8, id, ratcheted)) {
            if (!seen.contains(ratcheted)) return error.RatchetedCaseMissing;
            return error.PassingCaseUnlisted;
        }
    }
}

fn stableId(id: []const u8) bool {
    if (id.len == 0 or id[0] == '.' or id[id.len - 1] == '.') return false;
    var previous_dot = false;
    for (id) |char| {
        const dot = char == '.';
        if (!dot and !(char >= 'a' and char <= 'z') and
            !(char >= '0' and char <= '9') and char != '-') return false;
        if (dot and previous_dot) return false;
        previous_dot = dot;
    }
    return true;
}

fn validateHex(hex: []const u8) !void {
    if (hex.len % 2 != 0) return error.InvalidHex;
    for (hex) |char| if (!((char >= '0' and char <= '9') or
        (char >= 'a' and char <= 'f'))) return error.InvalidHex;
}

fn decodeHex(alloc: std.mem.Allocator, hex: []const u8) ![]u8 {
    try validateHex(hex);
    const bytes = try alloc.alloc(u8, hex.len / 2);
    return std.fmt.hexToBytes(bytes, hex);
}

fn validScalar(cp: u21) bool {
    return cp <= 0x10ffff and !(cp >= 0xd800 and cp <= 0xdfff);
}

fn lessThanString(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn fail(io: std.Io, comptime format: []const u8, args: anytype) !void {
    const stderr = std.Io.File.stderr();
    var buf: [2048]u8 = undefined;
    const message = try std.fmt.bufPrint(&buf, "kitty-keyboard-conformance: " ++ format ++ "\n", args);
    try stderr.writeStreamingAll(io, message);
}
