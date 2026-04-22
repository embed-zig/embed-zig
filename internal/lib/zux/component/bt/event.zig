const bt = @import("bt");
const Context = @import("../../event/Context.zig");

pub const addr_len: usize = bt.Host.addr_len;
pub const max_name_len: usize = bt.Host.max_name_len;
pub const max_adv_data_len: usize = bt.Host.max_adv_data_len;
pub const max_notification_len: usize = bt.Central.MAX_NOTIFICATION_VALUE_LEN;

pub const PeriphAdvertisingStarted = struct {
    pub const kind = .ble_periph_advertising_started;

    source_id: u32,
    ctx: Context.Type = null,
};

pub const PeriphAdvertisingStopped = struct {
    pub const kind = .ble_periph_advertising_stopped;

    source_id: u32,
    ctx: Context.Type = null,
};

pub const CentralFound = struct {
    pub const kind = .ble_central_found;

    source_id: u32,
    peer_addr: [addr_len]u8,
    rssi: i8,
    name_end: u8,
    name_buf: [max_name_len]u8,
    adv_data_end: u8,
    adv_data_buf: [max_adv_data_len]u8,
    ctx: Context.Type = null,

    pub fn name(self: *const @This()) []const u8 {
        return self.name_buf[0..self.name_end];
    }

    pub fn advData(self: *const @This()) []const u8 {
        return self.adv_data_buf[0..self.adv_data_end];
    }
};

pub const CentralConnected = struct {
    pub const kind = .ble_central_connected;

    source_id: u32,
    conn_handle: u16,
    peer_addr: [addr_len]u8,
    peer_addr_type: bt.Central.AddrType,
    interval: u16,
    latency: u16,
    timeout: u16,
    ctx: Context.Type = null,
};

pub const CentralDisconnected = struct {
    pub const kind = .ble_central_disconnected;

    source_id: u32,
    conn_handle: u16,
    ctx: Context.Type = null,
};

pub const CentralNotification = struct {
    pub const kind = .ble_central_notification;

    source_id: u32,
    conn_handle: u16,
    attr_handle: u16,
    data_len: u16,
    data_buf: [max_notification_len]u8,
    ctx: Context.Type = null,

    pub fn payload(self: *const @This()) []const u8 {
        return self.data_buf[0..self.data_len];
    }
};

pub const PeriphConnected = struct {
    pub const kind = .ble_periph_connected;

    source_id: u32,
    conn_handle: u16,
    peer_addr: [addr_len]u8,
    peer_addr_type: bt.Peripheral.AddrType,
    interval: u16,
    latency: u16,
    timeout: u16,
    ctx: Context.Type = null,
};

pub const PeriphDisconnected = struct {
    pub const kind = .ble_periph_disconnected;

    source_id: u32,
    conn_handle: u16,
    ctx: Context.Type = null,
};

pub const PeriphMtuChanged = struct {
    pub const kind = .ble_periph_mtu_changed;

    source_id: u32,
    conn_handle: u16,
    mtu: u16,
    ctx: Context.Type = null,
};

pub const Event = bt.Host.Event;
pub const CallbackFn = bt.Host.CallbackFn;

pub fn make(comptime EventType: type, source_id: u32, host_event: Event) !EventType {
    return switch (host_event) {
        .central => |central_event| switch (central_event) {
            .device_found => |report| .{
                .ble_central_found = .{
                    .source_id = source_id,
                    .peer_addr = report.addr,
                    .rssi = report.rssi,
                    .name_end = try copyNameLen(if (report.name_len == 0) null else report.getName()),
                    .name_buf = try copyNameBuf(if (report.name_len == 0) null else report.getName()),
                    .adv_data_end = try copyAdvDataLen(if (report.data_len == 0) null else report.getData()),
                    .adv_data_buf = try copyAdvDataBuf(if (report.data_len == 0) null else report.getData()),
                    .ctx = null,
                },
            },
            .connected => |info| .{
                .ble_central_connected = .{
                    .source_id = source_id,
                    .conn_handle = info.conn_handle,
                    .peer_addr = info.peer_addr,
                    .peer_addr_type = info.peer_addr_type,
                    .interval = info.interval,
                    .latency = info.latency,
                    .timeout = info.timeout,
                    .ctx = null,
                },
            },
            .disconnected => |conn_handle| .{
                .ble_central_disconnected = .{
                    .source_id = source_id,
                    .conn_handle = conn_handle,
                    .ctx = null,
                },
            },
            .notification => |notif| .{
                .ble_central_notification = .{
                    .source_id = source_id,
                    .conn_handle = notif.conn_handle,
                    .attr_handle = notif.attr_handle,
                    .data_len = notif.len,
                    .data_buf = copyNotificationBuf(notif.payload()),
                    .ctx = null,
                },
            },
        },
        .peripheral => |peripheral_event| switch (peripheral_event) {
            .advertising_started => .{
                .ble_periph_advertising_started = .{
                    .source_id = source_id,
                    .ctx = null,
                },
            },
            .advertising_stopped => .{
                .ble_periph_advertising_stopped = .{
                    .source_id = source_id,
                    .ctx = null,
                },
            },
            .connected => |info| .{
                .ble_periph_connected = .{
                    .source_id = source_id,
                    .conn_handle = info.conn_handle,
                    .peer_addr = info.peer_addr,
                    .peer_addr_type = info.peer_addr_type,
                    .interval = info.interval,
                    .latency = info.latency,
                    .timeout = info.timeout,
                    .ctx = null,
                },
            },
            .disconnected => |conn_handle| .{
                .ble_periph_disconnected = .{
                    .source_id = source_id,
                    .conn_handle = conn_handle,
                    .ctx = null,
                },
            },
            .mtu_changed => |info| .{
                .ble_periph_mtu_changed = .{
                    .source_id = source_id,
                    .conn_handle = info.conn_handle,
                    .mtu = info.mtu,
                    .ctx = null,
                },
            },
        },
    };
}

fn copyNameLen(name: ?[]const u8) !u8 {
    const value = name orelse return 0;
    if (value.len > max_name_len) return error.InvalidPeerNameLength;
    return @intCast(value.len);
}

fn copyNameBuf(name: ?[]const u8) ![max_name_len]u8 {
    const value = name orelse return [_]u8{0} ** max_name_len;
    if (value.len > max_name_len) return error.InvalidPeerNameLength;

    var buf = [_]u8{0} ** max_name_len;
    @memcpy(buf[0..value.len], value);
    return buf;
}

fn copyAdvDataLen(data: ?[]const u8) !u8 {
    const value = data orelse return 0;
    if (value.len > max_adv_data_len) return error.InvalidAdvDataLength;
    return @intCast(value.len);
}

fn copyAdvDataBuf(data: ?[]const u8) ![max_adv_data_len]u8 {
    const value = data orelse return [_]u8{0} ** max_adv_data_len;
    if (value.len > max_adv_data_len) return error.InvalidAdvDataLength;

    var buf = [_]u8{0} ** max_adv_data_len;
    @memcpy(buf[0..value.len], value);
    return buf;
}

fn copyNotificationBuf(payload: []const u8) [max_notification_len]u8 {
    var buf = [_]u8{0} ** max_notification_len;
    @memcpy(buf[0..payload.len], payload);
    return buf;
}
