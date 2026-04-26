//! CWSta — drivers.wifi.Sta implementation via Apple CoreWLAN.
//!
//! CoreWLAN exposes synchronous scan / associate / disassociate operations.
//! This backend translates those calls into the `drivers.wifi.Sta` interface and
//! emits best-effort events from operations initiated through this adapter.

const embed = @import("embed");
const std = @import("embed_std").std;
const drivers = @import("drivers");
const testing_api = @import("testing");
const wifi = drivers.wifi;
const Sta = wifi.Sta;
const objc = @import("objc.zig");
const Allocator = embed.mem.Allocator;

const CWSta = @This();

allocator: Allocator,
interface_name: ?[]const u8,
state: Sta.State = .idle,
hooks: embed.ArrayListUnmanaged(EventHook) = .{},
mutex: std.Thread.Mutex = .{},

const EventHook = struct {
    ctx: ?*anyopaque,
    cb: *const fn (?*anyopaque, Sta.Event) void,
};

const kCWSecurityNone: objc.NSInteger = 0;
const kCWSecurityWEP: objc.NSInteger = 1;
const kCWSecurityWPAPersonal: objc.NSInteger = 2;
const kCWSecurityWPAPersonalMixed: objc.NSInteger = 3;
const kCWSecurityWPA2Personal: objc.NSInteger = 4;
const kCWSecurityPersonal: objc.NSInteger = 5;
const kCWSecurityDynamicWEP: objc.NSInteger = 6;
const kCWSecurityWPAEnterprise: objc.NSInteger = 7;
const kCWSecurityWPAEnterpriseMixed: objc.NSInteger = 8;
const kCWSecurityWPA2Enterprise: objc.NSInteger = 9;
const kCWSecurityEnterprise: objc.NSInteger = 10;
const kCWSecurityWPA3Personal: objc.NSInteger = 11;
const kCWSecurityWPA3Enterprise: objc.NSInteger = 12;
const kCWSecurityWPA3Transition: objc.NSInteger = 13;
const kCWTimeoutErr: objc.NSInteger = -3905;
const kCWAssociationDeniedErr: objc.NSInteger = -3909;
const kCWChallengeFailureErr: objc.NSInteger = -3912;
const kCWSupplicantTimeoutErr: objc.NSInteger = -3925;

pub const Config = struct {
    interface_name: ?[]const u8 = null,
};

pub fn init(allocator: Allocator, config: Config) CWSta {
    return .{
        .allocator = allocator,
        .interface_name = config.interface_name,
    };
}

pub fn deinit(self: *CWSta) void {
    self.hooks.deinit(self.allocator);
    const alloc = self.allocator;
    self.* = undefined;
    alloc.destroy(self);
}

pub fn startScan(self: *CWSta, config: Sta.ScanConfig) Sta.ScanError!void {
    var previous_state: Sta.State = .idle;
    self.mutex.lock();
    if (self.state == .scanning) {
        self.mutex.unlock();
        return error.Busy;
    }
    previous_state = self.state;
    self.state = .scanning;
    self.mutex.unlock();
    defer {
        self.mutex.lock();
        self.state = previous_state;
        self.mutex.unlock();
    }

    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const interface = self.getInterface() orelse return error.Unexpected;
    const filter_name: ?objc.Id = if (config.ssid) |ssid| objc.nsString(ssid) else null;
    var ns_error: ?objc.Id = null;
    const networks = objc.msgSend(?objc.Id, interface, objc.sel("scanForNetworksWithName:includeHidden:error:"), .{
        @as(?*anyopaque, if (filter_name) |value| @ptrCast(value) else null),
        @as(objc.BOOL, if (config.show_hidden) objc.YES else objc.NO),
        @as(*?objc.Id, &ns_error),
    }) orelse return error.Unexpected;
    if (ns_error != null) return mapScanError(ns_error.?);

    const array = objc.msgSend(objc.Id, networks, objc.sel("allObjects"), .{});
    const count: objc.NSUInteger = objc.msgSend(objc.NSUInteger, array, objc.sel("count"), .{});
    var index: objc.NSUInteger = 0;
    while (index < count) : (index += 1) {
        const network = objc.msgSend(objc.Id, array, objc.sel("objectAtIndex:"), .{index});
        var ssid_buf: [Sta.max_ssid_len]u8 = [_]u8{0} ** Sta.max_ssid_len;
        const result = scanResultFromNetwork(network, &ssid_buf) orelse continue;
        if (config.channel != 0 and result.channel != config.channel) continue;
        self.fireEvent(.{ .scan_result = result });
    }
}

