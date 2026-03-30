//! Central — type-erased low-level BLE Central interface.
//!
//! This is the backend-facing VTable surface. It exposes scanning,
//! connection management, GATT discovery, and raw attribute operations.
//! Higher-level concepts like Conn/Char/Subscription are built on top
//! in the host-side helpers under `lib/bt/host/`.

const Central = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const BdAddr = [6]u8;

pub const AddrType = enum {
    public,
    random,
};

pub const State = enum {
    idle,
    scanning,
    connecting,
    connected,
};

pub const ScanConfig = struct {
    active: bool = true,
    /// Scan interval in milliseconds. Backends that speak raw HCI must convert
    /// this to controller-specific scan units.
    interval_ms: u16 = 10,
    /// Scan window in milliseconds. Backends that speak raw HCI must convert
    /// this to controller-specific scan units.
    window_ms: u16 = 10,
    filter_duplicates: bool = true,
    timeout_ms: u32 = 0,
    service_uuids: []const u16 = &.{},
};

pub const ConnParams = struct {
    interval_min: u16 = 0x0006,
    interval_max: u16 = 0x0006,
    latency: u16 = 0,
    timeout: u16 = 0x00C8,
};

pub const AdvReport = struct {
    addr: BdAddr,
    addr_type: AddrType,
    rssi: i8,
    name: [32]u8 = .{0} ** 32,
    name_len: u8 = 0,
    data: [31]u8 = .{0} ** 31,
    data_len: u8 = 0,

    pub fn getName(self: *const AdvReport) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getData(self: *const AdvReport) []const u8 {
        return self.data[0..self.data_len];
    }
};

pub const ConnectionInfo = struct {
    conn_handle: u16,
    peer_addr: BdAddr,
    peer_addr_type: AddrType,
    interval: u16,
    latency: u16,
    timeout: u16,
};

pub const DiscoveredService = struct {
    start_handle: u16,
    end_handle: u16,
    uuid: u16,
};

pub const DiscoveredChar = struct {
    decl_handle: u16,
    value_handle: u16,
    cccd_handle: u16,
    properties: u8,
    uuid: u16,
};

pub const DEFAULT_ATT_MTU: u16 = 23;
pub const MAX_ATT_MTU: u16 = 517;
pub const ATT_VALUE_OVERHEAD: u16 = 3;
pub const MAX_NOTIFICATION_VALUE_LEN: usize = MAX_ATT_MTU - ATT_VALUE_OVERHEAD;

pub const NotificationData = struct {
    conn_handle: u16,
    attr_handle: u16,
    data: [MAX_NOTIFICATION_VALUE_LEN]u8 = undefined,
    len: u16 = 0,

    pub fn payload(self: *const NotificationData) []const u8 {
        return self.data[0..self.len];
    }
};

pub const CentralEvent = union(enum) {
    device_found: AdvReport,
    connected: ConnectionInfo,
    disconnected: u16,
    notification: NotificationData,
};

pub const StartError = error{
    BluetoothUnavailable,
    Unexpected,
};

pub const ScanError = error{
    Busy,
    Unexpected,
};

pub const ConnectError = error{
    Timeout,
    Rejected,
    Unexpected,
};

pub const GattError = error{
    AttError,
    Timeout,
    Disconnected,
    Unexpected,
};

