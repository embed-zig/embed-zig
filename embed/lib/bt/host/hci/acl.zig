//! ACL data packet codec (Bluetooth Core Spec Vol 4 Part E 5.4.2).
//!
//! Pure stateless codec — encode/decode ACL data packets.
//! No I/O, no Transport dependency.
//!
//! Packet format: [indicator(1)][handle+flags(2)][data_len(2)][data...]
//! Indicator byte 0x02 = ACL Data.

const glib = @import("glib");

pub const INDICATOR: u8 = 0x02;
pub const HEADER_LEN: usize = 5; // indicator(1) + handle+flags(2) + data_len(2)

pub const LE_DEFAULT_DATA_LEN: u16 = 27;
pub const LE_MAX_DATA_LEN: u16 = 251;
pub const MAX_PACKET_LEN: usize = HEADER_LEN + LE_MAX_DATA_LEN;

pub const PbFlag = enum(u2) {
    first_non_auto = 0b00,
    continuing = 0b01,
    first_auto_flush = 0b10,
    complete_l2cap = 0b11,
};

pub const BcFlag = enum(u2) {
    point_to_point = 0b00,
    active_broadcast = 0b01,
    _,
};

pub const Header = struct {
    conn_handle: u16,
    pb_flag: PbFlag,
    bc_flag: BcFlag,
    data_len: u16,
};

/// Parse ACL header from raw bytes (without indicator byte).
/// Expects at least 4 bytes.
pub fn parseHeader(raw: []const u8) ?Header {
    if (raw.len < 4) return null;
    const w0 = glib.std.mem.readInt(u16, raw[0..2], .little);
    const w1 = glib.std.mem.readInt(u16, raw[2..4], .little);
    return .{
        .conn_handle = w0 & 0x0FFF,
        .pb_flag = @enumFromInt(@as(u2, @truncate(w0 >> 12))),
        .bc_flag = @enumFromInt(@as(u2, @truncate(w0 >> 14))),
        .data_len = w1,
    };
}

/// Parse ACL header from raw bytes (with indicator byte).
pub fn parsePacketHeader(raw: []const u8) ?Header {
    if (raw.len < HEADER_LEN) return null;
    if (raw[0] != INDICATOR) return null;
    return parseHeader(raw[1..]);
}

/// Encode an ACL data packet into buf. Returns the encoded slice.
pub fn encode(buf: []u8, conn_handle: u16, pb_flag: PbFlag, payload: []const u8) []const u8 {
    const total = HEADER_LEN + payload.len;
    glib.std.debug.assert(buf.len >= total);
    glib.std.debug.assert(payload.len <= 0xFFFF);

    buf[0] = INDICATOR;
    const flags: u16 = (conn_handle & 0x0FFF) |
        (@as(u16, @intFromEnum(pb_flag)) << 12) |
        (@as(u16, @intFromEnum(BcFlag.point_to_point)) << 14);
    glib.std.mem.writeInt(u16, buf[1..3], flags, .little);
    glib.std.mem.writeInt(u16, buf[3..5], @truncate(payload.len), .little);
    if (payload.len > 0) {
        @memcpy(buf[HEADER_LEN..][0..payload.len], payload);
    }
    return buf[0..total];
}

/// Get the payload slice from a raw ACL packet (with indicator).
pub fn getPayload(raw: []const u8) ?[]const u8 {
    const hdr = parsePacketHeader(raw) orelse return null;
    const end = HEADER_LEN + hdr.data_len;
    if (raw.len < end) return null;
    return raw[HEADER_LEN..end];
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn run() !void {
            var buf: [MAX_PACKET_LEN]u8 = undefined;
            const payload = "hello BLE";
            const pkt = encode(&buf, 0x0040, .first_auto_flush, payload);

            try grt.std.testing.expectEqual(INDICATOR, pkt[0]);
            try grt.std.testing.expectEqual(@as(usize, HEADER_LEN + payload.len), pkt.len);

            const hdr = parsePacketHeader(pkt) orelse return error.ParseFailed;
            try grt.std.testing.expectEqual(@as(u16, 0x0040), hdr.conn_handle);
            try grt.std.testing.expectEqual(PbFlag.first_auto_flush, hdr.pb_flag);
            try grt.std.testing.expectEqual(BcFlag.point_to_point, hdr.bc_flag);
            try grt.std.testing.expectEqual(@as(u16, payload.len), hdr.data_len);

            const data = getPayload(pkt) orelse return error.PayloadFailed;
            try grt.std.testing.expectEqualSlices(u8, payload, data);

            var raw: [4]u8 = undefined;
            const handle_flags: u16 = 0x0040 | (@as(u16, @intFromEnum(PbFlag.continuing)) << 12);
            grt.std.mem.writeInt(u16, raw[0..2], handle_flags, .little);
            grt.std.mem.writeInt(u16, raw[2..4], 27, .little);

            const parsed = parseHeader(&raw) orelse return error.ParseFailed;
            try grt.std.testing.expectEqual(@as(u16, 0x0040), parsed.conn_handle);
            try grt.std.testing.expectEqual(PbFlag.continuing, parsed.pb_flag);
            try grt.std.testing.expectEqual(@as(u16, 27), parsed.data_len);

            try grt.std.testing.expectEqual(@as(?Header, null), parseHeader(&.{ 0x00, 0x00 }));

            var empty_buf: [HEADER_LEN]u8 = undefined;
            const empty_pkt = encode(&empty_buf, 0x0001, .first_auto_flush, &.{});
            try grt.std.testing.expectEqual(@as(usize, HEADER_LEN), empty_pkt.len);
            const empty_hdr = parsePacketHeader(empty_pkt) orelse return error.ParseFailed;
            try grt.std.testing.expectEqual(@as(u16, 0), empty_hdr.data_len);
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
