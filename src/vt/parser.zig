//! The DEC ANSI parser state machine (vt100.net/emu/dec_ansi_parser),
//! byte-driven with a UTF-8 decoder in front of ground state. Deviations
//! from the 1997 machine, per docs/references/vt-parser-state-machine.md:
//!   - UTF-8 replaces raw 8-bit C1; bytes >= 0x80 outside strings are
//!     decoded (ground) or ignored (control sequences).
//!   - ':' is a legal sub-parameter separator (SGR 38:2:..., underline 4:x).
//!   - OSC terminates on BEL as well as ST; CAN/SUB abort without dispatch.
//!
//! The parser knows no sequence semantics. It collects params and
//! intermediates and calls the Handler on dispatch; the handler is the
//! Terminal. DCS payloads are bounded and dispatched at unhook (RFC 0002).

const std = @import("std");
const utf8 = @import("utf8.zig");

pub const max_params = 32;
pub const max_intermediates = 4;
pub const max_osc_bytes = 64 * 1024;
pub const max_dcs_bytes = 4096;
pub const max_apc_bytes = 8 * 1024;
pub const OscTerminator = enum { bel, st };

const StringKind = enum { sos, pm, apc };

pub const Params = struct {
    values: [max_params]u16 = @splat(0),
    /// colon[i] == true: values[i] was attached to values[i-1] with ':'.
    colon: [max_params]bool = @splat(false),
    len: usize = 0,

    pub fn get(self: *const Params, i: usize, default: u16) u16 {
        if (i >= self.len) return default;
        const v = self.values[i];
        return if (v == 0) default else v;
    }

    /// Raw value with missing-and-zero collapsed to 0 (they are equivalent
    /// everywhere we consume params).
    pub fn raw(self: *const Params, i: usize) u16 {
        return if (i >= self.len) 0 else self.values[i];
    }
};

pub const State = enum {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    csi_ignore,
    dcs_entry,
    dcs_param,
    dcs_intermediate,
    dcs_passthrough,
    dcs_ignore,
    osc_string,
    sos_pm_apc_string,
};

