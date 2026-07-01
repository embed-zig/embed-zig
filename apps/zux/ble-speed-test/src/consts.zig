const consts = @This();

pub const service_uuid: u16 = 0xFEE0;
pub const tx_char_uuid: u16 = 0xFEE1;
pub const rx_char_uuid: u16 = 0xFEE2;

pub const target_mtu: u16 = 512;
pub const minimum_mtu: u16 = 256;
pub const default_att_mtu: u16 = 23;
pub const default_payload_len: u16 = 20;
pub const default_window_ms: u32 = 1000;
pub const att_header_len: u16 = 3;
pub const max_payload_len: u16 = target_mtu - att_header_len;

pub const Role = enum(u8) {
    client,
    server,
};

pub const Transport = enum(u8) {
    raw_gatt,
    kcp_stream,
};

pub const PacketKind = enum(u8) {
    data = 1,
    ping = 2,
    pong = 3,
};

pub const Header = packed struct {
    magic: u16 = magic_value,
    kind: u8 = @intFromEnum(PacketKind.data),
    flags: u8 = 0,
    seq: u32 = 0,
    send_time_ms: u32 = 0,
    payload_len: u16 = 0,

    pub const magic_value: u16 = 0x5A42;
    pub const encoded_len: usize = 14;
};

pub fn roleFromOption(comptime role_text: []const u8) Role {
    if (comptime eql(role_text, "client") or eql(role_text, "central")) return .client;
    if (comptime eql(role_text, "server") or eql(role_text, "periph") or eql(role_text, "peripheral")) return .server;
    @compileError("ble_speed_role must be one of: client, central, server, periph, peripheral");
}

pub fn transportFromOption(comptime transport_text: []const u8) Transport {
    if (comptime eql(transport_text, "raw-gatt") or eql(transport_text, "raw_gatt")) return .raw_gatt;
    if (comptime eql(transport_text, "kcp-stream") or eql(transport_text, "kcp_stream")) return .kcp_stream;
    @compileError("ble_speed_transport must be one of: raw-gatt, raw_gatt, kcp-stream, kcp_stream");
}

fn eql(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    inline for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