pub const VTable = struct {
    start: *const fn (ptr: *anyopaque) StartError!void,
    stop: *const fn (ptr: *anyopaque) void,
    startScanning: *const fn (ptr: *anyopaque, config: ScanConfig) ScanError!void,
    stopScanning: *const fn (ptr: *anyopaque) void,
    connect: *const fn (ptr: *anyopaque, addr: BdAddr, addr_type: AddrType, params: ConnParams) ConnectError!ConnectionInfo,
    disconnect: *const fn (ptr: *anyopaque, conn_handle: u16) void,
    discoverServices: *const fn (ptr: *anyopaque, conn_handle: u16, out: []DiscoveredService) GattError!usize,
    discoverChars: *const fn (ptr: *anyopaque, conn_handle: u16, start_handle: u16, end_handle: u16, out: []DiscoveredChar) GattError!usize,
    gattRead: *const fn (ptr: *anyopaque, conn_handle: u16, attr_handle: u16, out: []u8) GattError!usize,
    gattWrite: *const fn (ptr: *anyopaque, conn_handle: u16, attr_handle: u16, data: []const u8) GattError!void,
    gattWriteNoResp: *const fn (ptr: *anyopaque, conn_handle: u16, attr_handle: u16, data: []const u8) GattError!void,
    exchangeMtu: *const fn (ptr: *anyopaque, conn_handle: u16, mtu: u16) GattError!u16,
    subscribe: *const fn (ptr: *anyopaque, conn_handle: u16, cccd_handle: u16) GattError!void,
    subscribeIndications: *const fn (ptr: *anyopaque, conn_handle: u16, cccd_handle: u16) GattError!void,
    unsubscribe: *const fn (ptr: *anyopaque, conn_handle: u16, cccd_handle: u16) GattError!void,
    getAttMtu: *const fn (ptr: *anyopaque, conn_handle: u16) u16,
    getState: *const fn (ptr: *anyopaque) State,
    addEventHook: *const fn (ptr: *anyopaque, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, CentralEvent) void) void,
    removeEventHook: *const fn (ptr: *anyopaque, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, CentralEvent) void) void,
    getAddr: *const fn (ptr: *anyopaque) ?BdAddr,
    deinit: *const fn (ptr: *anyopaque) void,
};

// -- lifecycle --

pub fn start(self: Central) StartError!void {
    return self.vtable.start(self.ptr);
}

pub fn stop(self: Central) void {
    self.vtable.stop(self.ptr);
}

pub fn deinit(self: Central) void {
    self.vtable.deinit(self.ptr);
}

// -- scan --

pub fn startScanning(self: Central, config: ScanConfig) ScanError!void {
    return self.vtable.startScanning(self.ptr, config);
}

pub fn stopScanning(self: Central) void {
    self.vtable.stopScanning(self.ptr);
}

// -- connect --

pub fn connect(self: Central, addr: BdAddr, addr_type: AddrType, params: ConnParams) ConnectError!ConnectionInfo {
    return self.vtable.connect(self.ptr, addr, addr_type, params);
}

pub fn disconnect(self: Central, conn_handle: u16) void {
    self.vtable.disconnect(self.ptr, conn_handle);
}

// -- GATT --

pub fn discoverServices(self: Central, conn_handle: u16, out: []DiscoveredService) GattError!usize {
    return self.vtable.discoverServices(self.ptr, conn_handle, out);
}

pub fn discoverChars(self: Central, conn_handle: u16, start_handle: u16, end_handle: u16, out: []DiscoveredChar) GattError!usize {
    return self.vtable.discoverChars(self.ptr, conn_handle, start_handle, end_handle, out);
}

pub fn gattRead(self: Central, conn_handle: u16, attr_handle: u16, out: []u8) GattError!usize {
    return self.vtable.gattRead(self.ptr, conn_handle, attr_handle, out);
}

pub fn gattWrite(self: Central, conn_handle: u16, attr_handle: u16, data: []const u8) GattError!void {
    return self.vtable.gattWrite(self.ptr, conn_handle, attr_handle, data);
}

pub fn gattWriteNoResp(self: Central, conn_handle: u16, attr_handle: u16, data: []const u8) GattError!void {
    return self.vtable.gattWriteNoResp(self.ptr, conn_handle, attr_handle, data);
}

pub fn exchangeMtu(self: Central, conn_handle: u16, mtu: u16) GattError!u16 {
    return self.vtable.exchangeMtu(self.ptr, conn_handle, mtu);
}

pub fn subscribe(self: Central, conn_handle: u16, cccd_handle: u16) GattError!void {
    return self.vtable.subscribe(self.ptr, conn_handle, cccd_handle);
}

pub fn subscribeIndications(self: Central, conn_handle: u16, cccd_handle: u16) GattError!void {
    return self.vtable.subscribeIndications(self.ptr, conn_handle, cccd_handle);
}

pub fn unsubscribe(self: Central, conn_handle: u16, cccd_handle: u16) GattError!void {
    return self.vtable.unsubscribe(self.ptr, conn_handle, cccd_handle);
}

