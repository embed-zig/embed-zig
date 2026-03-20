//! Peripheral — type-erased BLE Peripheral interface (like net.Conn for byte streams).
//!
//! VTable-based runtime dispatch. Any concrete Peripheral implementation
//! (HCI host stack, CoreBluetooth, Android BLE) can be wrapped into a Peripheral.
//!
//! Design follows the http.ServeMux pattern:
//!
//!   | HTTP                | BLE Peripheral                       |
//!   |---------------------|--------------------------------------|
//!   | ListenAndServe      | startAdvertising                     |
//!   | HandleFunc(path,fn) | handle(svc_uuid, char_uuid, fn, ctx) |
//!   | http.Request        | Request (op, conn, data)             |
//!   | http.ResponseWriter | ResponseWriter (write, ok, err)      |
//!   | Shutdown            | stopAdvertising                      |
//!   | Server Push / SSE   | notify / indicate                    |
//!
//! Usage:
//!   var peripheral = try cb.Peripheral(.{}).init(allocator);
//!   try peripheral.start();
//!   peripheral.handle(0x180D, 0x2A37, myHandler, null);
//!   try peripheral.startAdvertising(.{ .device_name = "Zig" });

const Peripheral = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const BdAddr = [6]u8;

pub const AddrType = enum {
    public,
    random,
};

pub const State = enum {
    idle,
    advertising,
    connected,
};

pub const AdvConfig = struct {
    device_name: []const u8 = "",
    service_uuids: []const u16 = &.{},
    interval_min: u16 = 0x0800,
    interval_max: u16 = 0x0800,
    connectable: bool = true,
    adv_data: []const u8 = &.{},
    scan_rsp_data: []const u8 = &.{},
};

pub const Operation = enum {
    read,
    write,
    write_command,
};

pub const Request = struct {
    op: Operation,
    conn_handle: u16,
    service_uuid: u16,
    char_uuid: u16,
    data: []const u8,
    user_ctx: ?*anyopaque,
};

pub const ResponseWriter = struct {
    _impl: *anyopaque,
    _write_fn: *const fn (*anyopaque, []const u8) void,
    _ok_fn: *const fn (*anyopaque) void,
    _err_fn: *const fn (*anyopaque, u8) void,

    pub fn write(self: *ResponseWriter, data: []const u8) void {
        self._write_fn(self._impl, data);
    }

    pub fn ok(self: *ResponseWriter) void {
        self._ok_fn(self._impl);
    }

    pub fn err(self: *ResponseWriter, code: u8) void {
        self._err_fn(self._impl, code);
    }
};

pub const HandlerFn = *const fn (*Request, *ResponseWriter) void;

pub const ConnectionInfo = struct {
    conn_handle: u16,
    peer_addr: BdAddr,
    peer_addr_type: AddrType,
    interval: u16,
    latency: u16,
    timeout: u16,
};

pub const MtuInfo = struct {
    conn_handle: u16,
    mtu: u16,
};

pub const PeripheralEvent = union(enum) {
    connected: ConnectionInfo,
    disconnected: u16,
    advertising_started: void,
    advertising_stopped: void,
    mtu_changed: MtuInfo,
};

pub const StartError = error{
    BluetoothUnavailable,
    Unexpected,
};

pub const AdvError = error{
    InvalidConfig,
    AlreadyAdvertising,
    Unexpected,
};

pub const GattError = error{
    InvalidHandle,
    NotConnected,
    Unexpected,
};

