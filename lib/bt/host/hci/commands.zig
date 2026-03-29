//! HCI command encoder (Bluetooth Core Spec Vol 4 Part E).
//!
//! Pure stateless codec — writes HCI command packets into caller-provided
//! buffers, returns a slice. No I/O, no Transport dependency.
//!
//! Packet format: [indicator(1)][opcode(2)][param_len(1)][params...]
//! Indicator byte 0x01 = HCI Command.

const std = @import("std");

pub const INDICATOR: u8 = 0x01;
pub const HEADER_LEN: usize = 4; // indicator + opcode(2) + param_len(1)
pub const MAX_PARAM_LEN: usize = 255;
pub const MAX_CMD_LEN: usize = HEADER_LEN + MAX_PARAM_LEN;

// --- Opcodes (OGF << 10 | OCF) ---

// Link Control (OGF 0x01)
pub const DISCONNECT: u16 = 0x0406;
// Controller & Baseband (OGF 0x03)
pub const RESET: u16 = 0x0C03;
pub const SET_EVENT_MASK: u16 = 0x0C01;
pub const READ_LOCAL_NAME: u16 = 0x0C14;
pub const WRITE_LOCAL_NAME: u16 = 0x0C13;
// Informational (OGF 0x04)
pub const READ_BD_ADDR: u16 = 0x1009;
pub const READ_LOCAL_VERSION: u16 = 0x1001;
pub const READ_BUFFER_SIZE: u16 = 0x1005;
// LE Controller (OGF 0x08)
pub const LE_SET_EVENT_MASK: u16 = 0x2001;
pub const LE_READ_BUFFER_SIZE: u16 = 0x2002;
pub const LE_SET_RANDOM_ADDR: u16 = 0x2005;
pub const LE_SET_ADV_PARAMS: u16 = 0x2006;
pub const LE_SET_ADV_DATA: u16 = 0x2008;
pub const LE_SET_SCAN_RSP_DATA: u16 = 0x2009;
pub const LE_SET_ADV_ENABLE: u16 = 0x200A;
pub const LE_SET_SCAN_PARAMS: u16 = 0x200B;
pub const LE_SET_SCAN_ENABLE: u16 = 0x200C;
pub const LE_CREATE_CONNECTION: u16 = 0x200D;
pub const LE_CREATE_CONNECTION_CANCEL: u16 = 0x200E;
pub const LE_READ_WHITE_LIST_SIZE: u16 = 0x200F;
pub const LE_CLEAR_WHITE_LIST: u16 = 0x2010;
pub const LE_CONNECTION_UPDATE: u16 = 0x2013;
pub const LE_READ_LOCAL_P256_KEY: u16 = 0x2025;
pub const LE_SET_DATA_LENGTH: u16 = 0x2022;
pub const LE_READ_MAX_DATA_LENGTH: u16 = 0x202F;

/// Generic encoder: writes any HCI command with raw parameter bytes.
pub fn encode(buf: []u8, opcode: u16, params: []const u8) []const u8 {
    std.debug.assert(params.len <= MAX_PARAM_LEN);
    const total = HEADER_LEN + params.len;
    std.debug.assert(buf.len >= total);

    buf[0] = INDICATOR;
    buf[1] = @truncate(opcode);
    buf[2] = @truncate(opcode >> 8);
    buf[3] = @truncate(params.len);
    if (params.len > 0) {
        @memcpy(buf[HEADER_LEN..][0..params.len], params);
    }
    return buf[0..total];
}

// --- Convenience encoders ---

/// HCI_Reset (Vol 4 Part E 7.3.2)
pub fn reset(buf: []u8) []const u8 {
    return encode(buf, RESET, &.{});
}

/// HCI_Read_BD_ADDR (Vol 4 Part E 7.4.6)
pub fn readBdAddr(buf: []u8) []const u8 {
    return encode(buf, READ_BD_ADDR, &.{});
}

/// HCI_Read_Local_Version_Information (Vol 4 Part E 7.4.1)
pub fn readLocalVersion(buf: []u8) []const u8 {
    return encode(buf, READ_LOCAL_VERSION, &.{});
}

/// HCI_Read_Buffer_Size (Vol 4 Part E 7.4.5)
pub fn readBufferSize(buf: []u8) []const u8 {
    return encode(buf, READ_BUFFER_SIZE, &.{});
}

/// HCI_Set_Event_Mask (Vol 4 Part E 7.3.1)
pub fn setEventMask(buf: []u8, mask: u64) []const u8 {
    var params: [8]u8 = undefined;
    std.mem.writeInt(u64, &params, mask, .little);
    return encode(buf, SET_EVENT_MASK, &params);
}

/// HCI_LE_Set_Event_Mask (Vol 4 Part E 7.8.1)
pub fn leSetEventMask(buf: []u8, mask: u64) []const u8 {
    var params: [8]u8 = undefined;
    std.mem.writeInt(u64, &params, mask, .little);
    return encode(buf, LE_SET_EVENT_MASK, &params);
}

/// HCI_LE_Read_Buffer_Size (Vol 4 Part E 7.8.2)
pub fn leReadBufferSize(buf: []u8) []const u8 {
    return encode(buf, LE_READ_BUFFER_SIZE, &.{});
}

