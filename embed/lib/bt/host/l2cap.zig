//! LE L2CAP (Bluetooth Core Spec Vol 3 Part A).
//!
//! BLE uses three fixed channels:
//!   CID 0x0004 — ATT
//!   CID 0x0005 — LE Signaling
//!   CID 0x0006 — SMP
//!
//! Header format: [length: u16 LE][CID: u16 LE] (4 bytes).
//!
//! Provides:
//! - Header parse/encode
//! - Reassembler: reassembles ACL fragments into complete L2CAP SDUs
//! - FragmentIterator: splits L2CAP SDUs into ACL-sized fragments

const glib = @import("glib");

const acl = @import("hci/acl.zig");

pub const HEADER_LEN: usize = 4;

pub const CID_ATT: u16 = 0x0004;
pub const CID_LE_SIGNALING: u16 = 0x0005;
pub const CID_SMP: u16 = 0x0006;

pub const Header = struct {
    length: u16,
    cid: u16,
};

pub const Sdu = struct {
    conn_handle: u16,
    cid: u16,
    data: []const u8,
};

/// Parse L2CAP header from raw payload bytes.
pub fn parseHeader(data: []const u8) ?Header {
    if (data.len < HEADER_LEN) return null;
    return .{
        .length = glib.std.mem.readInt(u16, data[0..2], .little),
        .cid = glib.std.mem.readInt(u16, data[2..4], .little),
    };
}

/// Encode L2CAP header + payload into buf. Returns the encoded slice.
pub fn encode(buf: []u8, cid: u16, payload: []const u8) []const u8 {
    const total = HEADER_LEN + payload.len;
    glib.std.debug.assert(buf.len >= total);
    glib.std.mem.writeInt(u16, buf[0..2], @truncate(payload.len), .little);
    glib.std.mem.writeInt(u16, buf[2..4], cid, .little);
    if (payload.len > 0) {
        @memcpy(buf[HEADER_LEN..][0..payload.len], payload);
    }
    return buf[0..total];
}

/// Reassembles ACL fragments into complete L2CAP SDUs.
///
/// Feed ACL headers + payloads. When a complete SDU is assembled,
/// `feed` returns it. Uses a fixed internal buffer.
pub const Reassembler = struct {
    buf: [MAX_SDU_LEN]u8 = undefined,
    pos: usize = 0,
    expected_len: usize = 0,
    conn_handle: u16 = 0,
    cid: u16 = 0,
    active: bool = false,

    pub const MAX_SDU_LEN: usize = 512 + HEADER_LEN;

    pub fn feed(self: *Reassembler, hdr: acl.Header, payload: []const u8) ?Sdu {
        switch (hdr.pb_flag) {
            .first_auto_flush, .first_non_auto => {
                if (payload.len < HEADER_LEN) return null;
                const l2cap_hdr = parseHeader(payload) orelse return null;
                const sdu_len: usize = l2cap_hdr.length;
                const first_data = payload[HEADER_LEN..];

                if (first_data.len >= sdu_len) {
                    return .{
                        .conn_handle = hdr.conn_handle,
                        .cid = l2cap_hdr.cid,
                        .data = first_data[0..sdu_len],
                    };
                }

                if (sdu_len > self.buf.len) return null;
                @memcpy(self.buf[0..first_data.len], first_data);
                self.pos = first_data.len;
                self.expected_len = sdu_len;
                self.conn_handle = hdr.conn_handle;
                self.cid = l2cap_hdr.cid;
                self.active = true;
                return null;
            },
            .continuing => {
                if (!self.active) return null;
                if (hdr.conn_handle != self.conn_handle) return null;

                const remaining = self.expected_len - self.pos;
                const copy_len = @min(payload.len, remaining);
                if (self.pos + copy_len > self.buf.len) {
                    self.active = false;
                    return null;
                }
                @memcpy(self.buf[self.pos..][0..copy_len], payload[0..copy_len]);
                self.pos += copy_len;

                if (self.pos >= self.expected_len) {
                    self.active = false;
                    return .{
                        .conn_handle = self.conn_handle,
                        .cid = self.cid,
                        .data = self.buf[0..self.expected_len],
                    };
                }
                return null;
            },
            .complete_l2cap => {
                if (payload.len < HEADER_LEN) return null;
                const l2cap_hdr = parseHeader(payload) orelse return null;
                const data = payload[HEADER_LEN..];
                const sdu_len: usize = l2cap_hdr.length;
                if (data.len < sdu_len) return null;
                return .{
                    .conn_handle = hdr.conn_handle,
                    .cid = l2cap_hdr.cid,
                    .data = data[0..sdu_len],
                };
            },
        }
    }

    pub fn reset(self: *Reassembler) void {
        self.active = false;
        self.pos = 0;
    }
};

