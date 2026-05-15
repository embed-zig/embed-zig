//! CWSta — drivers.wifi.Sta implementation via Apple CoreWLAN.
//!
//! CoreWLAN exposes synchronous scan / associate / disassociate operations.
//! This backend translates those calls into the `drivers.wifi.Sta` interface and
//! emits best-effort events from operations initiated through this adapter.

const glib = @import("glib");
const embed = @import("embed");
const std = @import("std");
const drivers = embed.drivers;
const wifi = drivers.wifi;
const Sta = wifi.Sta;
const objc = @import("objc.zig");
const location = @import("Location.zig");
const Allocator = glib.std.mem.Allocator;
const IfAddrs = extern struct {
    ifa_next: ?*IfAddrs,
    ifa_name: [*:0]const u8,
    ifa_flags: c_uint,
    ifa_addr: ?*std.c.sockaddr,
    ifa_netmask: ?*std.c.sockaddr,
    ifa_dstaddr: ?*std.c.sockaddr,
    ifa_data: ?*anyopaque,
};

extern "c" fn getifaddrs(ifap: *?*IfAddrs) c_int;
extern "c" fn freeifaddrs(ifa: ?*IfAddrs) void;

const CWSta = @This();

allocator: Allocator,
interface_name: ?[]const u8,
state: Sta.State = .idle,
hooks: glib.std.ArrayListUnmanaged(EventHook) = .{},
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
const kPosixBusyErr: objc.NSInteger = 16;

pub const Config = struct {
    interface_name: ?[]const u8 = null,
    request_location_authorization: bool = false,
    location_authorization_timeout: glib.time.duration.Duration = 8 * glib.time.duration.Second,
};

pub fn init(allocator: Allocator, config: Config) CWSta {
    if (config.request_location_authorization) {
        const status = location.requestWhenInUseAuthorization(config.location_authorization_timeout);
        std.log.info("core_wlan location authorization status={s}", .{@tagName(status)});
    }

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
    std.log.info("core_wlan scan start ssid={s} hidden={}", .{
        config.ssid orelse "",
        config.show_hidden,
    });
    const networks = objc.msgSend(?objc.Id, interface, objc.sel("scanForNetworksWithName:includeHidden:error:"), .{
        @as(?*anyopaque, if (filter_name) |value| @ptrCast(value) else null),
        @as(objc.BOOL, if (config.show_hidden) objc.YES else objc.NO),
        @as(*?objc.Id, &ns_error),
    }) orelse return error.Unexpected;
    if (ns_error != null) return mapScanError(ns_error.?);

    const array = objc.msgSend(objc.Id, networks, objc.sel("allObjects"), .{});
    const count: objc.NSUInteger = objc.msgSend(objc.NSUInteger, array, objc.sel("count"), .{});
    std.log.info("core_wlan scan result count={d}", .{count});
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
    std.log.info("core_wlan connect start ssid={s} channel={d}", .{ config.ssid, config.channel });
    var current_ssid_buf: [Sta.max_ssid_len]u8 = [_]u8{0} ** Sta.max_ssid_len;
    if (self.currentLinkInfo(interface, &current_ssid_buf)) |info| {
        std.log.info("core_wlan current link ssid={s} has_ip={}", .{ info.ssid, self.getIpInfo() != null });
        if (currentLinkMatches(info, config)) {
            self.mutex.lock();
            self.state = .connected;
            self.mutex.unlock();

            self.fireEvent(.{ .connected = info });
            if (self.getIpInfo()) |ip_info| {
                self.fireEvent(.{ .got_ip = ip_info });
            }
            return;
        }
    }

    const network = try self.findNetwork(interface, config);
    std.log.info("core_wlan connect found network ssid={s}", .{config.ssid});

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
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const interface = self.getInterface() orelse return null;
    var ssid_buf: [Sta.max_ssid_len]u8 = undefined;
    _ = self.currentLinkInfo(interface, &ssid_buf) orelse return null;

    const name_obj = objc.msgSend(?objc.Id, interface, objc.sel("interfaceName"), .{}) orelse return null;
    var interface_name_buf: [32]u8 = undefined;
    const interface_name = objc.nsStringGetBytes(name_obj, &interface_name_buf);
    if (interface_name.len == 0) return null;

    return self.ipInfoForInterface(interface_name);
}

