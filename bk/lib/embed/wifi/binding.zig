pub const ok: c_int = 0;
pub const invalid_arg: c_int = 1;
pub const invalid_state: c_int = 2;
pub const no_mem: c_int = 3;
pub const unexpected: c_int = 9;

pub const state_idle: c_int = 0;
pub const state_connecting: c_int = 1;
pub const state_connected: c_int = 2;
pub const state_scanning: c_int = 3;

pub const event_connected: c_int = 1;
pub const event_disconnected: c_int = 2;
pub const event_got_ip: c_int = 3;
pub const event_lost_ip: c_int = 4;
pub const event_scan_result: c_int = 5;

pub const security_unknown: c_int = 0;
pub const security_open: c_int = 1;
pub const security_wep: c_int = 2;
pub const security_wpa: c_int = 3;
pub const security_wpa2: c_int = 4;
pub const security_wpa3: c_int = 5;

pub const power_save_none: c_int = 0;
pub const power_save_default: c_int = 1;
pub const power_save_listen_interval: c_int = 2;

pub const Event = extern struct {
    event: c_int,
    ssid: [32]u8,
    ssid_len: usize,
    bssid: [6]u8,
    channel: u8,
    rssi: i16,
    security: c_int,
    reason: u16,
    ip: [4]u8,
    gateway: [4]u8,
    netmask: [4]u8,
    dns1: [4]u8,
};

pub const EventCallback = *const fn (ctx: ?*anyopaque, event: *const Event) callconv(.c) void;

pub extern fn bk_embed_wifi_sta_init() c_int;
pub extern fn bk_embed_wifi_sta_set_event_handler(ctx: ?*anyopaque, cb: ?EventCallback) void;
pub extern fn bk_embed_wifi_sta_start_scan(
    ssid_ptr: [*]const u8,
    ssid_len: usize,
    channel: u8,
    active: bool,
    timeout_ms: u32,
) c_int;
pub extern fn bk_embed_wifi_sta_stop_scan() void;
pub extern fn bk_embed_wifi_sta_connect(
    ssid_ptr: [*]const u8,
    ssid_len: usize,
    password_ptr: [*]const u8,
    password_len: usize,
    bssid_ptr: ?*const [6]u8,
    channel: u8,
) c_int;
pub extern fn bk_embed_wifi_sta_disconnect() void;
pub extern fn bk_embed_wifi_sta_state() c_int;
pub extern fn bk_embed_wifi_sta_set_power_save(mode: c_int, listen_interval: u16) c_int;
pub extern fn bk_embed_wifi_sta_get_power_save(mode: *c_int, listen_interval: *u16) c_int;
pub extern fn bk_embed_wifi_sta_get_mac(mac: *[6]u8) c_int;
pub extern fn bk_embed_wifi_sta_get_ip_info(ip: *[4]u8, gateway: *[4]u8, netmask: *[4]u8, dns1: *[4]u8) c_int;
