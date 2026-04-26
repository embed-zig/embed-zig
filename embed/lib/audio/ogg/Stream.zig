//! `audio/ogg/Stream.zig` owns the pure Zig rewrite of upstream
//! `ogg_stream_state` plus encode/decode page and packet flow.

const glib = @import("glib");
const Page = @import("Page.zig");
const Packet = @import("Packet.zig");

const Self = @This();

const initial_body_storage: usize = 16 * 1024;
const initial_lacing_storage: usize = 1024;
const header_storage_len: usize = 282;

const bos_lacing_flag: u16 = 0x100;
const eos_lacing_flag: u16 = 0x200;
const hole_lacing_flag: u16 = 0x400;

pub const PacketResult = union(enum) {
    none,
    hole,
    packet: Packet,
};

pub const Error = glib.std.mem.Allocator.Error || error{
    InvalidState,
    Overflow,
    SerialMismatch,
    UnsupportedVersion,
    InvalidPage,
};

allocator: ?glib.std.mem.Allocator = null,
body_data: ?[]u8 = null,
body_fill: usize = 0,
body_returned: usize = 0,

lacing_vals: ?[]u16 = null,
granule_vals: ?[]i64 = null,
lacing_fill: usize = 0,
lacing_packet: usize = 0,
lacing_returned: usize = 0,

header: [header_storage_len]u8 = [_]u8{0} ** header_storage_len,
header_fill: usize = 0,

eos_flag: bool = false,
bos_flag: bool = false,
serialno: u32 = 0,
pageno: i64 = 0,
packetno: i64 = 0,
granulepos: i64 = 0,

pub fn init(allocator: glib.std.mem.Allocator, serialno: u32) Error!Self {
    return .{
        .allocator = allocator,
        .body_data = try allocator.alloc(u8, initial_body_storage),
        .lacing_vals = try allocator.alloc(u16, initial_lacing_storage),
        .granule_vals = try allocator.alloc(i64, initial_lacing_storage),
        .serialno = serialno,
    };
}

pub fn deinit(self: *Self) void {
    if (self.body_data) |body_data| {
        self.allocator.?.free(body_data);
    }
    if (self.lacing_vals) |lacing_vals| {
        self.allocator.?.free(lacing_vals);
    }
    if (self.granule_vals) |granule_vals| {
        self.allocator.?.free(granule_vals);
    }
    self.* = .{};
}

pub fn check(self: *const Self) bool {
    return self.body_data != null and self.lacing_vals != null and self.granule_vals != null;
}

pub fn reset(self: *Self) Error!void {
    try self.ensureReady();

    self.body_fill = 0;
    self.body_returned = 0;

    self.lacing_fill = 0;
    self.lacing_packet = 0;
    self.lacing_returned = 0;

    self.header_fill = 0;

    self.eos_flag = false;
    self.bos_flag = false;
    self.pageno = -1;
    self.packetno = 0;
    self.granulepos = 0;
}

pub fn resetSerialNo(self: *Self, serialno: u32) Error!void {
    try self.reset();
    self.serialno = serialno;
}

pub fn eos(self: *const Self) bool {
    return !self.check() or self.eos_flag;
}

pub fn packetIn(self: *Self, packet: *const Packet) Error!void {
    const parts = [_][]const u8{packet.payload()};
    try self.packetInParts(parts[0..], packet.eos, packet.granulepos);
}

pub fn packetInParts(self: *Self, parts: []const []const u8, packet_eos: bool, granulepos: i64) Error!void {
    try self.ensureReady();
    self.compactReturnedBody();

    var bytes: usize = 0;
    for (parts) |part| {
        bytes = checkedAdd(bytes, part.len) orelse return error.Overflow;
    }

    const lacing_needed = checkedAdd(bytes / 255, 1) orelse return error.Overflow;

    try self.expandBody(bytes);
    try self.expandLacing(lacing_needed);

    if (bytes > 0) {
        var body_fill = self.body_fill;
        const body_data = self.body_data.?;
        for (parts) |part| {
            @memcpy(body_data[body_fill .. body_fill + part.len], part);
            body_fill += part.len;
        }
        self.body_fill = body_fill;
    }

    const lacing_vals = self.lacing_vals.?;
    const granule_vals = self.granule_vals.?;

    var i: usize = 0;
    while (i + 1 < lacing_needed) : (i += 1) {
        lacing_vals[self.lacing_fill + i] = 255;
        granule_vals[self.lacing_fill + i] = self.granulepos;
    }

    lacing_vals[self.lacing_fill + i] = @intCast(bytes % 255);
    self.granulepos = granulepos;
    granule_vals[self.lacing_fill + i] = granulepos;

    lacing_vals[self.lacing_fill] |= bos_lacing_flag;
    self.lacing_fill += lacing_needed;
    self.packetno += 1;

    if (packet_eos) self.eos_flag = true;
}