/// Splits an L2CAP SDU into ACL-sized fragments.
pub const FragmentIterator = struct {
    buf: []u8,
    l2cap_data: []const u8,
    conn_handle: u16,
    max_data_len: u16,
    offset: usize = 0,
    first: bool = true,

    pub fn next(self: *FragmentIterator) ?[]const u8 {
        if (self.first) {
            self.first = false;
            const max_payload: usize = self.max_data_len;
            const l2cap_total = HEADER_LEN + self.l2cap_data.len;
            const first_chunk = @min(l2cap_total, max_payload);

            glib.std.mem.writeInt(u16, self.buf[0..2], @truncate(self.l2cap_data.len), .little);
            glib.std.mem.writeInt(u16, self.buf[2..4], CID_ATT, .little);
            const data_in_first = first_chunk - HEADER_LEN;
            if (data_in_first > 0) {
                @memcpy(self.buf[HEADER_LEN..][0..data_in_first], self.l2cap_data[0..data_in_first]);
            }
            self.offset = data_in_first;

            return acl.encode(
                self.buf[Reassembler.MAX_SDU_LEN..],
                self.conn_handle,
                .first_auto_flush,
                self.buf[0..first_chunk],
            );
        }

        if (self.offset >= self.l2cap_data.len) return null;

        const remaining = self.l2cap_data.len - self.offset;
        const chunk = @min(remaining, self.max_data_len);
        const out = acl.encode(
            self.buf[Reassembler.MAX_SDU_LEN..],
            self.conn_handle,
            .continuing,
            self.l2cap_data[self.offset..][0..chunk],
        );
        self.offset += chunk;
        return out;
    }
};

/// Create a FragmentIterator for an ATT payload.
pub fn fragmentIterator(buf: []u8, att_payload: []const u8, conn_handle: u16, max_data_len: u16) FragmentIterator {
    glib.std.debug.assert(buf.len >= Reassembler.MAX_SDU_LEN + acl.MAX_PACKET_LEN);
    return .{
        .buf = buf,
        .l2cap_data = att_payload,
        .conn_handle = conn_handle,
        .max_data_len = max_data_len,
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn run() !void {
            var buf: [128]u8 = undefined;
            const payload = "ATT data";
            const encoded = encode(&buf, CID_ATT, payload);

            try grt.std.testing.expectEqual(@as(usize, HEADER_LEN + payload.len), encoded.len);

            const hdr = parseHeader(encoded) orelse return error.ParseFailed;
            try grt.std.testing.expectEqual(@as(u16, payload.len), hdr.length);
            try grt.std.testing.expectEqual(CID_ATT, hdr.cid);
            try grt.std.testing.expectEqualSlices(u8, payload, encoded[HEADER_LEN..]);

            var reasm = Reassembler{};
            var l2cap_buf: [64]u8 = undefined;
            const att_data = "hello";
            const l2cap_pkt = encode(&l2cap_buf, CID_ATT, att_data);

            const sdu = reasm.feed(.{
                .conn_handle = 0x0040,
                .pb_flag = .first_auto_flush,
                .bc_flag = .point_to_point,
                .data_len = @truncate(l2cap_pkt.len),
            }, l2cap_pkt) orelse return error.ReassemblyFailed;

            try grt.std.testing.expectEqual(@as(u16, 0x0040), sdu.conn_handle);
            try grt.std.testing.expectEqual(CID_ATT, sdu.cid);
            try grt.std.testing.expectEqualSlices(u8, att_data, sdu.data);

            reasm = .{};
            const fragmented = "hello world, this is fragmented";
            var fragmented_buf: [128]u8 = undefined;
            grt.std.mem.writeInt(u16, fragmented_buf[0..2], fragmented.len, .little);
            grt.std.mem.writeInt(u16, fragmented_buf[2..4], CID_ATT, .little);
            @memcpy(fragmented_buf[4..][0..10], fragmented[0..10]);

            const r1 = reasm.feed(.{
                .conn_handle = 0x0040,
                .pb_flag = .first_auto_flush,
                .bc_flag = .point_to_point,
                .data_len = 14,
            }, fragmented_buf[0..14]);
            try grt.std.testing.expectEqual(@as(?Sdu, null), r1);

            const r2 = reasm.feed(.{
                .conn_handle = 0x0040,
                .pb_flag = .continuing,
                .bc_flag = .point_to_point,
                .data_len = @truncate(fragmented.len - 10),
            }, fragmented[10..]) orelse return error.ReassemblyFailed;

            try grt.std.testing.expectEqual(CID_ATT, r2.cid);
            try grt.std.testing.expectEqualSlices(u8, fragmented, r2.data);

            try grt.std.testing.expectEqual(@as(?Header, null), parseHeader(&.{ 0x00, 0x00 }));

            var fragment_buf: [Reassembler.MAX_SDU_LEN + acl.MAX_PACKET_LEN]u8 = undefined;
            const iter_payload = "abcdefghijklmnop";
            var it = fragmentIterator(&fragment_buf, iter_payload, 0x0040, 6);

            const first = it.next() orelse return error.MissingFirstFragment;
            try grt.std.testing.expectEqual(acl.PbFlag.first_auto_flush, (acl.parsePacketHeader(first) orelse return error.BadHeader).pb_flag);

            const second = it.next() orelse return error.MissingSecondFragment;
            const second_payload = acl.getPayload(second) orelse return error.BadSecondPayload;
            try grt.std.testing.expectEqualSlices(u8, iter_payload[2..8], second_payload);

            const third = it.next() orelse return error.MissingThirdFragment;
            const third_payload = acl.getPayload(third) orelse return error.BadThirdPayload;
            try grt.std.testing.expectEqualSlices(u8, iter_payload[8..14], third_payload);
        }
    };
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.run() catch |err| {
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
