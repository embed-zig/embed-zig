//! Hci — type-erased controller-facing HCI coordinator interface.
//!
//! This sits between raw `Transport` and higher-level `Central` /
//! `Peripheral` host contracts.
//!
//! Responsibilities at this layer:
//! - shared controller lifecycle for one Central + one Peripheral
//! - GAP procedures (scan / advertise / connect / disconnect)
//! - ACL / ATT request transport
//! - event fan-out to Central-side and Peripheral-side listeners
//!
//! Higher-level concepts such as Conn / Char / Subscription / Handler
//! should be built on top of `Central` / `Peripheral`, not directly on Hci.

const glib = @import("glib");

const Hci = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const BdAddr = [6]u8;

pub const AddrType = enum {
    public,
    random,
};

pub const Role = enum {
    central,
    peripheral,
};

pub const ScanConfig = struct {
    active: bool = true,
    /// Raw controller scan interval units as expected by the concrete HCI backend.
    interval: u16 = 0x0010,
    /// Raw controller scan window units as expected by the concrete HCI backend.
    window: u16 = 0x0010,
    filter_duplicates: bool = true,
};

pub const AdvConfig = struct {
    interval_min: u16 = 0x0800,
    interval_max: u16 = 0x0800,
    connectable: bool = true,
    adv_data: []const u8 = &.{},
    scan_rsp_data: []const u8 = &.{},
};

pub const ConnConfig = struct {
    scan_interval: u16 = 0x0060,
    scan_window: u16 = 0x0030,
    interval_min: u16 = 0x0018,
    interval_max: u16 = 0x0028,
    latency: u16 = 0,
    supervision_timeout: glib.time.duration.Duration = 2 * glib.time.duration.Second,
};

pub const Link = struct {
    role: Role,
    conn_handle: u16,
    peer_addr: BdAddr,
    peer_addr_type: AddrType,
    interval: u16,
    latency: u16,
    supervision_timeout: glib.time.duration.Duration,
};

pub const Error = error{
    Busy,
    Timeout,
    Rejected,
    Disconnected,
    HwError,
    Unexpected,
};

pub const AdvReportFn = *const fn (?*anyopaque, []const u8) void;
pub const ConnectedFn = *const fn (?*anyopaque, Link) void;
pub const DisconnectedFn = *const fn (?*anyopaque, u16, u8) void;
pub const NotificationFn = *const fn (?*anyopaque, u16, u16, []const u8) void;
/// Handle one inbound ATT request and return the number of response bytes written into `out`.
/// The returned length must be less than or equal to `out.len`.
pub const AttRequestFn = *const fn (?*anyopaque, u16, []const u8, []u8) usize;

pub const CentralListener = struct {
    ctx: ?*anyopaque = null,
    on_adv_report: ?AdvReportFn = null,
    on_connected: ?ConnectedFn = null,
    on_disconnected: ?DisconnectedFn = null,
    on_notification: ?NotificationFn = null,
};

pub const PeripheralListener = struct {
    ctx: ?*anyopaque = null,
    on_connected: ?ConnectedFn = null,
    on_disconnected: ?DisconnectedFn = null,
    on_att_request: ?AttRequestFn = null,
};

pub const VTable = struct {
    retain: *const fn (ptr: *anyopaque) Error!void,
    release: *const fn (ptr: *anyopaque) void,
    setCentralListener: *const fn (ptr: *anyopaque, listener: CentralListener) void,
    setPeripheralListener: *const fn (ptr: *anyopaque, listener: PeripheralListener) void,
    startScanning: *const fn (ptr: *anyopaque, config: ScanConfig) Error!void,
    stopScanning: *const fn (ptr: *anyopaque) void,
    startAdvertising: *const fn (ptr: *anyopaque, config: AdvConfig) Error!void,
    stopAdvertising: *const fn (ptr: *anyopaque) void,
    connect: *const fn (ptr: *anyopaque, addr: BdAddr, addr_type: AddrType, config: ConnConfig) Error!void,
    cancelConnect: *const fn (ptr: *anyopaque) void,
    disconnect: *const fn (ptr: *anyopaque, conn_handle: u16, reason: u8) void,
    sendAcl: *const fn (ptr: *anyopaque, conn_handle: u16, data: []const u8) Error!void,
    sendAttRequest: *const fn (ptr: *anyopaque, conn_handle: u16, req: []const u8, out: []u8) Error!usize,
    getAddr: *const fn (ptr: *anyopaque) ?BdAddr,
    getLink: *const fn (ptr: *anyopaque, role: Role) ?Link,
    getLinkByHandle: *const fn (ptr: *anyopaque, conn_handle: u16) ?Link,
    isScanning: *const fn (ptr: *anyopaque) bool,
    isAdvertising: *const fn (ptr: *anyopaque) bool,
    isConnectingCentral: *const fn (ptr: *anyopaque) bool,
    deinit: *const fn (ptr: *anyopaque) void,
};

