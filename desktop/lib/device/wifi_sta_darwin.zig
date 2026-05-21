const core_wlan = @import("core_wlan");
const embed = @import("embed");
const glib = @import("glib");
const std = @import("std");

const WifiSta = @This();
const Sta = embed.drivers.wifi.Sta;

pub const Config = core_wlan.Sta.Config;

inner: *core_wlan.Sta,

pub fn init(allocator: glib.std.mem.Allocator, config: Config) !WifiSta {
    if (config.request_location_authorization) {
        const status = core_wlan.requestLocationAuthorization(config.location_authorization_timeout);
        std.log.info("desktop wifi sta location authorization status={s}", .{@tagName(status)});
    }

    const inner = try allocator.create(core_wlan.Sta);
    errdefer allocator.destroy(inner);

    inner.* = core_wlan.Sta.init(allocator, config);
    return .{
        .inner = inner,
    };
}

pub fn deinit(self: *WifiSta) void {
    self.inner.deinit();
    self.* = undefined;
}

pub fn handle(self: *WifiSta) Sta {
    return Sta.make(self);
}

pub fn startScan(self: *WifiSta, config: Sta.ScanConfig) Sta.ScanError!void {
    return self.inner.startScan(config);
}

pub fn stopScan(self: *WifiSta) void {
    self.inner.stopScan();
}

pub fn connect(self: *WifiSta, config: Sta.ConnectConfig) Sta.ConnectError!void {
    return self.inner.connect(config);
}

pub fn disconnect(self: *WifiSta) void {
    self.inner.disconnect();
}

pub fn getState(self: *WifiSta) Sta.State {
    return self.inner.getState();
}

pub fn addEventHook(
    self: *WifiSta,
    ctx: ?*anyopaque,
    cb: *const fn (?*anyopaque, Sta.Event) void,
) void {
    self.inner.addEventHook(ctx, cb);
}

pub fn removeEventHook(
    self: *WifiSta,
    ctx: ?*anyopaque,
    cb: *const fn (?*anyopaque, Sta.Event) void,
) void {
    self.inner.removeEventHook(ctx, cb);
}

pub fn getMacAddr(self: *WifiSta) ?Sta.MacAddr {
    return self.inner.getMacAddr();
}

pub fn getIpInfo(self: *WifiSta) ?Sta.IpInfo {
    return self.inner.getIpInfo();
}

pub fn getCurrentSsid(self: *WifiSta, out: *[Sta.max_ssid_len]u8) ?[]const u8 {
    return self.inner.getCurrentSsid(out);
}