// Returned pages borrow `Stream` storage and are only valid until the next
// mutating call on the same stream.
pub fn flush(self: *Self) Error!?Page {
    return self.flushInternal(true, 4096);
}

pub fn flushFill(self: *Self, nfill: usize) Error!?Page {
    return self.flushInternal(true, nfill);
}

pub fn pageOut(self: *Self) Error!?Page {
    try self.ensureReady();

    var force = false;
    if ((self.eos_flag and self.lacing_fill > 0) or (self.lacing_fill > 0 and !self.bos_flag)) {
        force = true;
    }

    return self.flushInternal(force, 4096);
}

pub fn pageOutFill(self: *Self, nfill: usize) Error!?Page {
    try self.ensureReady();

    var force = false;
    if ((self.eos_flag and self.lacing_fill > 0) or (self.lacing_fill > 0 and !self.bos_flag)) {
        force = true;
    }

    return self.flushInternal(force, nfill);
}

pub fn pageIn(self: *Self, page: *const Page) Error!void {
    try self.ensureReady();

    const version = page.version() catch return error.InvalidPage;
    var bos = page.bos() catch return error.InvalidPage;
    const continued = page.continued() catch return error.InvalidPage;
    const page_eos = page.eos() catch return error.InvalidPage;
    const granulepos = page.granulePos() catch return error.InvalidPage;
    const serialno = page.serialNo() catch return error.InvalidPage;
    const pageno = page.pageNo() catch return error.InvalidPage;

    if (serialno != self.serialno) return error.SerialMismatch;
    if (version > 0) return error.UnsupportedVersion;

    const header = page.header;
    if (header.len < Page.minimum_header_len) return error.InvalidPage;

    const segments = @as(usize, header[26]);
    if (header.len < Page.minimum_header_len + segments) return error.InvalidPage;

    self.compactReturnedBody();
    self.compactReturnedLacing();

    try self.expandLacing(segments + 1);

    if (self.pageno != @as(i64, pageno)) {
        const lacing_vals = self.lacing_vals.?;
        var i = self.lacing_packet;
        while (i < self.lacing_fill) : (i += 1) {
            self.body_fill -= lacing_vals[i] & 0xff;
        }
        self.lacing_fill = self.lacing_packet;

        if (self.pageno != -1) {
            lacing_vals[self.lacing_fill] = hole_lacing_flag;
            self.lacing_fill += 1;
            self.lacing_packet += 1;
        }
    }

    var body_offset: usize = 0;
    var segptr: usize = 0;

    if (continued) {
        const lacing_vals = self.lacing_vals.?;
        if (self.lacing_fill < 1 or
            (lacing_vals[self.lacing_fill - 1] & 0xff) < 255 or
            lacing_vals[self.lacing_fill - 1] == hole_lacing_flag)
        {
            bos = false;
            while (segptr < segments) : (segptr += 1) {
                const val = @as(usize, header[27 + segptr]);
                body_offset = checkedAdd(body_offset, val) orelse return error.InvalidPage;
                if (body_offset > page.body.len) return error.InvalidPage;
                if (val < 255) {
                    segptr += 1;
                    break;
                }
            }
        }
    }

    const body_remaining = page.body.len - body_offset;
    if (body_remaining > 0) {
        try self.expandBody(body_remaining);
        const body_data = self.body_data.?;
        @memcpy(body_data[self.body_fill .. self.body_fill + body_remaining], page.body[body_offset..]);
        self.body_fill += body_remaining;
    }

    {
        const lacing_vals = self.lacing_vals.?;
        const granule_vals = self.granule_vals.?;

        var saved: ?usize = null;
        while (segptr < segments) : (segptr += 1) {
            const val = @as(u16, header[27 + segptr]);
            lacing_vals[self.lacing_fill] = val;
            granule_vals[self.lacing_fill] = -1;

            if (bos) {
                lacing_vals[self.lacing_fill] |= bos_lacing_flag;
                bos = false;
            }

            if (val < 255) saved = self.lacing_fill;

            self.lacing_fill += 1;
            if (val < 255) self.lacing_packet = self.lacing_fill;
        }

        if (saved) |saved_index| {
            granule_vals[saved_index] = granulepos;
        }
    }

    if (page_eos) {
        self.eos_flag = true;
        if (self.lacing_fill > 0) {
            self.lacing_vals.?[self.lacing_fill - 1] |= eos_lacing_flag;
        }
    }

    self.pageno = @as(i64, pageno) + 1;
}

