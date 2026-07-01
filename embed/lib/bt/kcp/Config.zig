const glib = @import("glib");

pub const Config = @This();

pub const DEFAULT_SERVICE_UUID: u16 = 0xFEE0;
pub const DEFAULT_CONV: u32 = 0x42544B43;
pub const DEFAULT_SEND_WINDOW: i32 = 32;
pub const DEFAULT_RECV_WINDOW: i32 = 32;
pub const DEFAULT_NODELAY: i32 = 1;
pub const DEFAULT_INTERVAL_MS: i32 = 10;
pub const DEFAULT_RESEND: i32 = 2;
pub const DEFAULT_NO_CONGESTION_CONTROL: i32 = 1;
pub const DEFAULT_CHANNEL_CAPACITY: usize = 16;
pub const DEFAULT_MAX_DATAGRAM_LEN: usize = 512;
pub const MIN_KCP_MTU: usize = 50;
pub const KCP_OVERHEAD: usize = 24;
pub const ATT_HEADER_LEN: usize = 3;

service_uuid: u16 = DEFAULT_SERVICE_UUID,
tx_char_uuid: u16,
rx_char_uuid: u16,
conv: u32 = DEFAULT_CONV,
att_mtu: u16 = 23,
send_window: i32 = DEFAULT_SEND_WINDOW,
recv_window: i32 = DEFAULT_RECV_WINDOW,
nodelay: i32 = DEFAULT_NODELAY,
interval_ms: i32 = DEFAULT_INTERVAL_MS,
resend: i32 = DEFAULT_RESEND,
no_congestion_control: i32 = DEFAULT_NO_CONGESTION_CONTROL,
channel_capacity: usize = DEFAULT_CHANNEL_CAPACITY,
max_datagram_len: usize = DEFAULT_MAX_DATAGRAM_LEN,
task_options: glib.task.Options = .{ .min_stack_size = 6 * 1024 },

pub fn attPayloadLen(self: Config) usize {
    if (self.att_mtu <= ATT_HEADER_LEN) return 1;
    return @intCast(self.att_mtu - ATT_HEADER_LEN);
}

pub fn kcpMtu(self: Config) usize {
    return @min(self.attPayloadLen(), self.max_datagram_len);
}

pub fn maxWriteChunkLen(self: Config) usize {
    const mtu = self.kcpMtu();
    if (mtu <= KCP_OVERHEAD) return 1;
    return mtu - KCP_OVERHEAD;
}
