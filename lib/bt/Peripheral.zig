//! Peripheral — type-erased low-level BLE Peripheral interface.
//!
//! This is the backend-facing VTable surface. It exposes advertising,
//! GATT database configuration, a raw request callback, and server-push
//! primitives.
//! Higher-level request/handler abstractions should be built on top of
//! this low-level interface rather than encoded directly in the VTable.

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

pub const CharConfig = struct {
    read: bool = false,
    write: bool = false,
    write_without_response: bool = false,
    notify: bool = false,
    indicate: bool = false,

    pub fn default() CharConfig {
        return .{
            .read = true,
            .write = true,
            .write_without_response = true,
            .notify = true,
            .indicate = true,
        };
    }

    pub fn withRead(self: CharConfig) CharConfig {
        var cfg = self;
        cfg.read = true;
        return cfg;
    }

    pub fn withWrite(self: CharConfig) CharConfig {
        var cfg = self;
        cfg.write = true;
        return cfg;
    }

    pub fn withWriteWithoutResponse(self: CharConfig) CharConfig {
        var cfg = self;
        cfg.write_without_response = true;
        return cfg;
    }

    pub fn withNotify(self: CharConfig) CharConfig {
        var cfg = self;
        cfg.notify = true;
        return cfg;
    }

    pub fn withIndicate(self: CharConfig) CharConfig {
        var cfg = self;
        cfg.indicate = true;
        return cfg;
    }

    pub fn properties(self: CharConfig) u8 {
        var props: u8 = 0;
        if (self.read) props |= 0x02;
        if (self.write_without_response) props |= 0x04;
        if (self.write) props |= 0x08;
        if (self.notify) props |= 0x10;
        if (self.indicate) props |= 0x20;
        return props;
    }

    pub fn hasCccd(self: CharConfig) bool {
        return self.notify or self.indicate;
    }
};

pub const CharDef = struct {
    uuid: u16,
    config: CharConfig,
};

pub const ServiceDef = struct {
    uuid: u16,
    chars: []const CharDef,
};

pub const GattConfig = struct {
    services: []const ServiceDef = &.{},
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
    write_without_response,
};

pub const Request = struct {
    op: Operation,
    conn_handle: u16,
    service_uuid: u16,
    char_uuid: u16,
    data: []const u8,
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

pub const RequestHandlerFn = *const fn (?*anyopaque, *const Request, *ResponseWriter) void;

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

pub const SubscriptionInfo = struct {
    conn_handle: u16,
    service_uuid: u16,
    char_uuid: u16,
    cccd_value: u16,
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
    NotSubscribed,
    Unexpected,
};

pub fn Char(uuid: u16, cfg: CharConfig) CharDef {
    return .{ .uuid = uuid, .config = cfg };
}

pub fn Service(uuid: u16, chars: []const CharDef) ServiceDef {
    return .{ .uuid = uuid, .chars = chars };
}

pub const VTable = struct {
    start: *const fn (ptr: *anyopaque) StartError!void,
    stop: *const fn (ptr: *anyopaque) void,
    startAdvertising: *const fn (ptr: *anyopaque, config: AdvConfig) AdvError!void,
    stopAdvertising: *const fn (ptr: *anyopaque) void,
    setConfig: *const fn (ptr: *anyopaque, config: GattConfig) void,
    setRequestHandler: *const fn (ptr: *anyopaque, ctx: ?*anyopaque, cb: RequestHandlerFn) void,
    notify: *const fn (ptr: *anyopaque, conn_handle: u16, char_uuid: u16, data: []const u8) GattError!void,
    indicate: *const fn (ptr: *anyopaque, conn_handle: u16, char_uuid: u16, data: []const u8) GattError!void,
    disconnect: *const fn (ptr: *anyopaque, conn_handle: u16) void,
    getState: *const fn (ptr: *anyopaque) State,
    addEventHook: *const fn (ptr: *anyopaque, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, PeripheralEvent) void) void,
    addSubscriptionHook: *const fn (ptr: *anyopaque, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, SubscriptionInfo) void) void,
    getAddr: *const fn (ptr: *anyopaque) ?BdAddr,
    deinit: *const fn (ptr: *anyopaque) void,
};

pub fn start(self: Peripheral) StartError!void {
    return self.vtable.start(self.ptr);
}

pub fn stop(self: Peripheral) void {
    self.vtable.stop(self.ptr);
}

pub fn deinit(self: Peripheral) void {
    self.vtable.deinit(self.ptr);
}

pub fn startAdvertising(self: Peripheral, adv_config: AdvConfig) AdvError!void {
    return self.vtable.startAdvertising(self.ptr, adv_config);
}

pub fn stopAdvertising(self: Peripheral) void {
    self.vtable.stopAdvertising(self.ptr);
}

pub fn setConfig(self: Peripheral, config_value: GattConfig) void {
    self.vtable.setConfig(self.ptr, config_value);
}

pub fn setRequestHandler(self: Peripheral, ctx: ?*anyopaque, cb: RequestHandlerFn) void {
    self.vtable.setRequestHandler(self.ptr, ctx, cb);
}

pub fn notify(self: Peripheral, conn_handle: u16, char_uuid: u16, data: []const u8) GattError!void {
    return self.vtable.notify(self.ptr, conn_handle, char_uuid, data);
}

pub fn indicate(self: Peripheral, conn_handle: u16, char_uuid: u16, data: []const u8) GattError!void {
    return self.vtable.indicate(self.ptr, conn_handle, char_uuid, data);
}

pub fn disconnect(self: Peripheral, conn_handle: u16) void {
    self.vtable.disconnect(self.ptr, conn_handle);
}

pub fn getState(self: Peripheral) State {
    return self.vtable.getState(self.ptr);
}

pub fn getAddr(self: Peripheral) ?BdAddr {
    return self.vtable.getAddr(self.ptr);
}

pub fn addEventHook(self: Peripheral, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, PeripheralEvent) void) void {
    self.vtable.addEventHook(self.ptr, ctx, cb);
}

pub fn addSubscriptionHook(self: Peripheral, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, SubscriptionInfo) void) void {
    self.vtable.addSubscriptionHook(self.ptr, ctx, cb);
}

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

        fn startAdvertisingFn(ptr: *anyopaque, adv_config: AdvConfig) AdvError!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.startAdvertising(adv_config);
        }

        fn stopAdvertisingFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.stopAdvertising();
        }

        fn setConfigFn(ptr: *anyopaque, cfg: GattConfig) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.setConfig(cfg);
        }

        fn setRequestHandlerFn(ptr: *anyopaque, ctx: ?*anyopaque, cb: RequestHandlerFn) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.setRequestHandler(ctx, cb);
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

        fn addSubscriptionHookFn(ptr: *anyopaque, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, SubscriptionInfo) void) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            if (@hasDecl(Impl, "addSubscriptionHook")) {
                self.addSubscriptionHook(ctx, cb);
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
            .startAdvertising = startAdvertisingFn,
            .stopAdvertising = stopAdvertisingFn,
            .setConfig = setConfigFn,
            .setRequestHandler = setRequestHandlerFn,
            .notify = notifyFn,
            .indicate = indicateFn,
            .disconnect = disconnectFn,
            .getState = getStateFn,
            .addEventHook = addEventHookFn,
            .addSubscriptionHook = addSubscriptionHookFn,
            .getAddr = getAddrFn,
            .deinit = deinitFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}