pub fn getAttMtu(self: Central, conn_handle: u16) u16 {
    return self.vtable.getAttMtu(self.ptr, conn_handle);
}

pub fn resolveChar(self: Central, conn_handle: u16, svc_uuid: u16, char_uuid: u16) GattError!DiscoveredChar {
    var services: [16]DiscoveredService = undefined;
    const svc_count = try self.discoverServices(conn_handle, &services);

    var service: ?DiscoveredService = null;
    for (services[0..svc_count]) |svc| {
        if (svc.uuid == svc_uuid) {
            service = svc;
            break;
        }
    }
    if (service == null and svc_count == services.len) return error.AttError;
    const found_service = service orelse return error.AttError;

    var chars: [16]DiscoveredChar = undefined;
    const char_count = try self.discoverChars(conn_handle, found_service.start_handle, found_service.end_handle, &chars);
    for (chars[0..char_count]) |ch| {
        if (ch.uuid == char_uuid) return ch;
    }
    if (char_count == chars.len) return error.AttError;
    return error.AttError;
}

// -- state & info --

pub fn getState(self: Central) State {
    return self.vtable.getState(self.ptr);
}

pub fn getAddr(self: Central) ?BdAddr {
    return self.vtable.getAddr(self.ptr);
}

// -- events --

pub fn addEventHook(self: Central, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, CentralEvent) void) void {
    self.vtable.addEventHook(self.ptr, ctx, cb);
}

pub fn removeEventHook(self: Central, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, CentralEvent) void) void {
    self.vtable.removeEventHook(self.ptr, ctx, cb);
}

/// Wrap a pointer to any concrete Central implementation into a Central.
pub fn wrap(pointer: anytype) Central {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Central.wrap expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn startFn(ptr: *anyopaque) StartError!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.start();
        }
        fn stopFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.stop();
        }
        fn startScanningFn(ptr: *anyopaque, config: ScanConfig) ScanError!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.startScanning(config);
        }
        fn stopScanningFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.stopScanning();
        }
        fn connectFn(ptr: *anyopaque, addr: BdAddr, addr_type: AddrType, params: ConnParams) ConnectError!ConnectionInfo {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.connect(addr, addr_type, params);
        }
        fn disconnectFn(ptr: *anyopaque, conn_handle: u16) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.disconnect(conn_handle);
        }
        fn discoverServicesFn(ptr: *anyopaque, conn_handle: u16, out: []DiscoveredService) GattError!usize {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.discoverServices(conn_handle, out);
        }
        fn discoverCharsFn(ptr: *anyopaque, conn_handle: u16, start_handle: u16, end_handle: u16, out: []DiscoveredChar) GattError!usize {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.discoverChars(conn_handle, start_handle, end_handle, out);
        }
        fn gattReadFn(ptr: *anyopaque, conn_handle: u16, attr_handle: u16, out: []u8) GattError!usize {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.gattRead(conn_handle, attr_handle, out);
        }
        fn gattWriteFn(ptr: *anyopaque, conn_handle: u16, attr_handle: u16, data: []const u8) GattError!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.gattWrite(conn_handle, attr_handle, data);
        }
        fn gattWriteNoRespFn(ptr: *anyopaque, conn_handle: u16, attr_handle: u16, data: []const u8) GattError!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            if (@hasDecl(Impl, "gattWriteNoResp")) {
                return self.gattWriteNoResp(conn_handle, attr_handle, data);
            }
            return error.Unexpected;
        }
        fn exchangeMtuFn(ptr: *anyopaque, conn_handle: u16, mtu: u16) GattError!u16 {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            if (@hasDecl(Impl, "exchangeMtu")) {
                return self.exchangeMtu(conn_handle, mtu);
            }
            return error.Unexpected;
        }
        fn subscribeFn(ptr: *anyopaque, conn_handle: u16, cccd_handle: u16) GattError!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.subscribe(conn_handle, cccd_handle);
        }
        fn subscribeIndicationsFn(ptr: *anyopaque, conn_handle: u16, cccd_handle: u16) GattError!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            if (@hasDecl(Impl, "subscribeIndications")) {
                return self.subscribeIndications(conn_handle, cccd_handle);
            }
            return error.Unexpected;
        }
        fn unsubscribeFn(ptr: *anyopaque, conn_handle: u16, cccd_handle: u16) GattError!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.unsubscribe(conn_handle, cccd_handle);
        }
        fn getAttMtuFn(ptr: *anyopaque, conn_handle: u16) u16 {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            if (@hasDecl(Impl, "getAttMtu")) {
                return self.getAttMtu(conn_handle);
            }
            return DEFAULT_ATT_MTU;
        }
        fn getStateFn(ptr: *anyopaque) State {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.getState();
        }
        fn addEventHookFn(ptr: *anyopaque, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, CentralEvent) void) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.addEventHook(ctx, cb);
        }
        fn removeEventHookFn(ptr: *anyopaque, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, CentralEvent) void) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            if (@hasDecl(Impl, "removeEventHook")) {
                self.removeEventHook(ctx, cb);
            }
        }
        fn getAddrFn(ptr: *anyopaque) ?BdAddr {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.getAddr();
        }
        fn deinitFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.deinit();
        }

        const vtable = VTable{
            .start = startFn,
            .stop = stopFn,
            .startScanning = startScanningFn,
            .stopScanning = stopScanningFn,
            .connect = connectFn,
            .disconnect = disconnectFn,
            .discoverServices = discoverServicesFn,
            .discoverChars = discoverCharsFn,
            .gattRead = gattReadFn,
            .gattWrite = gattWriteFn,
            .gattWriteNoResp = gattWriteNoRespFn,
            .exchangeMtu = exchangeMtuFn,
            .subscribe = subscribeFn,
            .subscribeIndications = subscribeIndicationsFn,
            .unsubscribe = unsubscribeFn,
            .getAttMtu = getAttMtuFn,
            .getState = getStateFn,
            .addEventHook = addEventHookFn,
            .removeEventHook = removeEventHookFn,
            .getAddr = getAddrFn,
            .deinit = deinitFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}