pub fn getCurrentSsid(self: *CWSta, out: *[Sta.max_ssid_len]u8) ?[]const u8 {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const interface = self.getInterface() orelse return null;
    const info = self.currentLinkInfo(interface, out) orelse return null;
    return info.ssid;
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
    _ = self;
    var ns_error: ?objc.Id = null;
    const name_obj = objc.nsString(config.ssid);
    const networks = objc.msgSend(?objc.Id, interface, objc.sel("scanForNetworksWithName:includeHidden:error:"), .{
        @as(?*anyopaque, @ptrCast(name_obj)),
        @as(objc.BOOL, objc.YES),
        @as(*?objc.Id, &ns_error),
    }) orelse return error.Unexpected;
    if (ns_error != null) return mapConnectError(ns_error.?);

    const array = objc.msgSend(objc.Id, networks, objc.sel("allObjects"), .{});
    const count: objc.NSUInteger = objc.msgSend(objc.NSUInteger, array, objc.sel("count"), .{});
    std.log.info("core_wlan find network scan ssid={s} count={d}", .{ config.ssid, count });
    var index: objc.NSUInteger = 0;
    while (index < count) : (index += 1) {
        const network = objc.msgSend(objc.Id, array, objc.sel("objectAtIndex:"), .{index});
        if (!networkMatches(network, config)) {
            logNetworkCandidate(network);
            continue;
        }
        return network;
    }
    std.log.warn("core_wlan find network no match ssid={s}", .{config.ssid});
    return error.Unexpected;
}

fn logNetworkCandidate(network: objc.Id) void {
    var ssid_buf: [Sta.max_ssid_len]u8 = [_]u8{0} ** Sta.max_ssid_len;
    const ssid = ssidFromObject(network, &ssid_buf) orelse {
        std.log.info("core_wlan candidate ssid=<null>", .{});
        return;
    };
    std.log.info("core_wlan candidate ssid={s}", .{ssid});
}

fn networkMatches(network: objc.Id, config: Sta.ConnectConfig) bool {
    var ssid_buf: [Sta.max_ssid_len]u8 = [_]u8{0} ** Sta.max_ssid_len;
    const ssid = ssidFromObject(network, &ssid_buf) orelse return false;
    if (!glib.std.mem.eql(u8, ssid, config.ssid)) return false;

    if (config.channel != 0) {
        const channel_obj = objc.msgSend(?objc.Id, network, objc.sel("wlanChannel"), .{}) orelse return false;
        const channel: objc.NSInteger = objc.msgSend(objc.NSInteger, channel_obj, objc.sel("channelNumber"), .{});
        if (@as(u8, @intCast(channel)) != config.channel) return false;
    }

    if (config.bssid) |bssid| {
        const bssid_obj = objc.msgSend(?objc.Id, network, objc.sel("bssid"), .{}) orelse return false;
        var bssid_buf: [17]u8 = undefined;
        const parsed = parseMacAddress(objc.nsStringGetBytes(bssid_obj, &bssid_buf)) orelse return false;
        return glib.std.mem.eql(u8, parsed[0..], bssid[0..]);
    }

    return true;
}

fn currentLinkMatches(info: Sta.LinkInfo, config: Sta.ConnectConfig) bool {
    if (!glib.std.mem.eql(u8, info.ssid, config.ssid)) return false;
    if (config.channel != 0 and info.channel != config.channel) return false;
    if (config.bssid) |expected| {
        const actual = info.bssid orelse return false;
        if (!glib.std.mem.eql(u8, actual[0..], expected[0..])) return false;
    }
    return true;
}

fn currentLinkInfo(self: *CWSta, interface: objc.Id, ssid_buf: *[Sta.max_ssid_len]u8) ?Sta.LinkInfo {
    _ = self;
    const ssid = ssidFromObject(interface, ssid_buf) orelse return null;

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
    return .{
        .ssid = ssid,
        .bssid = bssid,
        .channel = channel,
        .rssi = rssi,
        .security = securityFromObject(interface),
    };
}

