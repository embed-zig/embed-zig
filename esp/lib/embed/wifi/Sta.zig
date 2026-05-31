const embed = @import("embed_core");
const esp = @import("esp");
const binding = @import("binding.zig");

const StaImpl = @This();
const Sta = embed.drivers.wifi.Sta;

hook_ctx: ?*anyopaque = null,
hook_cb: ?*const fn (?*anyopaque, Sta.Event) void = null,
last_ip_info: ?Sta.IpInfo = null,

pub fn init(self: *StaImpl) !void {
    try check("esp_embed_wifi_sta_init", binding.esp_embed_wifi_sta_init());
    binding.esp_embed_wifi_sta_set_event_handler(self, dispatchEvent);
}

pub fn handle(self: *StaImpl) Sta {
    return Sta.make(self);
}

pub fn startScan(self: *StaImpl, config: Sta.ScanConfig) Sta.ScanError!void {
    _ = self;
    const ssid = config.ssid orelse "";
    const rc = binding.esp_embed_wifi_sta_start_scan(
        @ptrCast(ssid.ptr),
        ssid.len,
        config.channel,
        config.show_hidden,
        config.active,
    );
    return switch (rc) {
        binding.esp_ok => {},
        binding.esp_invalid_state => error.Busy,
        else => error.Unexpected,
    };
}

pub fn stopScan(self: *StaImpl) void {
    _ = self;
    binding.esp_embed_wifi_sta_stop_scan();
}

pub fn connect(self: *StaImpl, config: Sta.ConnectConfig) Sta.ConnectError!void {
    _ = self;
    const rc = binding.esp_embed_wifi_sta_connect(
        @ptrCast(config.ssid.ptr),
        config.ssid.len,
        @ptrCast(config.password.ptr),
        config.password.len,
    );
    return switch (rc) {
        binding.esp_ok => {},
        binding.esp_invalid_arg => error.InvalidCredentials,
        binding.esp_invalid_state => error.Busy,
        else => error.Unexpected,
    };
}

pub fn disconnect(self: *StaImpl) void {
    _ = self;
    binding.esp_embed_wifi_sta_disconnect();
}

pub fn getState(self: *StaImpl) Sta.State {
    _ = self;
    return switch (binding.esp_embed_wifi_sta_state()) {
        binding.state_idle => .idle,
        binding.state_scanning => .scanning,
        binding.state_connecting => .connecting,
        binding.state_connected => .connected,
        else => .idle,
    };
}

pub fn setPowerSave(self: *StaImpl, mode: Sta.PowerSave) Sta.PowerSaveError!void {
    _ = self;
    const config = try powerSaveValue(mode);
    const rc = binding.esp_embed_wifi_sta_set_power_save(config.mode, config.listen_interval);
    return switch (rc) {
        binding.esp_ok => {},
        binding.esp_invalid_arg => error.InvalidConfig,
        binding.esp_invalid_state => error.Busy,
        else => error.Unexpected,
    };
}

pub fn getPowerSave(self: *StaImpl) Sta.PowerSaveError!Sta.PowerSave {
    _ = self;
    var mode: c_int = binding.power_save_default;
    var listen_interval: u16 = 0;
    const rc = binding.esp_embed_wifi_sta_get_power_save(&mode, &listen_interval);
    return switch (rc) {
        binding.esp_ok => powerSaveFromValue(mode, listen_interval) orelse error.Unexpected,
        binding.esp_invalid_arg => error.InvalidConfig,
        binding.esp_invalid_state => error.Busy,
        else => error.Unexpected,
    };
}

pub fn addEventHook(
    self: *StaImpl,
    ctx: ?*anyopaque,
    cb: *const fn (?*anyopaque, Sta.Event) void,
) void {
    esp.grt.std.log.scoped(.esp_wifi_sta).info("add event hook", .{});
    self.hook_ctx = ctx;
    self.hook_cb = cb;
}

pub fn removeEventHook(
    self: *StaImpl,
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

pub fn getMacAddr(self: *StaImpl) ?Sta.MacAddr {
    _ = self;
    return null;
}

pub fn getIpInfo(self: *StaImpl) ?Sta.IpInfo {
    return self.last_ip_info;
}

pub fn deinit(self: *StaImpl) void {
    binding.esp_embed_wifi_sta_set_event_handler(null, null);
    self.hook_ctx = null;
    self.hook_cb = null;
    self.last_ip_info = null;
}

fn check(call_name: []const u8, rc: c_int) !void {
    if (rc == binding.esp_ok) return;

    esp.grt.std.log.scoped(.esp_wifi_sta).err("{s} failed with rc={d}", .{ call_name, rc });
    return error.BoardCallFailed;
}

const PowerSaveValue = struct {
    mode: c_int,
    listen_interval: u16 = 0,
};

fn powerSaveValue(mode: Sta.PowerSave) Sta.PowerSaveError!PowerSaveValue {
    return switch (mode) {
        .none => .{ .mode = binding.power_save_none },
        .default => .{ .mode = binding.power_save_default },
        .listen_interval => |listen_interval| blk: {
            if (listen_interval == 0) return error.InvalidConfig;
            break :blk .{
                .mode = binding.power_save_listen_interval,
                .listen_interval = listen_interval,
            };
        },
    };
}

fn powerSaveFromValue(mode: c_int, listen_interval: u16) ?Sta.PowerSave {
    return switch (mode) {
        binding.power_save_none => .none,
        binding.power_save_default => .default,
        binding.power_save_listen_interval => if (listen_interval == 0) null else .{ .listen_interval = listen_interval },
        else => null,
    };
}

fn dispatchEvent(ctx: ?*anyopaque, event: *const binding.Event) callconv(.c) void {
    const self: *StaImpl = @ptrCast(@alignCast(ctx orelse return));
    const sta_event = self.makeEvent(event) orelse return;
    if (self.hook_cb) |cb| {
        esp.grt.std.log.scoped(.esp_wifi_sta).info("dispatch hook event={s}", .{@tagName(sta_event)});
        cb(self.hook_ctx, sta_event);
    } else {
        esp.grt.std.log.scoped(.esp_wifi_sta).warn("drop event without hook event={s}", .{@tagName(sta_event)});
    }
}

fn makeEvent(self: *StaImpl, event: *const binding.Event) ?Sta.Event {
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
