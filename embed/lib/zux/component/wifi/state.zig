const wifi_event = @import("event.zig");
const glib = @import("glib");

pub const Sta = struct {
    pub const Status = enum {
        disconnected,
        connecting,
        connected,
        online,
    };

    source_id: u32 = 0,
    status: Status = .disconnected,
    scanning: bool = false,
    connected: bool = false,
    has_ip: bool = false,
    connected_at: glib.time.instant.Time = 0,
    connect_timeout: bool = false,
    reconnect_at: glib.time.instant.Time = 0,
    ssid_end: u8 = 0,
    ssid_buf: [wifi_event.max_ssid_len]u8 = [_]u8{0} ** wifi_event.max_ssid_len,
    bssid: ?wifi_event.MacAddr = null,
    channel: u8 = 0,
    last_rssi: ?i16 = null,
    security: wifi_event.Security = .unknown,
    address: ?wifi_event.Addr = null,
    gateway: ?wifi_event.Addr = null,
    netmask: ?wifi_event.Addr = null,
    dns1: ?wifi_event.Addr = null,
    dns2: ?wifi_event.Addr = null,
    last_disconnect_reason: ?u16 = null,

    pub fn ssid(self: *const @This()) []const u8 {
        return self.ssid_buf[0..self.ssid_end];
    }
};

pub const Ap = struct {
    source_id: u32 = 0,
    active: bool = false,
    ssid_end: u8 = 0,
    ssid_buf: [wifi_event.max_ssid_len]u8 = [_]u8{0} ** wifi_event.max_ssid_len,
    channel: u8 = 0,
    security: wifi_event.Security = .unknown,
    client_count: u16 = 0,
    last_client_mac: ?wifi_event.MacAddr = null,
    last_client_ip: ?wifi_event.Addr = null,
    last_client_aid: u16 = 0,

    pub fn ssid(self: *const @This()) []const u8 {
        return self.ssid_buf[0..self.ssid_end];
    }
};
