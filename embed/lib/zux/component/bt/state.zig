const glib = @import("glib");
const bt = @import("bt");
const bt_event = @import("event.zig");

pub const Central = struct {
    source_id: u32 = 0,
    connected: bool = false,
    conn_handle: ?u16 = null,
    peer_addr: ?[bt_event.addr_len]u8 = null,
    peer_addr_type: ?bt.Central.AddrType = null,
    interval: u16 = 0,
    latency: u16 = 0,
    supervision_timeout: glib.time.duration.Duration = 0,
    last_rssi: ?i8 = null,
    name_end: u8 = 0,
    name_buf: [bt_event.max_name_len]u8 = [_]u8{0} ** bt_event.max_name_len,
    adv_data_end: u8 = 0,
    adv_data_buf: [bt_event.max_adv_data_len]u8 = [_]u8{0} ** bt_event.max_adv_data_len,
    last_notification_attr_handle: ?u16 = null,
    last_notification_len: u16 = 0,
    last_notification_buf: [bt_event.max_notification_len]u8 = [_]u8{0} ** bt_event.max_notification_len,

    pub fn name(self: *const @This()) []const u8 {
        return self.name_buf[0..self.name_end];
    }

    pub fn advData(self: *const @This()) []const u8 {
        return self.adv_data_buf[0..self.adv_data_end];
    }

    pub fn lastNotification(self: *const @This()) []const u8 {
        return self.last_notification_buf[0..self.last_notification_len];
    }
};

pub const Periph = struct {
    source_id: u32 = 0,
    advertising: bool = false,
    connected_count: u16 = 0,
    last_connected_conn_handle: ?u16 = null,
    last_disconnected_conn_handle: ?u16 = null,
    last_peer_addr: ?[bt_event.addr_len]u8 = null,
    last_peer_addr_type: ?bt.Peripheral.AddrType = null,
    last_interval: u16 = 0,
    last_latency: u16 = 0,
    last_supervision_timeout: glib.time.duration.Duration = 0,
    last_mtu_conn_handle: ?u16 = null,
    last_mtu: ?u16 = null,

    pub fn connected(self: *const @This()) bool {
        return self.connected_count > 0;
    }
};