pub fn stopScan(self: *CWSta) void {
    self.mutex.lock();
    if (self.state == .scanning) self.state = .idle;
    self.mutex.unlock();
}

pub fn connect(self: *CWSta, config: Sta.ConnectConfig) Sta.ConnectError!void {
    self.mutex.lock();
    if (self.state == .connecting) {
        self.mutex.unlock();
        return error.Busy;
    }
    self.state = .connecting;
    self.mutex.unlock();
    errdefer {
        self.mutex.lock();
        self.state = .idle;
        self.mutex.unlock();
    }

    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const interface = self.getInterface() orelse return error.Unexpected;
    const network = try self.findNetwork(interface, config);

    const password_obj: ?objc.Id = if (config.password.len > 0) objc.nsString(config.password) else null;
    var ns_error: ?objc.Id = null;
    objc.msgSend(void, interface, objc.sel("associateToNetwork:password:error:"), .{
        network,
        @as(?*anyopaque, if (password_obj) |value| @ptrCast(value) else null),
        @as(*?objc.Id, &ns_error),
    });
    if (ns_error) |err| return mapConnectError(err);

    self.mutex.lock();
    self.state = .connected;
    self.mutex.unlock();

    var link_ssid_buf: [Sta.max_ssid_len]u8 = [_]u8{0} ** Sta.max_ssid_len;
    if (self.currentLinkInfo(interface, &link_ssid_buf)) |info| {
        self.fireEvent(.{ .connected = info });
    }
    if (self.getIpInfo()) |ip_info| {
        self.fireEvent(.{ .got_ip = ip_info });
    }
}

pub fn disconnect(self: *CWSta) void {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    if (self.getInterface()) |interface| {
        objc.msgSend(void, interface, objc.sel("disassociate"), .{});
    }
    self.mutex.lock();
    self.state = .idle;
    self.mutex.unlock();
    self.fireEvent(.{ .disconnected = .{} });
}

pub fn getState(self: *CWSta) Sta.State {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.state;
}

pub fn addEventHook(self: *CWSta, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Sta.Event) void) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.hooks.append(self.allocator, .{
        .ctx = ctx,
        .cb = cb,
    }) catch {};
}

pub fn removeEventHook(self: *CWSta, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Sta.Event) void) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    for (self.hooks.items, 0..) |hook, index| {
        if (hook.ctx == ctx and hook.cb == cb) {
            _ = self.hooks.swapRemove(index);
            break;
        }
    }
}

pub fn getMacAddr(self: *CWSta) ?Sta.MacAddr {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const interface = self.getInterface() orelse return null;
    const addr_obj = objc.msgSend(?objc.Id, interface, objc.sel("hardwareAddress"), .{}) orelse return null;
    var buf: [17]u8 = undefined;
    return parseMacAddress(objc.nsStringGetBytes(addr_obj, &buf));
}

pub fn getIpInfo(self: *CWSta) ?Sta.IpInfo {
    _ = self;
    return null;
}

fn getInterface(self: *CWSta) ?objc.Id {
    const client = objc.msgSend(?objc.Id, objc.getClass("CWWiFiClient"), objc.sel("sharedWiFiClient"), .{}) orelse return null;
    if (self.interface_name) |name| {
        const name_obj = objc.nsString(name);
        return objc.msgSend(?objc.Id, client, objc.sel("interfaceWithName:"), .{name_obj});
    }
    return objc.msgSend(?objc.Id, client, objc.sel("interface"), .{});
}