pub fn packetOut(self: *Self) Error!PacketResult {
    return self.packetOutInternal(true);
}

pub fn packetPeek(self: *Self) Error!PacketResult {
    return self.packetOutInternal(false);
}

fn flushInternal(self: *Self, force_in: bool, nfill: usize) Error!?Page {
    try self.ensureReady();

    const maxvals = @min(@as(usize, 255), self.lacing_fill);
    if (maxvals == 0) return null;

    var force = force_in;
    var vals: usize = 0;
    var bytes: usize = 0;
    var acc: usize = 0;
    var granule_pos: i64 = -1;

    const lacing_vals = self.lacing_vals.?;
    const granule_vals = self.granule_vals.?;

    if (!self.bos_flag) {
        granule_pos = 0;
        while (vals < maxvals) : (vals += 1) {
            if ((lacing_vals[vals] & 0xff) < 255) {
                vals += 1;
                break;
            }
        }
    } else {
        var packets_done: usize = 0;
        var packet_just_done: usize = 0;

        while (vals < maxvals) : (vals += 1) {
            if (acc > nfill and packet_just_done >= 4) {
                force = true;
                break;
            }

            acc += lacing_vals[vals] & 0xff;
            if ((lacing_vals[vals] & 0xff) < 255) {
                granule_pos = granule_vals[vals];
                packets_done += 1;
                packet_just_done = packets_done;
            } else {
                packet_just_done = 0;
            }
        }

        if (vals == 255) force = true;
    }

    if (!force) return null;

    @memcpy(self.header[0..4], "OggS");
    self.header[4] = 0;
    self.header[5] = 0;
    if ((lacing_vals[0] & bos_lacing_flag) == 0) self.header[5] |= 0x01;
    if (!self.bos_flag) self.header[5] |= 0x02;
    if (self.eos_flag and self.lacing_fill == vals) self.header[5] |= 0x04;
    self.bos_flag = true;

    var granule_bits: u64 = @bitCast(granule_pos);
    for (6..14) |index| {
        self.header[index] = @truncate(granule_bits);
        granule_bits >>= 8;
    }

    var serialno = self.serialno;
    for (14..18) |index| {
        self.header[index] = @truncate(serialno);
        serialno >>= 8;
    }

    const current_pageno: u32 = if (self.pageno < 0)
        0
    else
        @truncate(@as(u64, @intCast(self.pageno)));
    self.pageno = @as(i64, current_pageno) + 1;
    var page_no = current_pageno;
    for (18..22) |index| {
        self.header[index] = @truncate(page_no);
        page_no >>= 8;
    }

    @memset(self.header[22..26], 0);
    self.header[26] = @intCast(vals);

    for (0..vals) |index| {
        const segment_len: u8 = @truncate(lacing_vals[index] & 0xff);
        self.header[27 + index] = segment_len;
        bytes += segment_len;
    }

    const body_start = self.body_returned;
    self.header_fill = vals + 27;

    if (self.lacing_fill > vals) {
        @memmove(lacing_vals[0 .. self.lacing_fill - vals], lacing_vals[vals..self.lacing_fill]);
        @memmove(granule_vals[0 .. self.lacing_fill - vals], granule_vals[vals..self.lacing_fill]);
    }
    self.lacing_fill -= vals;
    self.body_returned += bytes;

    var page = Page.init(
        self.header[0..self.header_fill],
        self.body_data.?[body_start .. body_start + bytes],
    );
    page.setChecksum() catch unreachable;
    return page;
}