/// HCI_LE_Set_Random_Address (Vol 4 Part E 7.8.4)
pub fn leSetRandomAddr(buf: []u8, addr: [6]u8) []const u8 {
    return encode(buf, LE_SET_RANDOM_ADDR, &addr);
}

/// HCI_LE_Set_Advertising_Parameters (Vol 4 Part E 7.8.5)
pub fn leSetAdvParams(buf: []u8, config: AdvParams) []const u8 {
    var params: [15]u8 = undefined;
    std.mem.writeInt(u16, params[0..2], config.interval_min, .little);
    std.mem.writeInt(u16, params[2..4], config.interval_max, .little);
    params[4] = @intFromEnum(config.adv_type);
    params[5] = @intFromEnum(config.own_addr_type);
    params[6] = @intFromEnum(config.peer_addr_type);
    @memcpy(params[7..13], &config.peer_addr);
    params[13] = config.channel_map;
    params[14] = @intFromEnum(config.filter_policy);
    return encode(buf, LE_SET_ADV_PARAMS, &params);
}

/// HCI_LE_Set_Advertising_Data (Vol 4 Part E 7.8.7)
pub fn leSetAdvData(buf: []u8, data: []const u8) []const u8 {
    var params: [32]u8 = .{0} ** 32;
    const len: u8 = @intCast(@min(data.len, 31));
    params[0] = len;
    @memcpy(params[1..][0..len], data[0..len]);
    return encode(buf, LE_SET_ADV_DATA, &params);
}

/// HCI_LE_Set_Scan_Response_Data (Vol 4 Part E 7.8.8)
pub fn leSetScanRspData(buf: []u8, data: []const u8) []const u8 {
    var params: [32]u8 = .{0} ** 32;
    const len: u8 = @intCast(@min(data.len, 31));
    params[0] = len;
    @memcpy(params[1..][0..len], data[0..len]);
    return encode(buf, LE_SET_SCAN_RSP_DATA, &params);
}

/// HCI_LE_Set_Advertise_Enable (Vol 4 Part E 7.8.9)
pub fn leSetAdvEnable(buf: []u8, enabled: bool) []const u8 {
    return encode(buf, LE_SET_ADV_ENABLE, &.{@intFromBool(enabled)});
}

/// HCI_LE_Set_Scan_Parameters (Vol 4 Part E 7.8.10)
pub fn leSetScanParams(buf: []u8, config: ScanParams) []const u8 {
    var params: [7]u8 = undefined;
    params[0] = @intFromBool(config.active);
    std.mem.writeInt(u16, params[1..3], config.interval, .little);
    std.mem.writeInt(u16, params[3..5], config.window, .little);
    params[5] = @intFromEnum(config.own_addr_type);
    params[6] = @intFromEnum(config.filter_policy);
    return encode(buf, LE_SET_SCAN_PARAMS, &params);
}

/// HCI_LE_Set_Scan_Enable (Vol 4 Part E 7.8.11)
pub fn leSetScanEnable(buf: []u8, enabled: bool, filter_duplicates: bool) []const u8 {
    return encode(buf, LE_SET_SCAN_ENABLE, &.{ @intFromBool(enabled), @intFromBool(filter_duplicates) });
}

/// HCI_LE_Create_Connection (Vol 4 Part E 7.8.12)
pub fn leCreateConnection(buf: []u8, config: ConnParams) []const u8 {
    var params: [25]u8 = undefined;
    std.mem.writeInt(u16, params[0..2], config.scan_interval, .little);
    std.mem.writeInt(u16, params[2..4], config.scan_window, .little);
    params[4] = @intFromEnum(config.filter_policy);
    params[5] = @intFromEnum(config.peer_addr_type);
    @memcpy(params[6..12], &config.peer_addr);
    params[12] = @intFromEnum(config.own_addr_type);
    std.mem.writeInt(u16, params[13..15], config.conn_interval_min, .little);
    std.mem.writeInt(u16, params[15..17], config.conn_interval_max, .little);
    std.mem.writeInt(u16, params[17..19], config.max_latency, .little);
    std.mem.writeInt(u16, params[19..21], config.supervision_timeout, .little);
    std.mem.writeInt(u16, params[21..23], config.min_ce_length, .little);
    std.mem.writeInt(u16, params[23..25], config.max_ce_length, .little);
    return encode(buf, LE_CREATE_CONNECTION, &params);
}

/// HCI_LE_Create_Connection_Cancel (Vol 4 Part E 7.8.13)
pub fn leCreateConnectionCancel(buf: []u8) []const u8 {
    return encode(buf, LE_CREATE_CONNECTION_CANCEL, &.{});
}

/// HCI_Disconnect (Vol 4 Part E 7.1.6)
pub fn disconnect(buf: []u8, conn_handle: u16, reason: u8) []const u8 {
    var params: [3]u8 = undefined;
    std.mem.writeInt(u16, params[0..2], conn_handle, .little);
    params[2] = reason;
    return encode(buf, DISCONNECT, &params);
}