pub fn retain(self: Hci) Error!void {
    return self.vtable.retain(self.ptr);
}

pub fn release(self: Hci) void {
    self.vtable.release(self.ptr);
}

pub fn setCentralListener(self: Hci, listener: CentralListener) void {
    self.vtable.setCentralListener(self.ptr, listener);
}

pub fn setPeripheralListener(self: Hci, listener: PeripheralListener) void {
    self.vtable.setPeripheralListener(self.ptr, listener);
}

pub fn startScanning(self: Hci, config: ScanConfig) Error!void {
    return self.vtable.startScanning(self.ptr, config);
}

pub fn stopScanning(self: Hci) void {
    self.vtable.stopScanning(self.ptr);
}

pub fn startAdvertising(self: Hci, config: AdvConfig) Error!void {
    return self.vtable.startAdvertising(self.ptr, config);
}

pub fn stopAdvertising(self: Hci) void {
    self.vtable.stopAdvertising(self.ptr);
}

pub fn connect(self: Hci, addr: BdAddr, addr_type: AddrType, config: ConnConfig) Error!void {
    return self.vtable.connect(self.ptr, addr, addr_type, config);
}

pub fn cancelConnect(self: Hci) void {
    self.vtable.cancelConnect(self.ptr);
}

pub fn disconnect(self: Hci, conn_handle: u16, reason: u8) void {
    self.vtable.disconnect(self.ptr, conn_handle, reason);
}

pub fn sendAcl(self: Hci, conn_handle: u16, data: []const u8) Error!void {
    return self.vtable.sendAcl(self.ptr, conn_handle, data);
}

/// Sends one ATT request and copies the response into `out`.
///
/// Returns the number of response bytes copied into `out`.
pub fn sendAttRequest(self: Hci, conn_handle: u16, req: []const u8, out: []u8) Error!usize {
    return self.vtable.sendAttRequest(self.ptr, conn_handle, req, out);
}

pub fn getAddr(self: Hci) ?BdAddr {
    return self.vtable.getAddr(self.ptr);
}

pub fn getLink(self: Hci, role: Role) ?Link {
    return self.vtable.getLink(self.ptr, role);
}

pub fn getLinkByHandle(self: Hci, conn_handle: u16) ?Link {
    return self.vtable.getLinkByHandle(self.ptr, conn_handle);
}

pub fn isScanning(self: Hci) bool {
    return self.vtable.isScanning(self.ptr);
}

pub fn isAdvertising(self: Hci) bool {
    return self.vtable.isAdvertising(self.ptr);
}

pub fn isConnectingCentral(self: Hci) bool {
    return self.vtable.isConnectingCentral(self.ptr);
}

pub fn deinit(self: Hci) void {
    self.vtable.deinit(self.ptr);
}

