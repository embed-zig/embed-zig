//! Sta — type-erased low-level Wi-Fi station interface.

const types = @import("types.zig");

const Sta = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const max_ssid_len: usize = types.max_ssid_len;
pub const MacAddr = types.MacAddr;
pub const Addr = types.Addr;
pub const Security = types.Security;

pub const State = enum {
    idle,
    scanning,
    connecting,
    connected,
};

pub const ScanConfig = struct {
    active: bool = true,
    ssid: ?[]const u8 = null,
    channel: u8 = 0,
    show_hidden: bool = false,
    timeout_ms: u32 = 0,
};

pub const ConnectConfig = struct {
    ssid: []const u8,
    password: []const u8 = "",
    bssid: ?MacAddr = null,
    channel: u8 = 0,
    timeout_ms: u32 = 0,
};

pub const ScanResult = struct {
    ssid: []const u8,
    bssid: MacAddr,
    channel: u8,
    rssi: i16,
    security: Security,
};

pub const LinkInfo = struct {
    ssid: []const u8 = "",
    bssid: ?MacAddr = null,
    channel: u8 = 0,
    rssi: i16 = 0,
    security: Security = .unknown,
};

pub const IpInfo = struct {
    address: Addr,
    gateway: ?Addr = null,
    netmask: ?Addr = null,
    dns1: ?Addr = null,
    dns2: ?Addr = null,
};

pub const DisconnectInfo = struct {
    reason: u16 = 0,
};

pub const Event = union(enum) {
    scan_result: ScanResult,
    connected: LinkInfo,
    disconnected: DisconnectInfo,
    got_ip: IpInfo,
    lost_ip: void,
};

pub const ScanError = error{
    Busy,
    Unexpected,
};

pub const ConnectError = error{
    Busy,
    InvalidCredentials,
    Timeout,
    Unexpected,
};

pub const VTable = struct {
    startScan: *const fn (ptr: *anyopaque, config: ScanConfig) ScanError!void,
    stopScan: *const fn (ptr: *anyopaque) void,
    connect: *const fn (ptr: *anyopaque, config: ConnectConfig) ConnectError!void,
    disconnect: *const fn (ptr: *anyopaque) void,
    getState: *const fn (ptr: *anyopaque) State,
    addEventHook: *const fn (ptr: *anyopaque, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Event) void) void,
    removeEventHook: *const fn (ptr: *anyopaque, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Event) void) void,
    getMacAddr: *const fn (ptr: *anyopaque) ?MacAddr,
    getIpInfo: *const fn (ptr: *anyopaque) ?IpInfo,
    deinit: *const fn (ptr: *anyopaque) void,
};

pub fn startScan(self: Sta, config: ScanConfig) ScanError!void {
    return self.vtable.startScan(self.ptr, config);
}

pub fn stopScan(self: Sta) void {
    self.vtable.stopScan(self.ptr);
}

pub fn connect(self: Sta, config: ConnectConfig) ConnectError!void {
    return self.vtable.connect(self.ptr, config);
}

pub fn disconnect(self: Sta) void {
    self.vtable.disconnect(self.ptr);
}

pub fn getState(self: Sta) State {
    return self.vtable.getState(self.ptr);
}

pub fn addEventHook(self: Sta, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Event) void) void {
    self.vtable.addEventHook(self.ptr, ctx, cb);
}

pub fn removeEventHook(self: Sta, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Event) void) void {
    self.vtable.removeEventHook(self.ptr, ctx, cb);
}

pub fn getMacAddr(self: Sta) ?MacAddr {
    return self.vtable.getMacAddr(self.ptr);
}

pub fn getIpInfo(self: Sta) ?IpInfo {
    return self.vtable.getIpInfo(self.ptr);
}

pub fn deinit(self: Sta) void {
    self.vtable.deinit(self.ptr);
}

pub fn wrap(pointer: anytype) Sta {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Sta.wrap expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn startScanFn(ptr: *anyopaque, config: ScanConfig) ScanError!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.startScan(config);
        }

        fn stopScanFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.stopScan();
        }

        fn connectFn(ptr: *anyopaque, config: ConnectConfig) ConnectError!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.connect(config);
        }

        fn disconnectFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.disconnect();
        }

        fn getStateFn(ptr: *anyopaque) State {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.getState();
        }

        fn addEventHookFn(ptr: *anyopaque, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Event) void) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.addEventHook(ctx, cb);
        }

        fn removeEventHookFn(ptr: *anyopaque, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Event) void) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            if (@hasDecl(Impl, "removeEventHook")) {
                self.removeEventHook(ctx, cb);
            }
        }

        fn getMacAddrFn(ptr: *anyopaque) ?MacAddr {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            if (@hasDecl(Impl, "getMacAddr")) {
                return self.getMacAddr();
            }
            return null;
        }

        fn getIpInfoFn(ptr: *anyopaque) ?IpInfo {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            if (@hasDecl(Impl, "getIpInfo")) {
                return self.getIpInfo();
            }
            return null;
        }

        fn deinitFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.deinit();
        }

        const vtable = VTable{
            .startScan = startScanFn,
            .stopScan = stopScanFn,
            .connect = connectFn,
            .disconnect = disconnectFn,
            .getState = getStateFn,
            .addEventHook = addEventHookFn,
            .removeEventHook = removeEventHookFn,
            .getMacAddr = getMacAddrFn,
            .getIpInfo = getIpInfoFn,
            .deinit = deinitFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}

test "wifi/unit_tests/Sta_wrap_allows_missing_optional_introspection" {
    const std = @import("std");

    const Impl = struct {
        pub fn startScan(_: *@This(), _: ScanConfig) ScanError!void {}
        pub fn stopScan(_: *@This()) void {}
        pub fn connect(_: *@This(), _: ConnectConfig) ConnectError!void {}
        pub fn disconnect(_: *@This()) void {}
        pub fn getState(_: *@This()) State {
            return .idle;
        }
        pub fn addEventHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, Event) void) void {}
        pub fn deinit(_: *@This()) void {}
    };

    var impl = Impl{};
    const sta = wrap(&impl);

    sta.removeEventHook(null, struct {
        fn onEvent(_: ?*anyopaque, _: Event) void {}
    }.onEvent);
    try std.testing.expect(sta.getMacAddr() == null);
    try std.testing.expect(sta.getIpInfo() == null);
}