fn findNetwork(self: *CWSta, interface: objc.Id, config: Sta.ConnectConfig) Sta.ConnectError!objc.Id {
    const scan_config: Sta.ScanConfig = .{
        .ssid = config.ssid,
        .channel = config.channel,
    };
    self.startScan(scan_config) catch |err| switch (err) {
        error.Busy => {},
        error.Unexpected => return error.Unexpected,
    };

    var ns_error: ?objc.Id = null;
    const name_obj = objc.nsString(config.ssid);
    const networks = objc.msgSend(?objc.Id, interface, objc.sel("scanForNetworksWithName:includeHidden:error:"), .{
        @as(?*anyopaque, @ptrCast(name_obj)),
        @as(objc.BOOL, objc.NO),
        @as(*?objc.Id, &ns_error),
    }) orelse return error.Unexpected;
    if (ns_error != null) return mapConnectError(ns_error.?);

    const array = objc.msgSend(objc.Id, networks, objc.sel("allObjects"), .{});
    const count: objc.NSUInteger = objc.msgSend(objc.NSUInteger, array, objc.sel("count"), .{});
    var index: objc.NSUInteger = 0;
    while (index < count) : (index += 1) {
        const network = objc.msgSend(objc.Id, array, objc.sel("objectAtIndex:"), .{index});
        if (!networkMatches(network, config)) continue;
        return network;
    }
    return error.Unexpected;
}

fn networkMatches(network: objc.Id, config: Sta.ConnectConfig) bool {
    var ssid_buf: [Sta.max_ssid_len]u8 = [_]u8{0} ** Sta.max_ssid_len;
    const ssid_obj = objc.msgSend(?objc.Id, network, objc.sel("ssid"), .{}) orelse return false;
    const ssid = objc.nsStringGetBytes(ssid_obj, &ssid_buf);
    if (!embed.mem.eql(u8, ssid, config.ssid)) return false;

    if (config.channel != 0) {
        const channel_obj = objc.msgSend(?objc.Id, network, objc.sel("wlanChannel"), .{}) orelse return false;
        const channel: objc.NSInteger = objc.msgSend(objc.NSInteger, channel_obj, objc.sel("channelNumber"), .{});
        if (@as(u8, @intCast(channel)) != config.channel) return false;
    }

    if (config.bssid) |bssid| {
        const bssid_obj = objc.msgSend(?objc.Id, network, objc.sel("bssid"), .{}) orelse return false;
        var bssid_buf: [17]u8 = undefined;
        const parsed = parseMacAddress(objc.nsStringGetBytes(bssid_obj, &bssid_buf)) orelse return false;
        return embed.mem.eql(u8, parsed[0..], bssid[0..]);
    }

    return true;
}

fn currentLinkInfo(self: *CWSta, interface: objc.Id, ssid_buf: *[Sta.max_ssid_len]u8) ?Sta.LinkInfo {
    _ = self;
    const ssid_obj = objc.msgSend(?objc.Id, interface, objc.sel("ssid"), .{}) orelse return null;
    const ssid = objc.nsStringGetBytes(ssid_obj, ssid_buf);

    const bssid_obj = objc.msgSend(?objc.Id, interface, objc.sel("bssid"), .{});
    var bssid_buf: [17]u8 = undefined;
    const bssid = if (bssid_obj) |obj|
        parseMacAddress(objc.nsStringGetBytes(obj, &bssid_buf))
    else
        null;

    const channel_obj = objc.msgSend(?objc.Id, interface, objc.sel("wlanChannel"), .{});
    const channel = if (channel_obj) |obj|
        @as(u8, @intCast(objc.msgSend(objc.NSInteger, obj, objc.sel("channelNumber"), .{})))
    else
        0;

    const rssi = @as(i16, @intCast(objc.msgSend(objc.NSInteger, interface, objc.sel("rssiValue"), .{})));
    const security_raw = objc.msgSend(objc.NSInteger, interface, objc.sel("security"), .{});
    return .{
        .ssid = ssid,
        .bssid = bssid,
        .channel = channel,
        .rssi = rssi,
        .security = mapSecurity(security_raw),
    };
}