/// Make a type-erased Hci from a concrete implementation pointer.
pub fn make(pointer: anytype) Hci {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Hci.make expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn retainFn(ptr: *anyopaque) Error!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.retain();
        }

        fn releaseFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.release();
        }

        fn setCentralListenerFn(ptr: *anyopaque, listener: CentralListener) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.setCentralListener(listener);
        }

        fn setPeripheralListenerFn(ptr: *anyopaque, listener: PeripheralListener) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.setPeripheralListener(listener);
        }

        fn startScanningFn(ptr: *anyopaque, config: ScanConfig) Error!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.startScanning(config);
        }

        fn stopScanningFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.stopScanning();
        }

        fn startAdvertisingFn(ptr: *anyopaque, config: AdvConfig) Error!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.startAdvertising(config);
        }

        fn stopAdvertisingFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.stopAdvertising();
        }

        fn connectFn(ptr: *anyopaque, addr: BdAddr, addr_type: AddrType, config: ConnConfig) Error!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.connect(addr, addr_type, config);
        }

        fn cancelConnectFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.cancelConnect();
        }

        fn disconnectFn(ptr: *anyopaque, conn_handle: u16, reason: u8) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.disconnect(conn_handle, reason);
        }

        fn sendAclFn(ptr: *anyopaque, conn_handle: u16, data: []const u8) Error!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.sendAcl(conn_handle, data);
        }

        fn sendAttRequestFn(ptr: *anyopaque, conn_handle: u16, req: []const u8, out: []u8) Error!usize {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.sendAttRequest(conn_handle, req, out);
        }

        fn getAddrFn(ptr: *anyopaque) ?BdAddr {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.getAddr();
        }

        fn getLinkFn(ptr: *anyopaque, role: Role) ?Link {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.getLink(role);
        }

        fn getLinkByHandleFn(ptr: *anyopaque, conn_handle: u16) ?Link {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.getLinkByHandle(conn_handle);
        }

        fn isScanningFn(ptr: *anyopaque) bool {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.isScanning();
        }

        fn isAdvertisingFn(ptr: *anyopaque) bool {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.isAdvertising();
        }

        fn isConnectingCentralFn(ptr: *anyopaque) bool {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.isConnectingCentral();
        }

        fn deinitFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.deinit();
        }

        const vtable = VTable{
            .retain = retainFn,
            .release = releaseFn,
            .setCentralListener = setCentralListenerFn,
            .setPeripheralListener = setPeripheralListenerFn,
            .startScanning = startScanningFn,
            .stopScanning = stopScanningFn,
            .startAdvertising = startAdvertisingFn,
            .stopAdvertising = stopAdvertisingFn,
            .connect = connectFn,
            .cancelConnect = cancelConnectFn,
            .disconnect = disconnectFn,
            .sendAcl = sendAclFn,
            .sendAttRequest = sendAttRequestFn,
            .getAddr = getAddrFn,
            .getLink = getLinkFn,
            .getLinkByHandle = getLinkByHandleFn,
            .isScanning = isScanningFn,
            .isAdvertising = isAdvertisingFn,
            .isConnectingCentral = isConnectingCentralFn,
            .deinit = deinitFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn run() !void {
            const Impl = struct {
                retained: bool = false,
                scanning: bool = false,
                advertising: bool = false,
                connecting: bool = false,
                addr: BdAddr = .{ 1, 2, 3, 4, 5, 6 },
                central_listener: CentralListener = .{},
                peripheral_listener: PeripheralListener = .{},
                link: ?Link = null,

                pub fn retain(self: *@This()) Error!void {
                    self.retained = true;
                }
                pub fn release(_: *@This()) void {}
                pub fn setCentralListener(self: *@This(), listener: CentralListener) void {
                    self.central_listener = listener;
                }
                pub fn setPeripheralListener(self: *@This(), listener: PeripheralListener) void {
                    self.peripheral_listener = listener;
                }
                pub fn startScanning(self: *@This(), _: ScanConfig) Error!void {
                    self.scanning = true;
                }
                pub fn stopScanning(self: *@This()) void {
                    self.scanning = false;
                }
                pub fn startAdvertising(self: *@This(), _: AdvConfig) Error!void {
                    self.advertising = true;
                }
                pub fn stopAdvertising(self: *@This()) void {
                    self.advertising = false;
                }
                pub fn connect(self: *@This(), addr: BdAddr, addr_type: AddrType, config: ConnConfig) Error!void {
                    self.connecting = false;
                    self.link = .{
                        .role = .central,
                        .conn_handle = 0x0040,
                        .peer_addr = addr,
                        .peer_addr_type = addr_type,
                        .interval = config.interval_min,
                        .latency = config.latency,
                        .supervision_timeout = config.supervision_timeout,
                    };
                }
                pub fn cancelConnect(self: *@This()) void {
                    self.connecting = false;
                }
                pub fn disconnect(self: *@This(), _: u16, _: u8) void {
                    self.link = null;
                }
                pub fn sendAcl(_: *@This(), _: u16, _: []const u8) Error!void {}
                pub fn sendAttRequest(_: *@This(), _: u16, _: []const u8, out: []u8) Error!usize {
                    if (out.len < 2) return error.Unexpected;
                    out[0] = 0xAA;
                    out[1] = 0x55;
                    return 2;
                }
                pub fn getAddr(self: *@This()) ?BdAddr {
                    return self.addr;
                }
                pub fn getLink(self: *@This(), _: Role) ?Link {
                    return self.link;
                }
                pub fn getLinkByHandle(self: *@This(), conn_handle: u16) ?Link {
                    if (self.link) |link| {
                        if (link.conn_handle == conn_handle) return link;
                    }
                    return null;
                }
                pub fn isScanning(self: *@This()) bool {
                    return self.scanning;
                }
                pub fn isAdvertising(self: *@This()) bool {
                    return self.advertising;
                }
                pub fn isConnectingCentral(self: *@This()) bool {
                    return self.connecting;
                }
                pub fn deinit(_: *@This()) void {}
            };

            var impl = Impl{};
            const hci = make(&impl);

            try hci.retain();
            try grt.std.testing.expect(impl.retained);

            hci.setCentralListener(.{});
            hci.setPeripheralListener(.{});

            try hci.startScanning(.{});
            try grt.std.testing.expect(hci.isScanning());
            hci.stopScanning();

            try hci.startAdvertising(.{});
            try grt.std.testing.expect(hci.isAdvertising());
            hci.stopAdvertising();

            try hci.connect(.{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF }, .public, .{});
            const link = hci.getLink(.central) orelse return error.NoLink;
            try grt.std.testing.expectEqual(@as(u16, 0x0040), link.conn_handle);
            try grt.std.testing.expectEqual(@as(?BdAddr, .{ 1, 2, 3, 4, 5, 6 }), hci.getAddr());

            var resp: [8]u8 = undefined;
            const n = try hci.sendAttRequest(0x0040, &.{0x01}, &resp);
            try grt.std.testing.expectEqual(@as(usize, 2), n);
            try grt.std.testing.expectEqual(@as(u8, 0xAA), resp[0]);
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

            TestCase.run() catch |err| {
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