fn packetOutInternal(self: *Self, advance: bool) Error!PacketResult {
    try self.ensureReady();

    const ptr = self.lacing_returned;
    if (self.lacing_packet <= ptr) return .none;

    const lacing_vals = self.lacing_vals.?;
    if ((lacing_vals[ptr] & hole_lacing_flag) != 0) {
        self.lacing_returned += 1;
        self.packetno += 1;
        return .hole;
    }

    var cursor = ptr;
    var size = @as(usize, lacing_vals[cursor] & 0xff);
    var bytes = size;
    var packet_eos = (lacing_vals[cursor] & eos_lacing_flag) != 0;
    const bos = (lacing_vals[cursor] & bos_lacing_flag) != 0;

    while (size == 255) {
        cursor += 1;
        const val = lacing_vals[cursor];
        size = val & 0xff;
        if ((val & eos_lacing_flag) != 0) packet_eos = true;
        bytes += size;
    }

    if (self.body_returned + bytes > self.body_fill) return error.InvalidState;

    const packet = Packet.initBorrowed(
        self.body_data.?[self.body_returned .. self.body_returned + bytes],
        .{
            .bos = bos,
            .eos = packet_eos,
            .granulepos = self.granule_vals.?[cursor],
            .packetno = self.packetno,
        },
    );

    if (advance) {
        self.body_returned += bytes;
        self.lacing_returned = cursor + 1;
        self.packetno += 1;
    }

    return .{ .packet = packet };
}

fn compactReturnedBody(self: *Self) void {
    if (self.body_returned == 0) return;

    const body_data = self.body_data.?;
    self.body_fill -= self.body_returned;
    if (self.body_fill > 0) {
        @memmove(body_data[0..self.body_fill], body_data[self.body_returned .. self.body_returned + self.body_fill]);
    }
    self.body_returned = 0;
}

fn compactReturnedLacing(self: *Self) void {
    if (self.lacing_returned == 0) return;

    const remaining = self.lacing_fill - self.lacing_returned;
    if (remaining > 0) {
        @memmove(self.lacing_vals.?[0..remaining], self.lacing_vals.?[self.lacing_returned..self.lacing_fill]);
        @memmove(self.granule_vals.?[0..remaining], self.granule_vals.?[self.lacing_returned..self.lacing_fill]);
    }

    self.lacing_fill -= self.lacing_returned;
    self.lacing_packet -= self.lacing_returned;
    self.lacing_returned = 0;
}

fn expandBody(self: *Self, needed: usize) Error!void {
    const body_data = self.body_data orelse return error.InvalidState;
    if (self.body_fill + needed < body_data.len) return;

    var new_size = checkedAdd(body_data.len, needed) orelse return error.Overflow;
    if (new_size < @as(usize, maxInt(usize)) - 1024) {
        new_size += 1024;
    }

    self.body_data = try self.allocator.?.realloc(body_data, new_size);
}

fn expandLacing(self: *Self, needed: usize) Error!void {
    const lacing_vals = self.lacing_vals orelse return error.InvalidState;
    if (self.lacing_fill + needed < lacing_vals.len) return;

    var new_size = checkedAdd(lacing_vals.len, needed) orelse return error.Overflow;
    if (new_size < @as(usize, maxInt(usize)) - 32) {
        new_size += 32;
    }

    self.lacing_vals = try self.allocator.?.realloc(lacing_vals, new_size);
    self.granule_vals = try self.allocator.?.realloc(self.granule_vals.?, new_size);
}

fn ensureReady(self: *const Self) Error!void {
    if (!self.check()) return error.InvalidState;
}

fn checkedAdd(a: usize, b: usize) ?usize {
    const result = @addWithOverflow(a, b);
    if (result[1] != 0) return null;
    return result[0];
}