/// Handler interface (comptime duck-typed):
///   print(cp: u21), execute(byte: u8),
///   csiDispatch(final: u8, intermediates: []const u8, params: *const Params),
///   escDispatch(final: u8, intermediates: []const u8),
///   oscDispatch(data: []const u8, terminator: OscTerminator),
///   dcsDispatch(final: u8, intermediates: []const u8,
///               params: *const Params, data: []const u8),
///   apcDispatch(data: []const u8)
pub fn Parser(comptime Handler: type) type {
    return struct {
        const Self = @This();

        handler: *Handler,
        state: State = .ground,
        decoder: utf8.Decoder = .{},

        params: Params = .{},
        cur: u32 = 0,
        cur_started: bool = false,
        next_is_colon: bool = false,
        params_dropped: bool = false,

        intermediates: [max_intermediates]u8 = undefined,
        intermediates_len: usize = 0,
        intermediates_overflow: bool = false,

        osc_buf: []u8,
        osc_len: usize = 0,

        dcs_buf: []u8,
        dcs_len: usize = 0,
        dcs_overflow: bool = false,
        dcs_final: u8 = 0,

        string_kind: StringKind = .sos,
        apc_buf: []u8,
        apc_len: usize = 0,
        apc_overflow: bool = false,

        pub fn init(allocator: std.mem.Allocator, handler: *Handler) !Self {
            const osc_buf = try allocator.alloc(u8, max_osc_bytes);
            errdefer allocator.free(osc_buf);
            const dcs_buf = try allocator.alloc(u8, max_dcs_bytes);
            errdefer allocator.free(dcs_buf);
            const apc_buf = try allocator.alloc(u8, max_apc_bytes);
            return .{
                .handler = handler,
                .osc_buf = osc_buf,
                .dcs_buf = dcs_buf,
                .apc_buf = apc_buf,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.apc_buf);
            allocator.free(self.dcs_buf);
            allocator.free(self.osc_buf);
        }

        pub fn feed(self: *Self, bytes: []const u8) void {
            for (bytes) |b| self.feedByte(b);
        }

        pub fn feedByte(self: *Self, byte: u8) void {
            // UTF-8 runs only against ground-state high input. Codepoints
            // out of the decoder are always >= 0x80 (multibyte or U+FFFD);
            // ASCII never enters it. A byte that aborts a pending sequence
            // is re-fed as fresh input — bounded, the decoder was reset, so
            // a retried high byte starts a new sequence instead of retrying.
            if (self.state == .ground and (self.decoder.pending() or byte >= 0x80)) {
                const r = self.decoder.feed(byte);
                if (r.cp) |cp| self.handler.print(cp);
                if (!r.retry) return;
                return self.feedByte(byte);
            }

            // Anywhere rules.
            switch (byte) {
                0x18, 0x1A => { // CAN, SUB: abort whatever is in flight.
                    self.toGround();
                    return;
                },
                0x1B => {
                    if (self.state == .osc_string) self.oscEnd(.st);
                    if (self.state == .dcs_passthrough) self.dcsEnd();
                    if (self.state == .sos_pm_apc_string and self.string_kind == .apc) self.apcEnd();
                    self.clearSeq();
                    self.state = .escape;
                    return;
                },
                else => {},
            }

            switch (self.state) {
                .ground => switch (byte) {
                    0x00...0x1F => self.handler.execute(byte),
                    0x20...0x7E => self.handler.print(byte),
                    0x7F => {}, // DEL is ignored on input display path
                    else => unreachable, // >= 0x80 handled by decoder above
                },

                .escape => switch (byte) {
                    0x00...0x17, 0x19, 0x1C...0x1F => self.handler.execute(byte),
                    0x20...0x2F => {
                        self.collect(byte);
                        self.state = .escape_intermediate;
                    },
                    0x50 => self.enter(.dcs_entry),
                    0x58, 0x5E, 0x5F => {
                        self.string_kind = switch (byte) {
                            0x58 => .sos,
                            0x5E => .pm,
                            0x5F => .apc,
                            else => unreachable,
                        };
                        self.apc_len = 0;
                        self.apc_overflow = false;
                        self.state = .sos_pm_apc_string;
                    },
                    0x5B => self.enter(.csi_entry),
                    0x5C => self.state = .ground, // ST with nothing open
                    0x5D => {
                        self.osc_len = 0;
                        self.state = .osc_string;
                    },
                    0x30...0x4F, 0x51...0x57, 0x59, 0x5A, 0x60...0x7E => {
                        self.handler.escDispatch(byte, self.intermediates[0..self.intermediates_len]);
                        self.state = .ground;
                    },
                    else => {}, // 0x7F, stray high bytes
                },

                .escape_intermediate => switch (byte) {
                    0x00...0x17, 0x19, 0x1C...0x1F => self.handler.execute(byte),
                    0x20...0x2F => self.collect(byte),
                    0x30...0x7E => {
                        if (!self.intermediates_overflow) {
                            self.handler.escDispatch(byte, self.intermediates[0..self.intermediates_len]);
                        }
                        self.state = .ground;
                    },
                    else => {},
                },

                .csi_entry => switch (byte) {
                    0x00...0x17, 0x19, 0x1C...0x1F => self.handler.execute(byte),
                    0x20...0x2F => {
                        self.collect(byte);
                        self.state = .csi_intermediate;
                    },
                    0x30...0x39, 0x3A, 0x3B => {
                        self.paramByte(byte);
                        self.state = .csi_param;
                    },
                    0x3C...0x3F => {
                        self.collect(byte);
                        self.state = .csi_param;
                    },
                    0x40...0x7E => self.csiFinal(byte),
                    else => {},
                },

                .csi_param => switch (byte) {
                    0x00...0x17, 0x19, 0x1C...0x1F => self.handler.execute(byte),
                    0x30...0x39, 0x3A, 0x3B => self.paramByte(byte),
                    0x20...0x2F => {
                        self.collect(byte);
                        self.state = .csi_intermediate;
                    },
                    0x3C...0x3F => self.state = .csi_ignore,
                    0x40...0x7E => self.csiFinal(byte),
                    else => {},
                },

                .csi_intermediate => switch (byte) {
                    0x00...0x17, 0x19, 0x1C...0x1F => self.handler.execute(byte),
                    0x20...0x2F => self.collect(byte),
                    0x30...0x3F => self.state = .csi_ignore,
                    0x40...0x7E => self.csiFinal(byte),
                    else => {},
                },

                .csi_ignore => switch (byte) {
                    0x00...0x17, 0x19, 0x1C...0x1F => self.handler.execute(byte),
                    0x40...0x7E => self.state = .ground,
                    else => {},
                },

                .dcs_entry => switch (byte) {
                    0x20...0x2F => {
                        self.collect(byte);
                        self.state = .dcs_intermediate;
                    },
                    0x30...0x39, 0x3A, 0x3B => {
                        self.paramByte(byte);
                        self.state = .dcs_param;
                    },
                    0x3C...0x3F => {
                        self.collect(byte);
                        self.state = .dcs_param;
                    },
                    0x40...0x7E => self.dcsFinal(byte),
                    else => {},
                },

                .dcs_param => switch (byte) {
                    0x30...0x39, 0x3A, 0x3B => self.paramByte(byte),
                    0x20...0x2F => {
                        self.collect(byte);
                        self.state = .dcs_intermediate;
                    },
                    0x3C...0x3F => self.state = .dcs_ignore,
                    0x40...0x7E => self.dcsFinal(byte),
                    else => {},
                },

                .dcs_intermediate => switch (byte) {
                    0x20...0x2F => self.collect(byte),
                    0x30...0x3F => self.state = .dcs_ignore,
                    0x40...0x7E => self.dcsFinal(byte),
                    else => {},
                },

                .dcs_passthrough => switch (byte) {
                    0x20...0x7E, 0x80...0xFF => {
                        if (self.dcs_len < self.dcs_buf.len) {
                            self.dcs_buf[self.dcs_len] = byte;
                            self.dcs_len += 1;
                        } else {
                            self.dcs_overflow = true;
                        }
                    },
                    else => {}, // C0 and DEL are not DCS payload bytes.
                },

                .dcs_ignore => {}, // consumed until ST/CAN/SUB/ESC

                .osc_string => switch (byte) {
                    0x07 => { // BEL terminator (xterm extension)
                        self.oscEnd(.bel);
                        self.state = .ground;
                    },
                    0x20...0x7E, 0x80...0xFF => {
                        if (self.osc_len < self.osc_buf.len) {
                            self.osc_buf[self.osc_len] = byte;
                            self.osc_len += 1;
                        }
                    },
                    else => {}, // other C0 ignored inside OSC
                },

                .sos_pm_apc_string => if (self.string_kind == .apc) {
                    // Kitty payload/control data is printable ASCII. Other C0
                    // controls are ignored inside the string.
                    if (byte >= 0x20 and byte <= 0x7e) {
                        if (self.apc_len < self.apc_buf.len) {
                            self.apc_buf[self.apc_len] = byte;
                            self.apc_len += 1;
                        } else {
                            self.apc_overflow = true;
                        }
                    }
                },
            }
        }

        fn enter(self: *Self, state: State) void {
            self.clearSeq();
            self.state = state;
        }

        fn toGround(self: *Self) void {
            self.clearSeq();
            self.state = .ground;
        }

        fn clearSeq(self: *Self) void {
            self.params = .{};
            self.cur = 0;
            self.cur_started = false;
            self.next_is_colon = false;
            self.params_dropped = false;
            self.intermediates_len = 0;
            self.intermediates_overflow = false;
            self.dcs_len = 0;
            self.dcs_overflow = false;
            self.dcs_final = 0;
            self.apc_len = 0;
            self.apc_overflow = false;
        }

        fn collect(self: *Self, byte: u8) void {
            if (self.intermediates_len >= max_intermediates) {
                self.intermediates_overflow = true;
                return;
            }
            self.intermediates[self.intermediates_len] = byte;
            self.intermediates_len += 1;
        }

        fn paramByte(self: *Self, byte: u8) void {
            switch (byte) {
                '0'...'9' => {
                    self.cur = @min(self.cur * 10 + (byte - '0'), 65535);
                    self.cur_started = true;
                },
                ';', ':' => {
                    self.pushParam();
                    self.next_is_colon = byte == ':';
                },
                else => unreachable,
            }
        }

        fn pushParam(self: *Self) void {
            if (self.params.len >= max_params) {
                self.params_dropped = true;
            } else {
                self.params.values[self.params.len] = @intCast(self.cur);
                self.params.colon[self.params.len] = self.next_is_colon;
                self.params.len += 1;
            }
            self.cur = 0;
            self.cur_started = false;
            self.next_is_colon = false;
        }

        fn csiFinal(self: *Self, final: u8) void {
            if (self.cur_started or self.params.len > 0) self.pushParam();
            if (!self.intermediates_overflow and !self.params_dropped) {
                self.handler.csiDispatch(
                    final,
                    self.intermediates[0..self.intermediates_len],
                    &self.params,
                );
            }
            self.state = .ground;
        }

        fn dcsFinal(self: *Self, final: u8) void {
            if (self.cur_started or self.params.len > 0) self.pushParam();
            if (self.intermediates_overflow or self.params_dropped) {
                self.state = .dcs_ignore;
                return;
            }
            self.dcs_final = final;
            self.dcs_len = 0;
            self.dcs_overflow = false;
            self.state = .dcs_passthrough;
        }

        fn dcsEnd(self: *Self) void {
            if (!self.dcs_overflow) {
                self.handler.dcsDispatch(
                    self.dcs_final,
                    self.intermediates[0..self.intermediates_len],
                    &self.params,
                    self.dcs_buf[0..self.dcs_len],
                );
            }
            self.dcs_len = 0;
            self.dcs_overflow = false;
        }

        fn oscEnd(self: *Self, terminator: OscTerminator) void {
            self.handler.oscDispatch(self.osc_buf[0..self.osc_len], terminator);
            self.osc_len = 0;
        }

        fn apcEnd(self: *Self) void {
            if (!self.apc_overflow) self.handler.apcDispatch(self.apc_buf[0..self.apc_len]);
            self.apc_len = 0;
            self.apc_overflow = false;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests drive the parser with a recording handler.

const Recorded = union(enum) {
    print: u21,
    execute: u8,
    csi: struct { final: u8, intermediates: [4]u8, n_intermediates: usize, params: Params },
    esc: struct { final: u8, intermediates: [4]u8, n_intermediates: usize },
    osc: [64]u8,
    dcs: struct {
        final: u8,
        intermediates: [4]u8,
        n_intermediates: usize,
        params: Params,
        data: [64]u8,
        data_len: usize,
    },
    apc: struct { data: [64]u8, data_len: usize },
};

const Recorder = struct {
    events: std.ArrayList(Recorded) = .empty,
    osc_lens: std.ArrayList(usize) = .empty,
    osc_terminators: std.ArrayList(OscTerminator) = .empty,
    alloc: std.mem.Allocator,

    fn deinit(self: *Recorder) void {
        self.events.deinit(self.alloc);
        self.osc_lens.deinit(self.alloc);
        self.osc_terminators.deinit(self.alloc);
    }

    pub fn print(self: *Recorder, cp: u21) void {
        self.events.append(self.alloc, .{ .print = cp }) catch unreachable;
    }
    pub fn execute(self: *Recorder, b: u8) void {
        self.events.append(self.alloc, .{ .execute = b }) catch unreachable;
    }
    pub fn csiDispatch(self: *Recorder, final: u8, inter: []const u8, params: *const Params) void {
        var e: Recorded = .{ .csi = .{ .final = final, .intermediates = @splat(0), .n_intermediates = inter.len, .params = params.* } };
        @memcpy(e.csi.intermediates[0..inter.len], inter);
        self.events.append(self.alloc, e) catch unreachable;
    }
    pub fn escDispatch(self: *Recorder, final: u8, inter: []const u8) void {
        var e: Recorded = .{ .esc = .{ .final = final, .intermediates = @splat(0), .n_intermediates = inter.len } };
        @memcpy(e.esc.intermediates[0..inter.len], inter);
        self.events.append(self.alloc, e) catch unreachable;
    }
    pub fn oscDispatch(self: *Recorder, data: []const u8, terminator: OscTerminator) void {
        var buf: [64]u8 = @splat(0);
        const n = @min(data.len, 64);
        @memcpy(buf[0..n], data[0..n]);
        self.events.append(self.alloc, .{ .osc = buf }) catch unreachable;
        self.osc_lens.append(self.alloc, data.len) catch unreachable;
        self.osc_terminators.append(self.alloc, terminator) catch unreachable;
    }
    pub fn dcsDispatch(self: *Recorder, final: u8, inter: []const u8, params: *const Params, data: []const u8) void {
        var e: Recorded = .{ .dcs = .{
            .final = final,
            .intermediates = @splat(0),
            .n_intermediates = inter.len,
            .params = params.*,
            .data = @splat(0),
            .data_len = @min(data.len, 64),
        } };
        @memcpy(e.dcs.intermediates[0..inter.len], inter);
        @memcpy(e.dcs.data[0..e.dcs.data_len], data[0..e.dcs.data_len]);
        self.events.append(self.alloc, e) catch unreachable;
    }
    pub fn apcDispatch(self: *Recorder, data: []const u8) void {
        var value: Recorded = .{ .apc = .{ .data = @splat(0), .data_len = @min(data.len, 64) } };
        @memcpy(value.apc.data[0..value.apc.data_len], data[0..value.apc.data_len]);
        self.events.append(self.alloc, value) catch unreachable;
    }
};

fn record(alloc: std.mem.Allocator, bytes: []const u8, chunked: bool) !Recorder {
    var rec: Recorder = .{ .alloc = alloc };
    var p = try Parser(Recorder).init(alloc, &rec);
    defer p.deinit(alloc);
    if (chunked) {
        for (bytes) |b| p.feed(&[_]u8{b});
    } else {
        p.feed(bytes);
    }
    return rec;
}

test "csi with params and prefix" {
    const alloc = std.testing.allocator;
    var rec = try record(alloc, "\x1b[?1049h", false);
    defer rec.deinit();
    try std.testing.expectEqual(@as(usize, 1), rec.events.items.len);
    const e = rec.events.items[0].csi;
    try std.testing.expectEqual(@as(u8, 'h'), e.final);
    try std.testing.expectEqual(@as(usize, 1), e.n_intermediates);
    try std.testing.expectEqual(@as(u8, '?'), e.intermediates[0]);
    try std.testing.expectEqual(@as(u16, 1049), e.params.values[0]);
}

test "empty and missing params" {
    const alloc = std.testing.allocator;
    var rec = try record(alloc, "\x1b[;5H\x1b[H", false);
    defer rec.deinit();
    const a = rec.events.items[0].csi;
    try std.testing.expectEqual(@as(usize, 2), a.params.len);
    try std.testing.expectEqual(@as(u16, 0), a.params.values[0]);
    try std.testing.expectEqual(@as(u16, 5), a.params.values[1]);
    const b = rec.events.items[1].csi;
    try std.testing.expectEqual(@as(usize, 0), b.params.len);
}

test "colon subparams" {
    const alloc = std.testing.allocator;
    var rec = try record(alloc, "\x1b[38:2:10:20:30m", false);
    defer rec.deinit();
    const e = rec.events.items[0].csi;
    try std.testing.expectEqual(@as(usize, 5), e.params.len);
    try std.testing.expectEqual(@as(u16, 38), e.params.values[0]);
    try std.testing.expect(!e.params.colon[0]);
    try std.testing.expect(e.params.colon[1]);
    try std.testing.expectEqual(@as(u16, 30), e.params.values[4]);
}

test "APC payload dispatches at ST and is chunk safe" {
    const alloc = std.testing.allocator;
    const sequence = "\x1b_Gi=4207,a=q,t=d,f=24,s=1,v=1;AAAA\x1b\\";
    var whole = try record(alloc, sequence, false);
    defer whole.deinit();
    var chunked = try record(alloc, sequence, true);
    defer chunked.deinit();
    try std.testing.expectEqual(@as(usize, 1), whole.events.items.len);
    try std.testing.expectEqual(@as(usize, 1), chunked.events.items.len);
    const a = whole.events.items[0].apc;
    const b = chunked.events.items[0].apc;
    try std.testing.expectEqualStrings("Gi=4207,a=q,t=d,f=24,s=1,v=1;AAAA", a.data[0..a.data_len]);
    try std.testing.expectEqualSlices(u8, a.data[0..a.data_len], b.data[0..b.data_len]);
}

test "C0 executes inside CSI" {
    const alloc = std.testing.allocator;
    var rec = try record(alloc, "\x1b[1\x0a2H", false);
    defer rec.deinit();
    try std.testing.expectEqual(@as(usize, 2), rec.events.items.len);
    try std.testing.expectEqual(@as(u8, 0x0a), rec.events.items[0].execute);
    const e = rec.events.items[1].csi;
    try std.testing.expectEqual(@as(u16, 12), e.params.values[0]);
}

test "cancel aborts sequence" {
    const alloc = std.testing.allocator;
    var rec = try record(alloc, "\x1b[12\x18A", false);
    defer rec.deinit();
    // CAN kills the CSI; 'A' prints.
    try std.testing.expectEqual(@as(usize, 1), rec.events.items.len);
    try std.testing.expectEqual(@as(u21, 'A'), rec.events.items[0].print);
}

test "osc bel and st terminators" {
    const alloc = std.testing.allocator;
    var rec = try record(alloc, "\x1b]0;hi\x07\x1b]2;yo\x1b\\", false);
    defer rec.deinit();
    try std.testing.expectEqual(@as(usize, 2), rec.events.items.len);
    try std.testing.expectEqualStrings("0;hi", rec.events.items[0].osc[0..4]);
    try std.testing.expectEqualStrings("2;yo", rec.events.items[1].osc[0..4]);
    try std.testing.expectEqual(OscTerminator.bel, rec.osc_terminators.items[0]);
    try std.testing.expectEqual(OscTerminator.st, rec.osc_terminators.items[1]);
}

test "DCS hook payload and unhook are chunk safe" {
    const alloc = std.testing.allocator;
    const stream = "\x1bP+q544e;436F\x1b\\";
    inline for (.{ false, true }) |chunked| {
        var rec = try record(alloc, stream, chunked);
        defer rec.deinit();
        try std.testing.expectEqual(@as(usize, 1), rec.events.items.len);
        const event = rec.events.items[0].dcs;
        try std.testing.expectEqual(@as(u8, 'q'), event.final);
        try std.testing.expectEqualStrings("+", event.intermediates[0..event.n_intermediates]);
        try std.testing.expectEqual(@as(usize, 0), event.params.len);
        try std.testing.expectEqualStrings("544e;436F", event.data[0..event.data_len]);
    }
}

test "cancelled and overflowed DCS payloads do not dispatch" {
    const alloc = std.testing.allocator;
    var rec: Recorder = .{ .alloc = alloc };
    defer rec.deinit();
    var p = try Parser(Recorder).init(alloc, &rec);
    defer p.deinit(alloc);

    p.feed("\x1bP+q544E\x18");
    try std.testing.expectEqual(@as(usize, 0), rec.events.items.len);

    p.feed("\x1bP+q");
    var remaining: usize = max_dcs_bytes + 1;
    while (remaining > 0) : (remaining -= 1) p.feed("A");
    p.feed("\x1b\\");
    try std.testing.expectEqual(@as(usize, 0), rec.events.items.len);
    try std.testing.expectEqual(State.ground, p.state);
}

test "esc dispatch with intermediate" {
    const alloc = std.testing.allocator;
    var rec = try record(alloc, "\x1b(0\x1b7", false);
    defer rec.deinit();
    const a = rec.events.items[0].esc;
    try std.testing.expectEqual(@as(u8, '0'), a.final);
    try std.testing.expectEqual(@as(u8, '('), a.intermediates[0]);
    const b = rec.events.items[1].esc;
    try std.testing.expectEqual(@as(u8, '7'), b.final);
}

test "utf8 print interleaved with sequences" {
    const alloc = std.testing.allocator;
    var rec = try record(alloc, "é\x1b[m€", false);
    defer rec.deinit();
    try std.testing.expectEqual(@as(u21, 0xE9), rec.events.items[0].print);
    try std.testing.expectEqual(@as(u8, 'm'), rec.events.items[1].csi.final);
    try std.testing.expectEqual(@as(u21, 0x20AC), rec.events.items[2].print);
}

test "esc aborts pending utf8" {
    const alloc = std.testing.allocator;
    var rec = try record(alloc, &[_]u8{ 0xE2, 0x1b, '[', 'm' }, false);
    defer rec.deinit();
    try std.testing.expectEqual(@as(u21, utf8.replacement), rec.events.items[0].print);
    try std.testing.expectEqual(@as(u8, 'm'), rec.events.items[1].csi.final);
}

test "chunked equals one-shot" {
    const alloc = std.testing.allocator;
    const stream = "\x1b[1;31mred\x1b[0m\x1b]0;tïtle\x07\x1b(B\x1b[?25l\x1b[2J\x1b[10;20Hé€\x1bP1;2|discard\x1b\\after";
    var whole = try record(alloc, stream, false);
    defer whole.deinit();
    var chunked = try record(alloc, stream, true);
    defer chunked.deinit();
    try std.testing.expectEqual(whole.events.items.len, chunked.events.items.len);
    for (whole.events.items, chunked.events.items) |a, b| {
        try std.testing.expectEqual(std.meta.activeTag(a), std.meta.activeTag(b));
    }
}

test "fuzz never crashes and always recovers" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x6e657774);
    const random = prng.random();
    var rec: Recorder = .{ .alloc = alloc };
    defer rec.deinit();
    var p = try Parser(Recorder).init(alloc, &rec);
    defer p.deinit(alloc);

    var buf: [512]u8 = undefined;
    var round: usize = 0;
    while (round < 200) : (round += 1) {
        random.bytes(&buf);
        p.feed(buf[0 .. 1 + random.uintLessThan(usize, buf.len - 1)]);
        // CAN must always return the machine to ground.
        p.feed(&[_]u8{0x18});
        try std.testing.expectEqual(State.ground, p.state);
        rec.events.clearRetainingCapacity();
        rec.osc_lens.clearRetainingCapacity();
    }
}
