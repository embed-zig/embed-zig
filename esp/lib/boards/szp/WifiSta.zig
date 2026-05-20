const embed = @import("embed_core");
const esp = @import("esp");
const binding = @import("bindings/common.zig");

const WifiSta = @This();
const Sta = embed.drivers.wifi.Sta;

hook_ctx: ?*anyopaque = null,
hook_cb: ?*const fn (?*anyopaque, Sta.Event) void = null,
last_ip_info: ?Sta.IpInfo = null,

pub fn init(self: *WifiSta) !void {
    try check("szp_wifi_sta_init", binding.szp_wifi_sta_init());
    binding.szp_wifi_sta_set_event_handler(self, dispatchEvent);
}

pub fn handle(self: *WifiSta) Sta {
    return Sta.make(self);
}

pub fn startScan(self: *WifiSta, config: Sta.ScanConfig) Sta.ScanError!void {
    _ = self;
    const ssid = config.ssid orelse "";
    const rc = binding.szp_wifi_sta_start_scan(
        @ptrCast(ssid.ptr),
        ssid.len,
        config.channel,
        config.show_hidden,
        config.active,
    );
    return switch (rc) {
        binding.esp_ok => {},
        else => error.Unexpected,
    };
}

pub fn stopScan(self: *WifiSta) void {
    _ = self;
    binding.szp_wifi_sta_stop_scan();
}

pub fn connect(self: *WifiSta, config: Sta.ConnectConfig) Sta.ConnectError!void {
    _ = self;
    const timeout_ms = durationMillis(config.timeout);
    const rc = binding.szp_wifi_sta_connect_blocking(
        @ptrCast(config.ssid.ptr),
        config.ssid.len,
        @ptrCast(config.password.ptr),
        config.password.len,
        timeout_ms,
    );
    return switch (rc) {
        binding.connect_success => {},
        binding.connect_timeout => error.Timeout,
        binding.connect_invalid_config => error.InvalidCredentials,
        else => error.Unexpected,
    };
}

pub fn disconnect(self: *WifiSta) void {
    _ = self;
    binding.szp_wifi_sta_disconnect();
}

pub fn getState(self: *WifiSta) Sta.State {
    _ = self;
    return switch (binding.szp_wifi_sta_state()) {
        binding.state_idle => .idle,
        binding.state_scanning => .scanning,
        binding.state_connecting => .connecting,
        binding.state_connected => .connected,
        else => .idle,
    };
}

pub fn addEventHook(
    self: *WifiSta,
    ctx: ?*anyopaque,
    cb: *const fn (?*anyopaque, Sta.Event) void,
) void {
    self.hook_ctx = ctx;
    self.hook_cb = cb;
}

pub fn removeEventHook(
    self: *WifiSta,
    ctx: ?*anyopaque,
    cb: *const fn (?*anyopaque, Sta.Event) void,
) void {
    if (self.hook_ctx == ctx) {
        if (self.hook_cb) |hook_cb| {
            if (hook_cb == cb) {
                self.hook_ctx = null;
                self.hook_cb = null;
            }
        }
    }
}

pub fn getMacAddr(self: *WifiSta) ?Sta.MacAddr {
    _ = self;
    return null;
}

pub fn getIpInfo(self: *WifiSta) ?Sta.IpInfo {
    return self.last_ip_info;
}

pub fn deinit(self: *WifiSta) void {
    binding.szp_wifi_sta_set_event_handler(null, null);
    self.hook_ctx = null;
    self.hook_cb = null;
    self.last_ip_info = null;
}

fn durationMillis(duration: esp.grt.time.duration.Duration) u32 {
    if (duration == 0) return 15_000;
    const millis = @divTrunc(duration, esp.grt.time.duration.MilliSecond);
    if (millis > esp.grt.std.math.maxInt(u32)) return esp.grt.std.math.maxInt(u32);
    return @intCast(millis);
}

fn check(call_name: []const u8, rc: c_int) !void {
    if (rc == binding.esp_ok) return;

    esp.grt.std.log.scoped(.szp_wifi_sta).err("{s} failed with rc={d}", .{ call_name, rc });
    return error.BoardCallFailed;
}

fn dispatchEvent(ctx: ?*anyopaque, event: *const binding.Event) callconv(.c) void {
    const self: *WifiSta = @ptrCast(@alignCast(ctx orelse return));
    const sta_event = self.makeEvent(event.*) orelse return;
    if (self.hook_cb) |cb| {
        cb(self.hook_ctx, sta_event);
    }
}

fn makeEvent(self: *WifiSta, event: binding.Event) ?Sta.Event {
    return switch (event.event) {
        binding.event_scan_result => .{ .scan_result = .{
            .ssid = event.ssid[0..@min(event.ssid_len, event.ssid.len)],
            .bssid = event.bssid,
            .channel = event.channel,
            .rssi = event.rssi,
            .security = mapSecurity(event.security),
        } },
        binding.event_connected => .{ .connected = .{
            .ssid = event.ssid[0..@min(event.ssid_len, event.ssid.len)],
            .bssid = event.bssid,
            .channel = event.channel,
            .rssi = event.rssi,
            .security = mapSecurity(event.security),
        } },
        binding.event_disconnected => blk: {
            self.last_ip_info = null;
            break :blk .{ .disconnected = .{ .reason = event.reason } };
        },
        binding.event_got_ip => blk: {
            const ip_info = Sta.IpInfo{
                .address = Sta.Addr.from4(event.ip),
                .gateway = Sta.Addr.from4(event.gateway),
                .netmask = Sta.Addr.from4(event.netmask),
            };
            self.last_ip_info = ip_info;
            break :blk .{ .got_ip = ip_info };
        },
        binding.event_lost_ip => blk: {
            self.last_ip_info = null;
            break :blk .{ .lost_ip = {} };
        },
        else => null,
    };
}

fn mapSecurity(security: c_int) Sta.Security {
    return switch (security) {
        binding.security_open => .open,
        binding.security_wep => .wep,
        binding.security_wpa => .wpa,
        binding.security_wpa2 => .wpa2,
        binding.security_wpa3 => .wpa3,
        else => .unknown,
    };
}
