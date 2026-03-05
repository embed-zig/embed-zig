const std = @import("std");
const esp = @import("esp");
const hal_wifi = @import("hal").wifi;

const EspWiFi = esp.esp_wifi.WiFi;

const max_pending_scan: usize = 16;

pub const Driver = struct {
    wifi: EspWiFi,
    connected: bool = false,
    ap_running: bool = false,
    current_ssid: [32]u8 = [_]u8{0} ** 32,
    current_ssid_len: u8 = 0,
    current_channel: ?u8 = null,
    tx_power: ?i8 = null,
    country_code: [2]u8 = "01".*,
    power_save: hal_wifi.PowerSaveMode = .none,
    roaming_cfg: hal_wifi.RoamingConfig = .{},
    rssi_threshold: i8 = -127,
    pending_event: ?hal_wifi.WifiEvent = null,
    scan_results: [max_pending_scan]hal_wifi.ApInfo = undefined,
    scan_count: usize = 0,
    scan_index: usize = 0,

    pub fn init() hal_wifi.Error!Driver {
        const wifi = EspWiFi.init() catch |err| return mapInitError(err);
        return .{ .wifi = wifi };
    }

    pub fn deinit(self: *Driver) void {
        self.wifi.deinit() catch {};
    }

    pub fn connect(self: *Driver, ssid: []const u8, password: []const u8) void {
        self.connectWithConfig(.{
            .ssid = ssid,
            .password = password,
        });
    }

    pub fn connectWithConfig(self: *Driver, cfg: hal_wifi.ConnectConfig) void {
        self.connected = false;
        self.ap_running = false;
        self.current_channel = if (cfg.channel_hint == 0) null else cfg.channel_hint;
        setSsid(self, cfg.ssid);

        self.wifi.startSta(.{
            .ssid = cfg.ssid,
            .password = cfg.password,
        }) catch {
            self.pending_event = .{ .connection_failed = .unknown };
            return;
        };
        self.wifi.connectSta() catch {
            self.pending_event = .{ .connection_failed = .unknown };
            return;
        };

        // Note: espz WiFi wrapper currently does not expose event callbacks.
        // We emit optimistic connected event after successful start/connect calls.
        self.connected = true;
        self.pending_event = .{ .connected = {} };
    }

    pub fn reconnect(self: *Driver) void {
        if (self.current_ssid_len == 0) return;
        self.wifi.connectSta() catch return;
        self.connected = true;
        self.pending_event = .{ .connected = {} };
    }

    pub fn disconnect(self: *Driver) void {
        self.wifi.disconnectSta() catch {};
        self.connected = false;
        self.pending_event = .{ .disconnected = .user_request };
    }

    pub fn isConnected(self: *const Driver) bool {
        return self.connected;
    }

    pub fn pollEvent(self: *Driver) ?hal_wifi.WifiEvent {
        if (self.pending_event) |ev| {
            self.pending_event = null;
            return ev;
        }

        if (self.scan_index < self.scan_count) {
            const idx = self.scan_index;
            self.scan_index += 1;
            return .{ .scan_result = self.scan_results[idx] };
        }

        if (self.scan_count != 0 and self.scan_index == self.scan_count) {
            self.scan_count = 0;
            self.scan_index = 0;
            return .{ .scan_done = .{ .success = true } };
        }

        return null;
    }

    pub fn getRssi(_: *const Driver) ?i8 {
        return null;
    }

    pub fn getMac(self: *const Driver) ?hal_wifi.Mac {
        var copy = self.*;
        return copy.wifi.getStaMac() catch null;
    }

    pub fn getChannel(self: *const Driver) ?u8 {
        return self.current_channel;
    }

    pub fn getSsid(self: *const Driver) ?[]const u8 {
        if (self.current_ssid_len == 0) return null;
        return self.current_ssid[0..self.current_ssid_len];
    }

    pub fn getBssid(_: *const Driver) ?hal_wifi.Mac {
        return null;
    }

    pub fn getPhyMode(_: *const Driver) ?hal_wifi.PhyMode {
        return null;
    }

    pub fn scanStart(self: *Driver, cfg: hal_wifi.ScanConfig) hal_wifi.Error!void {
        self.scan_count = 0;
        self.scan_index = 0;

        const records = self.wifi.scan(.{
            .channel = cfg.channel,
            .show_hidden = cfg.show_hidden,
            .block_until_done = true,
            .max_results = max_pending_scan,
        }, std.heap.c_allocator) catch |err| return mapOpError(err);
        defer std.heap.c_allocator.free(records);

        const n = @min(records.len, self.scan_results.len);
        for (records[0..n], 0..) |rec, idx| {
            var ssid_len: usize = 0;
            while (ssid_len < rec.ssid.len and rec.ssid[ssid_len] != 0) : (ssid_len += 1) {}

            var out: hal_wifi.ApInfo = .{
                .ssid = [_]u8{0} ** 32,
                .ssid_len = @intCast(ssid_len),
                .bssid = [_]u8{0} ** 6,
                .channel = rec.channel,
                .rssi = rec.rssi,
                .auth_mode = mapAuthMode(rec.authmode),
            };
            @memcpy(out.ssid[0..ssid_len], rec.ssid[0..ssid_len]);
            self.scan_results[idx] = out;
        }
        self.scan_count = n;
    }

    pub fn setPowerSave(self: *Driver, mode: hal_wifi.PowerSaveMode) void {
        self.power_save = mode;
        self.wifi.setPowerSave(switch (mode) {
            .none => .none,
            .min_modem => .min_modem,
            .max_modem => .max_modem,
        }) catch {};
    }

    pub fn getPowerSave(self: *const Driver) hal_wifi.PowerSaveMode {
        return self.power_save;
    }

    pub fn setRoaming(self: *Driver, cfg: hal_wifi.RoamingConfig) void {
        self.roaming_cfg = cfg;
    }

    pub fn setRssiThreshold(self: *Driver, rssi: i8) void {
        self.rssi_threshold = rssi;
    }

    pub fn setTxPower(self: *Driver, power: i8) void {
        self.tx_power = power;
        self.wifi.setMaxTxPower(power) catch {};
    }

    pub fn getTxPower(self: *const Driver) ?i8 {
        return self.tx_power;
    }

    pub fn startAp(self: *Driver, cfg: hal_wifi.ApConfig) hal_wifi.Error!void {
        self.wifi.startAp(.{
            .ssid = cfg.ssid,
            .password = cfg.password,
            .channel = cfg.channel,
            .max_connection = cfg.max_connections,
            .hidden = cfg.hidden,
        }) catch |err| return mapOpError(err);
        self.ap_running = true;
    }

    pub fn stopAp(self: *Driver) void {
        self.wifi.stopAp() catch {};
        self.ap_running = false;
    }

    pub fn isApRunning(self: *const Driver) bool {
        return self.ap_running;
    }

    pub fn getStaList(_: *const Driver) []const hal_wifi.StaInfo {
        return &[_]hal_wifi.StaInfo{};
    }

    pub fn deauthSta(_: *Driver, _: hal_wifi.Mac) void {}

    pub fn setProtocol(self: *Driver, proto: hal_wifi.Protocol) void {
        var mask: u8 = 0;
        if (proto.b) mask |= 1 << 0;
        if (proto.g) mask |= 1 << 1;
        if (proto.n) mask |= 1 << 2;
        if (proto.lr) mask |= 1 << 3;
        self.wifi.setProtocolMask(.sta, mask) catch {};
    }

    pub fn setBandwidth(self: *Driver, bw: hal_wifi.Bandwidth) void {
        self.wifi.setBandwidth(.sta, switch (bw) {
            .bw_20 => .ht20,
            .bw_40 => .ht40,
        }) catch {};
    }

    pub fn setCountryCode(self: *Driver, code: [2]u8) void {
        self.country_code = code;
    }

    pub fn getCountryCode(self: *const Driver) [2]u8 {
        return self.country_code;
    }
};

fn setSsid(self: *Driver, ssid: []const u8) void {
    const n = @min(ssid.len, self.current_ssid.len);
    @memset(self.current_ssid[0..], 0);
    @memcpy(self.current_ssid[0..n], ssid[0..n]);
    self.current_ssid_len = @intCast(n);
}

fn mapAuthMode(raw: u8) hal_wifi.AuthMode {
    return switch (raw) {
        0 => .open,
        1 => .wep,
        2 => .wpa_psk,
        3 => .wpa2_psk,
        4 => .wpa_wpa2_psk,
        5 => .wpa2_enterprise,
        6 => .wpa3_psk,
        7 => .wpa2_wpa3_psk,
        8 => .wpa3_enterprise,
        else => .open,
    };
}

fn mapInitError(err: anyerror) hal_wifi.Error {
    return switch (err) {
        error.InvalidArgument => error.InvalidConfig,
        error.InvalidState => error.Busy,
        else => error.WifiError,
    };
}

fn mapOpError(err: anyerror) hal_wifi.Error {
    return switch (err) {
        error.InvalidArgument => error.InvalidConfig,
        error.InvalidState => error.Busy,
        error.NotFound => error.Timeout,
        else => error.WifiError,
    };
}