test "bt/unit_tests/Central_wrap_does_not_silently_downgrade_optional_gatt_ops" {
    const Impl = struct {
        pub fn start(_: *@This()) StartError!void {}
        pub fn stop(_: *@This()) void {}
        pub fn startScanning(_: *@This(), _: ScanConfig) ScanError!void {}
        pub fn stopScanning(_: *@This()) void {}
        pub fn connect(_: *@This(), _: BdAddr, _: AddrType, _: ConnParams) ConnectError!ConnectionInfo {
            return error.Rejected;
        }
        pub fn disconnect(_: *@This(), _: u16) void {}
        pub fn discoverServices(_: *@This(), _: u16, _: []DiscoveredService) GattError!usize {
            return 0;
        }
        pub fn discoverChars(_: *@This(), _: u16, _: u16, _: u16, _: []DiscoveredChar) GattError!usize {
            return 0;
        }
        pub fn gattRead(_: *@This(), _: u16, _: u16, _: []u8) GattError!usize {
            return 0;
        }
        pub fn gattWrite(_: *@This(), _: u16, _: u16, _: []const u8) GattError!void {}
        pub fn subscribe(_: *@This(), _: u16, _: u16) GattError!void {}
        pub fn unsubscribe(_: *@This(), _: u16, _: u16) GattError!void {}
        pub fn getState(_: *@This()) State {
            return .idle;
        }
        pub fn addEventHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, CentralEvent) void) void {}
        pub fn getAddr(_: *@This()) ?BdAddr {
            return null;
        }
        pub fn deinit(_: *@This()) void {}
    };

    var impl = Impl{};
    const central = wrap(&impl);

    try @import("std").testing.expectError(error.Unexpected, central.gattWriteNoResp(1, 2, "x"));
    try @import("std").testing.expectError(error.Unexpected, central.exchangeMtu(1, MAX_ATT_MTU));
    try @import("std").testing.expectError(error.Unexpected, central.subscribeIndications(1, 2));
    try @import("std").testing.expectEqual(DEFAULT_ATT_MTU, central.getAttMtu(1));
}