fn ipInfoForInterface(self: *CWSta, interface_name: []const u8) ?Sta.IpInfo {
    _ = self;

    var addrs: ?*IfAddrs = null;
    if (getifaddrs(&addrs) != 0) return null;
    defer freeifaddrs(addrs);

    var current = addrs;
    while (current) |entry| : (current = entry.ifa_next) {
        if (!glib.std.mem.eql(u8, std.mem.span(entry.ifa_name), interface_name)) continue;
        const addr = ipv4FromSockaddr(entry.ifa_addr) orelse continue;
        if (!isUsableIpv4(addr)) continue;

        return .{
            .address = glib.net.netip.Addr.from4(addr),
            .netmask = if (ipv4FromSockaddr(entry.ifa_netmask)) |netmask|
                glib.net.netip.Addr.from4(netmask)
            else
                null,
        };
    }

    return null;
}

fn ipv4FromSockaddr(sockaddr: ?*std.c.sockaddr) ?[4]u8 {
    const addr = sockaddr orelse return null;
    if (addr.family != std.c.AF.INET) return null;
    const in_addr: *const std.c.sockaddr.in = @ptrCast(@alignCast(addr));
    return @bitCast(in_addr.addr);
}

fn isUsableIpv4(addr: [4]u8) bool {
    if (addr[0] == 0) return false;
    if (addr[0] == 127) return false;
    if (addr[0] == 169 and addr[1] == 254) return false;
    return true;
}

fn scanResultFromNetwork(network: objc.Id, ssid_buf: *[Sta.max_ssid_len]u8) ?Sta.ScanResult {
    const ssid = ssidFromObject(network, ssid_buf) orelse return null;

    const bssid_obj = objc.msgSend(?objc.Id, network, objc.sel("bssid"), .{}) orelse return null;
    var bssid_buf: [17]u8 = undefined;
    const bssid = parseMacAddress(objc.nsStringGetBytes(bssid_obj, &bssid_buf)) orelse return null;

    const channel_obj = objc.msgSend(?objc.Id, network, objc.sel("wlanChannel"), .{});
    const channel = if (channel_obj) |obj|
        @as(u8, @intCast(objc.msgSend(objc.NSInteger, obj, objc.sel("channelNumber"), .{})))
    else
        0;

    const rssi = @as(i16, @intCast(objc.msgSend(objc.NSInteger, network, objc.sel("rssiValue"), .{})));
    return .{
        .ssid = ssid,
        .bssid = bssid,
        .channel = channel,
        .rssi = rssi,
        .security = securityFromObject(network),
    };
}