pub const VTable = struct {
    start: *const fn (ptr: *anyopaque) StartError!void,
    stop: *const fn (ptr: *anyopaque) void,
    startAdvertising: *const fn (ptr: *anyopaque, config: AdvConfig) AdvError!void,
    stopAdvertising: *const fn (ptr: *anyopaque) void,
    handle: *const fn (ptr: *anyopaque, svc_uuid: u16, char_uuid: u16, HandlerFn, ctx: ?*anyopaque) void,
    notify: *const fn (ptr: *anyopaque, conn_handle: u16, char_uuid: u16, data: []const u8) GattError!void,
    indicate: *const fn (ptr: *anyopaque, conn_handle: u16, char_uuid: u16, data: []const u8) GattError!void,
    disconnect: *const fn (ptr: *anyopaque, conn_handle: u16) void,
    getState: *const fn (ptr: *anyopaque) State,
    addEventHook: *const fn (ptr: *anyopaque, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, PeripheralEvent) void) void,
    getAddr: *const fn (ptr: *anyopaque) ?BdAddr,
    deinit: *const fn (ptr: *anyopaque) void,
};

// -- lifecycle --

pub fn start(self: Peripheral) StartError!void {
    return self.vtable.start(self.ptr);
}

pub fn stop(self: Peripheral) void {
    self.vtable.stop(self.ptr);
}

pub fn deinit(self: Peripheral) void {
    self.vtable.deinit(self.ptr);
}

// -- advertising --

pub fn startAdvertising(self: Peripheral, config: AdvConfig) AdvError!void {
    return self.vtable.startAdvertising(self.ptr, config);
}

pub fn stopAdvertising(self: Peripheral) void {
    self.vtable.stopAdvertising(self.ptr);
}

// -- handler registration --

pub fn handle(self: Peripheral, svc_uuid: u16, char_uuid: u16, func: HandlerFn, ctx: ?*anyopaque) void {
    self.vtable.handle(self.ptr, svc_uuid, char_uuid, func, ctx);
}

// -- server push --

pub fn notify(self: Peripheral, conn_handle: u16, char_uuid: u16, data: []const u8) GattError!void {
    return self.vtable.notify(self.ptr, conn_handle, char_uuid, data);
}

pub fn indicate(self: Peripheral, conn_handle: u16, char_uuid: u16, data: []const u8) GattError!void {
    return self.vtable.indicate(self.ptr, conn_handle, char_uuid, data);
}

// -- connection --

pub fn disconnect(self: Peripheral, conn_handle: u16) void {
    self.vtable.disconnect(self.ptr, conn_handle);
}

// -- state & info --

pub fn getState(self: Peripheral) State {
    return self.vtable.getState(self.ptr);
}

pub fn getAddr(self: Peripheral) ?BdAddr {
    return self.vtable.getAddr(self.ptr);
}

// -- events --

pub fn addEventHook(self: Peripheral, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, PeripheralEvent) void) void {
    self.vtable.addEventHook(self.ptr, ctx, cb);
}

/// Wrap a pointer to any concrete Peripheral implementation into a Peripheral.
pub fn wrap(pointer: anytype) Peripheral {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Peripheral.init expects a single-item pointer");

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
        fn startAdvertisingFn(ptr: *anyopaque, config: AdvConfig) AdvError!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.startAdvertising(config);
        }
        fn stopAdvertisingFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.stopAdvertising();
        }
        fn handleFn(ptr: *anyopaque, svc_uuid: u16, char_uuid: u16, func: HandlerFn, ctx: ?*anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.handle(svc_uuid, char_uuid, func, ctx);
        }
        fn notifyFn(ptr: *anyopaque, conn_handle: u16, char_uuid: u16, data: []const u8) GattError!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.notify(conn_handle, char_uuid, data);
        }
        fn indicateFn(ptr: *anyopaque, conn_handle: u16, char_uuid: u16, data: []const u8) GattError!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.indicate(conn_handle, char_uuid, data);
        }
        fn disconnectFn(ptr: *anyopaque, conn_handle: u16) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.disconnect(conn_handle);
        }
        fn getStateFn(ptr: *anyopaque) State {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.getState();
        }
        fn addEventHookFn(ptr: *anyopaque, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, PeripheralEvent) void) void {
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
            .startAdvertising = startAdvertisingFn,
            .stopAdvertising = stopAdvertisingFn,
            .handle = handleFn,
            .notify = notifyFn,
            .indicate = indicateFn,
            .disconnect = disconnectFn,
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
