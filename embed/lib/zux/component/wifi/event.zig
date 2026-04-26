const drivers = @import("drivers");
const Context = @import("../../event/Context.zig");

pub const max_ssid_len: usize = drivers.wifi.Wifi.max_ssid_len;
pub const MacAddr = drivers.wifi.Wifi.MacAddr;
pub const Addr = drivers.wifi.Wifi.Addr;
pub const Security = drivers.wifi.Wifi.Security;

pub const StaScanResult = struct {
    pub const kind = .wifi_sta_scan_result;

    source_id: u32,
    ssid_end: u8,
    ssid_buf: [max_ssid_len]u8,
    bssid: MacAddr,
    channel: u8,
    rssi: i16,
    security: Security,
    ctx: Context.Type = null,

    pub fn ssid(self: *const @This()) []const u8 {
        return self.ssid_buf[0..self.ssid_end];
    }
};

pub const StaConnected = struct {
    pub const kind = .wifi_sta_connected;

    source_id: u32,
    ssid_end: u8,
    ssid_buf: [max_ssid_len]u8,
    bssid: ?MacAddr,
    channel: u8,
    rssi: i16,
    security: Security,
    ctx: Context.Type = null,

    pub fn ssid(self: *const @This()) []const u8 {
        return self.ssid_buf[0..self.ssid_end];
    }
};

pub const StaDisconnected = struct {
    pub const kind = .wifi_sta_disconnected;

    source_id: u32,
    reason: u16,
    ctx: Context.Type = null,
};

pub const StaGotIp = struct {
    pub const kind = .wifi_sta_got_ip;

    source_id: u32,
    address: Addr,
    gateway: ?Addr = null,
    netmask: ?Addr = null,
    dns1: ?Addr = null,
    dns2: ?Addr = null,
    ctx: Context.Type = null,
};

pub const StaLostIp = struct {
    pub const kind = .wifi_sta_lost_ip;

    source_id: u32,
    ctx: Context.Type = null,
};

pub const ApStarted = struct {
    pub const kind = .wifi_ap_started;

    source_id: u32,
    ssid_end: u8,
    ssid_buf: [max_ssid_len]u8,
    channel: u8,
    security: Security,
    ctx: Context.Type = null,

    pub fn ssid(self: *const @This()) []const u8 {
        return self.ssid_buf[0..self.ssid_end];
    }
};

pub const ApStopped = struct {
    pub const kind = .wifi_ap_stopped;

    source_id: u32,
    ctx: Context.Type = null,
};

pub const ApClientJoined = struct {
    pub const kind = .wifi_ap_client_joined;

    source_id: u32,
    client_mac: MacAddr,
    client_ip: ?Addr = null,
    aid: u16,
    ctx: Context.Type = null,
};

pub const ApClientLeft = struct {
    pub const kind = .wifi_ap_client_left;

    source_id: u32,
    client_mac: MacAddr,
    client_ip: ?Addr = null,
    aid: u16,
    ctx: Context.Type = null,
};

pub const ApLeaseGranted = struct {
    pub const kind = .wifi_ap_lease_granted;

    source_id: u32,
    client_mac: MacAddr,
    client_ip: Addr,
    ctx: Context.Type = null,
};

pub const ApLeaseReleased = struct {
    pub const kind = .wifi_ap_lease_released;

    source_id: u32,
    client_mac: MacAddr,
    client_ip: Addr,
    ctx: Context.Type = null,
};

pub const Event = drivers.wifi.Wifi.Event;
pub const CallbackFn = drivers.wifi.Wifi.CallbackFn;

pub fn make(comptime EventType: type, source_id: u32, adapter_event: Event) !EventType {
    return switch (adapter_event) {
        .sta => |sta_event| switch (sta_event) {
            .scan_result => |report| .{
                .wifi_sta_scan_result = .{
                    .source_id = source_id,
                    .ssid_end = try copySsidLen(report.ssid),
                    .ssid_buf = try copySsidBuf(report.ssid),
                    .bssid = report.bssid,
                    .channel = report.channel,
                    .rssi = report.rssi,
                    .security = report.security,
                    .ctx = null,
                },
            },
            .connected => |info| .{
                .wifi_sta_connected = .{
                    .source_id = source_id,
                    .ssid_end = try copySsidLen(info.ssid),
                    .ssid_buf = try copySsidBuf(info.ssid),
                    .bssid = info.bssid,
                    .channel = info.channel,
                    .rssi = info.rssi,
                    .security = info.security,
                    .ctx = null,
                },
            },
            .disconnected => |info| .{
                .wifi_sta_disconnected = .{
                    .source_id = source_id,
                    .reason = info.reason,
                    .ctx = null,
                },
            },
            .got_ip => |info| .{
                .wifi_sta_got_ip = .{
                    .source_id = source_id,
                    .address = info.address,
                    .gateway = info.gateway,
                    .netmask = info.netmask,
                    .dns1 = info.dns1,
                    .dns2 = info.dns2,
                    .ctx = null,
                },
            },
            .lost_ip => .{
                .wifi_sta_lost_ip = .{
                    .source_id = source_id,
                    .ctx = null,
                },
            },
        },
        .ap => |ap_event| switch (ap_event) {
            .started => |info| .{
                .wifi_ap_started = .{
                    .source_id = source_id,
                    .ssid_end = try copySsidLen(info.ssid),
                    .ssid_buf = try copySsidBuf(info.ssid),
                    .channel = info.channel,
                    .security = info.security,
                    .ctx = null,
                },
            },
            .stopped => .{
                .wifi_ap_stopped = .{
                    .source_id = source_id,
                    .ctx = null,
                },
            },
            .client_joined => |info| .{
                .wifi_ap_client_joined = .{
                    .source_id = source_id,
                    .client_mac = info.mac,
                    .client_ip = info.ip,
                    .aid = info.aid,
                    .ctx = null,
                },
            },
            .client_left => |info| .{
                .wifi_ap_client_left = .{
                    .source_id = source_id,
                    .client_mac = info.mac,
                    .client_ip = info.ip,
                    .aid = info.aid,
                    .ctx = null,
                },
            },
            .lease_granted => |info| .{
                .wifi_ap_lease_granted = .{
                    .source_id = source_id,
                    .client_mac = info.client_mac,
                    .client_ip = info.client_ip,
                    .ctx = null,
                },
            },
            .lease_released => |info| .{
                .wifi_ap_lease_released = .{
                    .source_id = source_id,
                    .client_mac = info.client_mac,
                    .client_ip = info.client_ip,
                    .ctx = null,
                },
            },
        },
    };
}

fn copySsidLen(ssid: []const u8) !u8 {
    if (ssid.len > max_ssid_len) return error.InvalidSsidLength;
    return @intCast(ssid.len);
}

fn copySsidBuf(ssid: []const u8) ![max_ssid_len]u8 {
    if (ssid.len > max_ssid_len) return error.InvalidSsidLength;

    var buf = [_]u8{0} ** max_ssid_len;
    @memcpy(buf[0..ssid.len], ssid);
    return buf;
}