fn scanResultFromNetwork(network: objc.Id, ssid_buf: *[Sta.max_ssid_len]u8) ?Sta.ScanResult {
    const ssid_obj = objc.msgSend(?objc.Id, network, objc.sel("ssid"), .{}) orelse return null;
    const ssid = objc.nsStringGetBytes(ssid_obj, ssid_buf);

    const bssid_obj = objc.msgSend(?objc.Id, network, objc.sel("bssid"), .{}) orelse return null;
    var bssid_buf: [17]u8 = undefined;
    const bssid = parseMacAddress(objc.nsStringGetBytes(bssid_obj, &bssid_buf)) orelse return null;

    const channel_obj = objc.msgSend(?objc.Id, network, objc.sel("wlanChannel"), .{});
    const channel = if (channel_obj) |obj|
        @as(u8, @intCast(objc.msgSend(objc.NSInteger, obj, objc.sel("channelNumber"), .{})))
    else
        0;

    const rssi = @as(i16, @intCast(objc.msgSend(objc.NSInteger, network, objc.sel("rssiValue"), .{})));
    const security_raw = objc.msgSend(objc.NSInteger, network, objc.sel("security"), .{});
    return .{
        .ssid = ssid,
        .bssid = bssid,
        .channel = channel,
        .rssi = rssi,
        .security = mapSecurity(security_raw),
    };
}

fn fireEvent(self: *CWSta, event: Sta.Event) void {
    self.mutex.lock();
    const snapshot = self.allocator.dupe(EventHook, self.hooks.items) catch {
        self.mutex.unlock();
        return;
    };
    self.mutex.unlock();
    defer self.allocator.free(snapshot);

    for (snapshot) |hook| {
        hook.cb(hook.ctx, event);
    }
}

fn mapSecurity(raw: objc.NSInteger) Sta.Security {
    return switch (raw) {
        kCWSecurityNone => .open,
        kCWSecurityWEP, kCWSecurityDynamicWEP => .wep,
        kCWSecurityWPAPersonal, kCWSecurityWPAPersonalMixed, kCWSecurityWPAEnterprise, kCWSecurityWPAEnterpriseMixed => .wpa,
        kCWSecurityWPA2Personal, kCWSecurityPersonal, kCWSecurityWPA2Enterprise, kCWSecurityEnterprise => .wpa2,
        kCWSecurityWPA3Personal, kCWSecurityWPA3Enterprise, kCWSecurityWPA3Transition => .wpa3,
        else => .unknown,
    };
}

fn mapScanError(err_obj: objc.Id) Sta.ScanError {
    _ = err_obj;
    return error.Unexpected;
}

fn mapConnectError(err_obj: objc.Id) Sta.ConnectError {
    const code = objc.msgSend(objc.NSInteger, err_obj, objc.sel("code"), .{});
    return switch (code) {
        kCWTimeoutErr, kCWSupplicantTimeoutErr => error.Timeout,
        kCWAssociationDeniedErr, kCWChallengeFailureErr => error.InvalidCredentials,
        else => error.Unexpected,
    };
}

fn parseMacAddress(value: []const u8) ?Sta.MacAddr {
    var parts = embed.mem.tokenizeScalar(u8, value, ':');
    var addr: Sta.MacAddr = undefined;
    var index: usize = 0;
    while (parts.next()) |part| {
        if (index >= addr.len) return null;
        addr[index] = embed.fmt.parseInt(u8, part, 16) catch return null;
        index += 1;
    }
    if (index != addr.len) return null;
    return addr;
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn parseMacAddressParsesColonSeparatedHexBytes() !void {
            try lib.testing.expectEqual(
                Sta.MacAddr{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60 },
                parseMacAddress("10:20:30:40:50:60").?,
            );
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.parseMacAddressParsesColonSeparatedHexBytes() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