fn ssidFromObject(obj: objc.Id, buf: *[Sta.max_ssid_len]u8) ?[]const u8 {
    const ssid_data_sel = objc.sel("ssidData");
    if (objc.respondsToSelector(obj, ssid_data_sel)) {
        if (objc.msgSend(?objc.Id, obj, ssid_data_sel, .{})) |data| {
            const len = objc.msgSend(objc.NSUInteger, data, objc.sel("length"), .{});
            if (len != 0) {
                const bytes = objc.msgSend(?[*]const u8, data, objc.sel("bytes"), .{}) orelse return null;
                const copy_len = @min(len, buf.len);
                @memcpy(buf[0..copy_len], bytes[0..copy_len]);
                return buf[0..copy_len];
            }
        }
    }

    const ssid_obj = objc.msgSend(?objc.Id, obj, objc.sel("ssid"), .{}) orelse return null;
    const ssid = objc.nsStringGetBytes(ssid_obj, buf);
    if (ssid.len == 0) return null;
    return ssid;
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

fn securityFromObject(obj: objc.Id) Sta.Security {
    const security_sel = objc.sel("security");
    if (!objc.respondsToSelector(obj, security_sel)) return .unknown;
    return mapSecurity(objc.msgSend(objc.NSInteger, obj, security_sel, .{}));
}

fn mapScanError(err_obj: objc.Id) Sta.ScanError {
    logNSError("core_wlan scan error", err_obj);
    return error.Unexpected;
}

fn mapConnectError(err_obj: objc.Id) Sta.ConnectError {
    const code = objc.msgSend(objc.NSInteger, err_obj, objc.sel("code"), .{});
    logNSError("core_wlan connect error", err_obj);
    return switch (code) {
        kPosixBusyErr => error.Busy,
        kCWTimeoutErr, kCWSupplicantTimeoutErr => error.Timeout,
        kCWAssociationDeniedErr, kCWChallengeFailureErr => error.InvalidCredentials,
        else => error.Unexpected,
    };
}

fn logNSError(prefix: []const u8, err_obj: objc.Id) void {
    const code = objc.msgSend(objc.NSInteger, err_obj, objc.sel("code"), .{});
    const domain_obj = objc.msgSend(?objc.Id, err_obj, objc.sel("domain"), .{});
    const desc_obj = objc.msgSend(?objc.Id, err_obj, objc.sel("localizedDescription"), .{});

    var domain_buf: [128]u8 = undefined;
    var desc_buf: [256]u8 = undefined;
    const domain = if (domain_obj) |value| objc.nsStringGetBytes(value, &domain_buf) else "";
    const desc = if (desc_obj) |value| objc.nsStringGetBytes(value, &desc_buf) else "";
    std.log.warn("{s} code={d} domain={s} description={s}", .{ prefix, code, domain, desc });
}

fn parseMacAddress(value: []const u8) ?Sta.MacAddr {
    var parts = glib.std.mem.tokenizeScalar(u8, value, ':');
    var addr: Sta.MacAddr = undefined;
    var index: usize = 0;
    while (parts.next()) |part| {
        if (index >= addr.len) return null;
        addr[index] = glib.std.fmt.parseInt(u8, part, 16) catch return null;
        index += 1;
    }
    if (index != addr.len) return null;
    return addr;
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn parseMacAddressParsesColonSeparatedHexBytes() !void {
            try grt.std.testing.expectEqual(
                Sta.MacAddr{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60 },
                parseMacAddress("10:20:30:40:50:60").?,
            );
        }

        fn ipv4FromSockaddrReadsDarwinSockaddrInBytes() !void {
            var sock_addr = std.c.sockaddr.in{
                .port = 0,
                .addr = @bitCast([4]u8{ 192, 168, 1, 23 }),
            };
            const addr: *std.c.sockaddr = @ptrCast(&sock_addr);
            try grt.std.testing.expectEqual([4]u8{ 192, 168, 1, 23 }, ipv4FromSockaddr(addr).?);
        }

        fn isUsableIpv4RejectsNonRoutableAddresses() !void {
            try grt.std.testing.expect(!isUsableIpv4(.{ 0, 0, 0, 0 }));
            try grt.std.testing.expect(!isUsableIpv4(.{ 127, 0, 0, 1 }));
            try grt.std.testing.expect(!isUsableIpv4(.{ 169, 254, 1, 2 }));
            try grt.std.testing.expect(isUsableIpv4(.{ 192, 168, 1, 23 }));
        }

        fn currentLinkMatchesHonorsOptionalConstraints() !void {
            const bssid: Sta.MacAddr = .{ 1, 2, 3, 4, 5, 6 };
            const other_bssid: Sta.MacAddr = .{ 6, 5, 4, 3, 2, 1 };
            const info: Sta.LinkInfo = .{
                .ssid = "test-wifi",
                .bssid = bssid,
                .channel = 6,
            };

            try grt.std.testing.expect(currentLinkMatches(info, .{ .ssid = "test-wifi" }));
            try grt.std.testing.expect(currentLinkMatches(info, .{ .ssid = "test-wifi", .channel = 6 }));
            try grt.std.testing.expect(currentLinkMatches(info, .{ .ssid = "test-wifi", .bssid = bssid }));
            try grt.std.testing.expect(!currentLinkMatches(info, .{ .ssid = "other-wifi" }));
            try grt.std.testing.expect(!currentLinkMatches(info, .{ .ssid = "test-wifi", .channel = 11 }));
            try grt.std.testing.expect(!currentLinkMatches(info, .{ .ssid = "test-wifi", .bssid = other_bssid }));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.parseMacAddressParsesColonSeparatedHexBytes() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.ipv4FromSockaddrReadsDarwinSockaddrInBytes() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.isUsableIpv4RejectsNonRoutableAddresses() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.currentLinkMatchesHonorsOptionalConstraints() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