// --- Parameter types ---

pub const AdvType = enum(u8) {
    adv_ind = 0x00,
    adv_direct_ind_high = 0x01,
    adv_scan_ind = 0x02,
    adv_nonconn_ind = 0x03,
    adv_direct_ind_low = 0x04,
};

pub const OwnAddrType = enum(u8) {
    public = 0x00,
    random = 0x01,
    rpa_or_public = 0x02,
    rpa_or_random = 0x03,
};

pub const PeerAddrType = enum(u8) {
    public = 0x00,
    random = 0x01,
};

pub const FilterPolicy = enum(u8) {
    accept_all = 0x00,
    whitelist_only = 0x01,
    accept_all_undirected = 0x02,
    whitelist_undirected = 0x03,
};

pub const ScanFilterPolicy = enum(u8) {
    accept_all = 0x00,
    whitelist_only = 0x01,
    accept_all_undirected = 0x02,
    whitelist_undirected = 0x03,
};

pub const AdvParams = struct {
    interval_min: u16 = 0x0800,
    interval_max: u16 = 0x0800,
    adv_type: AdvType = .adv_ind,
    own_addr_type: OwnAddrType = .public,
    peer_addr_type: PeerAddrType = .public,
    peer_addr: [6]u8 = .{0} ** 6,
    channel_map: u8 = 0x07, // all 3 channels
    filter_policy: FilterPolicy = .accept_all,
};

pub const ScanParams = struct {
    active: bool = true,
    interval: u16 = 0x0010,
    window: u16 = 0x0010,
    own_addr_type: OwnAddrType = .public,
    filter_policy: ScanFilterPolicy = .accept_all,
};

pub const ConnFilterPolicy = enum(u8) {
    peer_addr = 0x00,
    whitelist = 0x01,
};

pub const ConnParams = struct {
    scan_interval: u16 = 0x0060,
    scan_window: u16 = 0x0030,
    filter_policy: ConnFilterPolicy = .peer_addr,
    peer_addr_type: PeerAddrType = .public,
    peer_addr: [6]u8 = .{0} ** 6,
    own_addr_type: OwnAddrType = .public,
    conn_interval_min: u16 = 0x0018,
    conn_interval_max: u16 = 0x0028,
    max_latency: u16 = 0,
    supervision_timeout: u16 = 0x00C8,
    min_ce_length: u16 = 0,
    max_ce_length: u16 = 0,
};

// --- Tests ---

test "bt/unit_tests/host/hci/commands/reset" {
    var buf: [MAX_CMD_LEN]u8 = undefined;
    const pkt = reset(&buf);
    try std.testing.expectEqual(@as(usize, 4), pkt.len);
    try std.testing.expectEqual(INDICATOR, pkt[0]);
    try std.testing.expectEqual(@as(u8, 0x03), pkt[1]); // OCF low
    try std.testing.expectEqual(@as(u8, 0x0C), pkt[2]); // OGF high
    try std.testing.expectEqual(@as(u8, 0), pkt[3]); // param len
}

test "bt/unit_tests/host/hci/commands/leSetAdvEnable" {
    var buf: [MAX_CMD_LEN]u8 = undefined;
    const pkt = leSetAdvEnable(&buf, true);
    try std.testing.expectEqual(@as(usize, 5), pkt.len);
    try std.testing.expectEqual(INDICATOR, pkt[0]);
    try std.testing.expectEqual(@as(u8, 0x0A), pkt[1]);
    try std.testing.expectEqual(@as(u8, 0x20), pkt[2]);
    try std.testing.expectEqual(@as(u8, 1), pkt[3]); // param len
    try std.testing.expectEqual(@as(u8, 1), pkt[4]); // enable=true
}

test "bt/unit_tests/host/hci/commands/leSetScanEnable" {
    var buf: [MAX_CMD_LEN]u8 = undefined;
    const pkt = leSetScanEnable(&buf, true, false);
    try std.testing.expectEqual(@as(usize, 6), pkt.len);
    try std.testing.expectEqual(@as(u8, 1), pkt[4]); // enable
    try std.testing.expectEqual(@as(u8, 0), pkt[5]); // no filter dup
}

test "bt/unit_tests/host/hci/commands/disconnect" {
    var buf: [MAX_CMD_LEN]u8 = undefined;
    const pkt = disconnect(&buf, 0x0040, 0x13);
    try std.testing.expectEqual(@as(usize, 7), pkt.len);
    try std.testing.expectEqual(@as(u8, 0x40), pkt[4]); // handle low
    try std.testing.expectEqual(@as(u8, 0x00), pkt[5]); // handle high
    try std.testing.expectEqual(@as(u8, 0x13), pkt[6]); // reason
}

test "bt/unit_tests/host/hci/commands/generic_encode" {
    var buf: [MAX_CMD_LEN]u8 = undefined;
    const pkt = encode(&buf, READ_BD_ADDR, &.{});
    try std.testing.expectEqual(@as(usize, 4), pkt.len);
    try std.testing.expectEqual(@as(u8, 0x09), pkt[1]);
    try std.testing.expectEqual(@as(u8, 0x10), pkt[2]);
}