fn maxInt(comptime T: type) T {
    return (@as(T, 1) << (@typeInfo(T).int.bits - 1)) - 1 + (@as(T, 1) << (@typeInfo(T).int.bits - 1));
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn testPacketInPartsProducesExpectedPage(allocator: glib.std.mem.Allocator) !void {
            var stream = try init(allocator, 0x11223344);
            defer stream.deinit();

            const parts = [_][]const u8{ "ab", "cd", "ef" };
            try stream.packetInParts(parts[0..], true, 9);

            var page = (try stream.pageOut()).?;
            try grt.std.testing.expect(try page.bos());
            try grt.std.testing.expect(try page.eos());
            try grt.std.testing.expectEqual(@as(u32, 0x11223344), try page.serialNo());
            try grt.std.testing.expectEqual(@as(u32, 0), try page.pageNo());
            try grt.std.testing.expectEqual(@as(usize, 1), try page.packetCount());
            try grt.std.testing.expectEqualSlices(u8, "abcdef", page.body);
        }

        fn testPageInRoundTripsPacketPeekAndPacketOut(allocator: glib.std.mem.Allocator) !void {
            var encoder = try init(allocator, 7);
            defer encoder.deinit();

            var decoder = try init(allocator, 7);
            defer decoder.deinit();

            const parts = [_][]const u8{ "hel", "lo", "!" };
            try encoder.packetInParts(parts[0..], false, 123);

            var page = (try encoder.pageOut()).?;
            try decoder.pageIn(&page);

            switch (try decoder.packetPeek()) {
                .packet => |packet| {
                    try grt.std.testing.expectEqualSlices(u8, "hello!", packet.payload());
                    try grt.std.testing.expect(packet.bos);
                    try grt.std.testing.expect(!packet.eos);
                    try grt.std.testing.expectEqual(@as(i64, 0), packet.granulepos);
                    try grt.std.testing.expectEqual(@as(i64, 0), packet.packetno);
                },
                else => return error.TestUnexpectedResult,
            }

            switch (try decoder.packetOut()) {
                .packet => |packet| {
                    try grt.std.testing.expectEqualSlices(u8, "hello!", packet.payload());
                    try grt.std.testing.expect(packet.bos);
                    try grt.std.testing.expectEqual(@as(i64, 0), packet.packetno);
                },
                else => return error.TestUnexpectedResult,
            }

            switch (try decoder.packetOut()) {
                .none => {},
                else => return error.TestUnexpectedResult,
            }
        }

        fn testResetSerialNoRestartsPageSequence(allocator: glib.std.mem.Allocator) !void {
            var stream = try init(allocator, 1);
            defer stream.deinit();

            const first_packet = Packet.initBorrowed("a", .{});
            try stream.packetIn(&first_packet);
            var first_page = (try stream.flush()).?;
            try grt.std.testing.expectEqual(@as(u32, 1), try first_page.serialNo());
            try grt.std.testing.expectEqual(@as(u32, 0), try first_page.pageNo());

            try stream.resetSerialNo(99);

            const second_packet = Packet.initBorrowed("b", .{});
            try stream.packetIn(&second_packet);
            var second_page = (try stream.pageOut()).?;
            try grt.std.testing.expectEqual(@as(u32, 99), try second_page.serialNo());
            try grt.std.testing.expectEqual(@as(u32, 0), try second_page.pageNo());
        }

        fn testPageInReportsPacketHoleAfterMissingPage(allocator: glib.std.mem.Allocator) !void {
            var encoder = try init(allocator, 42);
            defer encoder.deinit();

            var decoder = try init(allocator, 42);
            defer decoder.deinit();

            const packet0 = Packet.initBorrowed("zero", .{ .bos = true });
            try encoder.packetIn(&packet0);
            var page0 = (try encoder.flush()).?;
            try decoder.pageIn(&page0);

            switch (try decoder.packetOut()) {
                .packet => |packet| try grt.std.testing.expectEqualSlices(u8, "zero", packet.payload()),
                else => return error.TestUnexpectedResult,
            }

            const packet1 = Packet.initBorrowed("one", .{});
            try encoder.packetIn(&packet1);
            _ = (try encoder.flush()).?;

            const packet2 = Packet.initBorrowed("two", .{});
            try encoder.packetIn(&packet2);
            var page2 = (try encoder.flush()).?;
            try decoder.pageIn(&page2);

            switch (try decoder.packetOut()) {
                .hole => {},
                else => return error.TestUnexpectedResult,
            }
            switch (try decoder.packetOut()) {
                .packet => |packet| try grt.std.testing.expectEqualSlices(u8, "two", packet.payload()),
                else => return error.TestUnexpectedResult,
            }
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;

            TestCase.testPacketInPartsProducesExpectedPage(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testPageInRoundTripsPacketPeekAndPacketOut(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testResetSerialNoRestartsPageSequence(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testPageInReportsPacketHoleAfterMissingPage(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
