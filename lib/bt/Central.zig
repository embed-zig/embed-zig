//! Central — type-erased BLE Central interface (like net.Conn for byte streams).
//!
//! VTable-based runtime dispatch. Any concrete Central implementation
//! (HCI host stack, CoreBluetooth, Android BLE) can be wrapped into a Central.
//!
//! Application code programs against this interface and is portable
//! across all backends.
//!
//! Usage:
//!   var central = try cb.Central(.{}).init(allocator);
//!   try central.start();
//!   try central.startScanning(.{ .active = true });

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
    interval_ms: u16 = 10,
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

pub const NotificationData = struct {
    conn_handle: u16,
    attr_handle: u16,
    data: [247]u8 = undefined,
    len: u8 = 0,

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
    connect: *const fn (ptr: *anyopaque, addr: BdAddr, addr_type: AddrType, params: ConnParams) ConnectError!void,
    disconnect: *const fn (ptr: *anyopaque, conn_handle: u16) void,
    discoverServices: *const fn (ptr: *anyopaque, conn_handle: u16, out: []DiscoveredService) GattError!usize,
    discoverChars: *const fn (ptr: *anyopaque, conn_handle: u16, start_handle: u16, end: u16, out: []DiscoveredChar) GattError!usize,
    gattRead: *const fn (ptr: *anyopaque, conn_handle: u16, attr_handle: u16, out: []u8) GattError!usize,
    gattWrite: *const fn (ptr: *anyopaque, conn_handle: u16, attr_handle: u16, data: []const u8) GattError!void,
    subscribe: *const fn (ptr: *anyopaque, conn_handle: u16, cccd_handle: u16) GattError!void,
    unsubscribe: *const fn (ptr: *anyopaque, conn_handle: u16, cccd_handle: u16) GattError!void,
    getState: *const fn (ptr: *anyopaque) State,
    addEventHook: *const fn (ptr: *anyopaque, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, CentralEvent) void) void,
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

pub fn connect(self: Central, addr: BdAddr, addr_type: AddrType, params: ConnParams) ConnectError!void {
    return self.vtable.connect(self.ptr, addr, addr_type, params);
}

pub fn disconnect(self: Central, conn_handle: u16) void {
    self.vtable.disconnect(self.ptr, conn_handle);
}

// -- discovery --

pub fn discoverServices(self: Central, conn_handle: u16, out: []DiscoveredService) GattError!usize {
    return self.vtable.discoverServices(self.ptr, conn_handle, out);
}

pub fn discoverChars(self: Central, conn_handle: u16, start_handle: u16, end_handle: u16, out: []DiscoveredChar) GattError!usize {
    return self.vtable.discoverChars(self.ptr, conn_handle, start_handle, end_handle, out);
}

// -- GATT client --

pub fn gattRead(self: Central, conn_handle: u16, attr_handle: u16, out: []u8) GattError!usize {
    return self.vtable.gattRead(self.ptr, conn_handle, attr_handle, out);
}

pub fn gattWrite(self: Central, conn_handle: u16, attr_handle: u16, data: []const u8) GattError!void {
    return self.vtable.gattWrite(self.ptr, conn_handle, attr_handle, data);
}

pub fn subscribe(self: Central, conn_handle: u16, cccd_handle: u16) GattError!void {
    return self.vtable.subscribe(self.ptr, conn_handle, cccd_handle);
}

pub fn unsubscribe(self: Central, conn_handle: u16, cccd_handle: u16) GattError!void {
    return self.vtable.unsubscribe(self.ptr, conn_handle, cccd_handle);
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

/// Wrap a pointer to any concrete Central implementation into a Central.
pub fn wrap(pointer: anytype) Central {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Central.init expects a single-item pointer");

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
        fn connectFn(ptr: *anyopaque, addr: BdAddr, addr_type: AddrType, params: ConnParams) ConnectError!void {
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
        fn subscribeFn(ptr: *anyopaque, conn_handle: u16, cccd_handle: u16) GattError!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.subscribe(conn_handle, cccd_handle);
        }
        fn unsubscribeFn(ptr: *anyopaque, conn_handle: u16, cccd_handle: u16) GattError!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.unsubscribe(conn_handle, cccd_handle);
        }
        fn getStateFn(ptr: *anyopaque) State {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.getState();
        }
        fn addEventHookFn(ptr: *anyopaque, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, CentralEvent) void) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.addEventHook(ctx, cb);
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
            .subscribe = subscribeFn,
            .unsubscribe = unsubscribeFn,
            .getState = getStateFn,
            .addEventHook = addEventHookFn,
            .getAddr = getAddrFn,
            .deinit = deinitFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}
