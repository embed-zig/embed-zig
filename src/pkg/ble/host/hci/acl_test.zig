const std = @import("std");
const testing = std.testing;
const module = @import("acl.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const PBFlag = module.PBFlag;
const BCFlag = module.BCFlag;
const AclHeader = module.AclHeader;
const HEADER_LEN = module.HEADER_LEN;
const LE_DEFAULT_DATA_LEN = module.LE_DEFAULT_DATA_LEN;
const LE_MAX_DATA_LEN = module.LE_MAX_DATA_LEN;
const MAX_PACKET_LEN = module.MAX_PACKET_LEN;
const parseHeader = module.parseHeader;
const payload = module.payload;
const encode = module.encode;
const hci = test_exports.hci;

test "parse ACL header" {
    // Handle=0x0040, PB=first_auto_flush(10), BC=point_to_point(00), len=7
    const raw = [_]u8{
        0x40, 0x20, // handle(0x0040) + pb_flag(0b10) + bc(0b00)
        0x07, 0x00, // data length: 7
        0x03, 0x00, // L2CAP length: 3
        0x04, 0x00, // L2CAP CID: 4 (ATT)
        0x02, 0x01, 0x00, // ATT data
    };

    const hdr = parseHeader(&raw) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 0x0040), hdr.conn_handle);
    try std.testing.expectEqual(PBFlag.first_auto_flush, hdr.pb_flag);
    try std.testing.expectEqual(BCFlag.point_to_point, hdr.bc_flag);
    try std.testing.expectEqual(@as(u16, 7), hdr.data_len);

    const pl = payload(&raw) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 7), pl.len);
}

test "encode ACL packet" {
    var buf: [MAX_PACKET_LEN]u8 = undefined;
    const data = [_]u8{ 0x03, 0x00, 0x04, 0x00, 0x02, 0x01, 0x00 };
    const pkt = encode(&buf, 0x0040, .first_auto_flush, &data);

    try std.testing.expectEqual(@as(usize, 5 + 7), pkt.len);
    try std.testing.expectEqual(@as(u8, 0x02), pkt[0]); // ACL indicator

    // Parse back
    const hdr = parseHeader(pkt[1..]) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 0x0040), hdr.conn_handle);
    try std.testing.expectEqual(PBFlag.first_auto_flush, hdr.pb_flag);
    try std.testing.expectEqual(@as(u16, 7), hdr.data_len);
}

test "round-trip encode/parse" {
    var buf: [MAX_PACKET_LEN]u8 = undefined;
    const original_data = "hello BLE";
    const pkt = encode(&buf, 0x0001, .first_auto_flush, original_data);

    // Skip indicator byte for parsing
    const hdr = parseHeader(pkt[1..]) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 0x0001), hdr.conn_handle);
    try std.testing.expectEqual(@as(u16, 9), hdr.data_len);

    const pl = payload(pkt[1..]) orelse unreachable;
    try std.testing.expectEqualStrings(original_data, pl);
}
