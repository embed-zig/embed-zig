//! wifi — portable Wi-Fi abstractions and helpers.

const net = @import("net");
const testing_api = @import("testing");

const root = @This();

pub const max_ssid_len: usize = 32;
pub const MacAddr = [6]u8;
pub const Addr = net.netip.Addr;

pub const Security = enum {
    unknown,
    open,
    wep,
    wpa,
    wpa2,
    wpa3,
};

pub const Ap = struct {
    const Self = @This();

    ptr: *anyopaque,
    vtable: *const VTable,

    pub const MacAddr = root.MacAddr;
    pub const Addr = root.Addr;
    pub const Security = root.Security;

    pub const State = enum {
        idle,
        starting,
        active,
    };

    pub const Config = struct {
        ssid: []const u8,
        password: []const u8 = "",
        channel: u8 = 1,
        max_clients: u8 = 4,
        hidden: bool = false,
        security: Self.Security = .wpa2,
        address: ?Self.Addr = null,
        gateway: ?Self.Addr = null,
        netmask: ?Self.Addr = null,
        dhcp_enabled: bool = true,
    };

    pub const StartedInfo = struct {
        ssid: []const u8,
        channel: u8,
        security: Self.Security,
    };

    pub const ClientInfo = struct {
        mac: Self.MacAddr,
        ip: ?Self.Addr = null,
        aid: u16 = 0,
    };

    pub const LeaseInfo = struct {
        client_mac: Self.MacAddr,
        client_ip: Self.Addr,
    };

    pub const Event = union(enum) {
        started: StartedInfo,
        stopped: void,
        client_joined: ClientInfo,
        client_left: ClientInfo,
        lease_granted: LeaseInfo,
        lease_released: LeaseInfo,
    };

    pub const StartError = error{
        Busy,
        InvalidConfig,
        Unsupported,
        Unexpected,
    };

    pub const VTable = struct {
        start: *const fn (ptr: *anyopaque, config: Config) StartError!void,
        stop: *const fn (ptr: *anyopaque) void,
        disconnectClient: *const fn (ptr: *anyopaque, mac: Self.MacAddr) void,
        getState: *const fn (ptr: *anyopaque) State,
        addEventHook: *const fn (ptr: *anyopaque, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Event) void) void,
        removeEventHook: *const fn (ptr: *anyopaque, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Event) void) void,
        getMacAddr: *const fn (ptr: *anyopaque) ?Self.MacAddr,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn start(self: Self, config: Config) StartError!void {
        return self.vtable.start(self.ptr, config);
    }

    pub fn stop(self: Self) void {
        self.vtable.stop(self.ptr);
    }

    pub fn disconnectClient(self: Self, mac: Self.MacAddr) void {
        self.vtable.disconnectClient(self.ptr, mac);
    }

    pub fn getState(self: Self) State {
        return self.vtable.getState(self.ptr);
    }

    pub fn addEventHook(self: Self, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Event) void) void {
        self.vtable.addEventHook(self.ptr, ctx, cb);
    }

    pub fn removeEventHook(self: Self, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Event) void) void {
        self.vtable.removeEventHook(self.ptr, ctx, cb);
    }

    pub fn getMacAddr(self: Self) ?Self.MacAddr {
        return self.vtable.getMacAddr(self.ptr);
    }

    pub fn deinit(self: Self) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn make(pointer: anytype) Self {
        const Ptr = @TypeOf(pointer);
        const info = @typeInfo(Ptr);
        if (info != .pointer or info.pointer.size != .one)
            @compileError("Ap.make expects a single-item pointer");

        const Impl = info.pointer.child;

        const gen = struct {
            fn startFn(ptr: *anyopaque, config: Config) StartError!void {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                return self.start(config);
            }

            fn stopFn(ptr: *anyopaque) void {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                self.stop();
            }

            fn disconnectClientFn(ptr: *anyopaque, mac: Self.MacAddr) void {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                self.disconnectClient(mac);
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

            fn getMacAddrFn(ptr: *anyopaque) ?Self.MacAddr {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                if (@hasDecl(Impl, "getMacAddr")) {
                    return self.getMacAddr();
                }
                return null;
            }

            fn deinitFn(ptr: *anyopaque) void {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                self.deinit();
            }

            const vtable = VTable{
                .start = startFn,
                .stop = stopFn,
                .disconnectClient = disconnectClientFn,
                .getState = getStateFn,
                .addEventHook = addEventHookFn,
                .removeEventHook = removeEventHookFn,
                .getMacAddr = getMacAddrFn,
                .deinit = deinitFn,
            };
        };

        return .{
            .ptr = pointer,
            .vtable = &gen.vtable,
        };
    }

    pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
        const TestCase = struct {
            fn makeAllowsMissingOptionalIntrospection() !void {
                const Impl = struct {
                    pub fn start(_: *@This(), _: Config) StartError!void {}
                    pub fn stop(_: *@This()) void {}
                    pub fn disconnectClient(_: *@This(), _: Self.MacAddr) void {}
                    pub fn getState(_: *@This()) State {
                        return .idle;
                    }
                    pub fn addEventHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, Event) void) void {}
                    pub fn deinit(_: *@This()) void {}
                };

                var impl = Impl{};
                const ap = Self.make(&impl);

                ap.removeEventHook(null, struct {
                    fn onEvent(_: ?*anyopaque, _: Event) void {}
                }.onEvent);
                try lib.testing.expect(ap.getMacAddr() == null);
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

                TestCase.makeAllowsMissingOptionalIntrospection() catch |err| {
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
};

pub const Sta = struct {
    const Self = @This();

    ptr: *anyopaque,
    vtable: *const VTable,

    pub const max_ssid_len: usize = root.max_ssid_len;
    pub const MacAddr = root.MacAddr;
    pub const Addr = root.Addr;
    pub const Security = root.Security;

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
        bssid: ?Self.MacAddr = null,
        channel: u8 = 0,
        timeout_ms: u32 = 0,
    };

    pub const ScanResult = struct {
        ssid: []const u8,
        bssid: Self.MacAddr,
        channel: u8,
        rssi: i16,
        security: Self.Security,
    };

    pub const LinkInfo = struct {
        ssid: []const u8 = "",
        bssid: ?Self.MacAddr = null,
        channel: u8 = 0,
        rssi: i16 = 0,
        security: Self.Security = .unknown,
    };

    pub const IpInfo = struct {
        address: Self.Addr,
        gateway: ?Self.Addr = null,
        netmask: ?Self.Addr = null,
        dns1: ?Self.Addr = null,
        dns2: ?Self.Addr = null,
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
        getMacAddr: *const fn (ptr: *anyopaque) ?Self.MacAddr,
        getIpInfo: *const fn (ptr: *anyopaque) ?IpInfo,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn startScan(self: Self, config: ScanConfig) ScanError!void {
        return self.vtable.startScan(self.ptr, config);
    }

    pub fn stopScan(self: Self) void {
        self.vtable.stopScan(self.ptr);
    }

    pub fn connect(self: Self, config: ConnectConfig) ConnectError!void {
        return self.vtable.connect(self.ptr, config);
    }

    pub fn disconnect(self: Self) void {
        self.vtable.disconnect(self.ptr);
    }

    pub fn getState(self: Self) State {
        return self.vtable.getState(self.ptr);
    }

    pub fn addEventHook(self: Self, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Event) void) void {
        self.vtable.addEventHook(self.ptr, ctx, cb);
    }

    pub fn removeEventHook(self: Self, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Event) void) void {
        self.vtable.removeEventHook(self.ptr, ctx, cb);
    }

    pub fn getMacAddr(self: Self) ?Self.MacAddr {
        return self.vtable.getMacAddr(self.ptr);
    }

    pub fn getIpInfo(self: Self) ?IpInfo {
        return self.vtable.getIpInfo(self.ptr);
    }

    pub fn deinit(self: Self) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn make(pointer: anytype) Self {
        const Ptr = @TypeOf(pointer);
        const info = @typeInfo(Ptr);
        if (info != .pointer or info.pointer.size != .one)
            @compileError("Sta.make expects a single-item pointer");

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

            fn getMacAddrFn(ptr: *anyopaque) ?Self.MacAddr {
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

    pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
        const TestCase = struct {
            fn makeAllowsMissingOptionalIntrospection() !void {
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
                const sta = Self.make(&impl);

                sta.removeEventHook(null, struct {
                    fn onEvent(_: ?*anyopaque, _: Event) void {}
                }.onEvent);
                try lib.testing.expect(sta.getMacAddr() == null);
                try lib.testing.expect(sta.getIpInfo() == null);
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

                TestCase.makeAllowsMissingOptionalIntrospection() catch |err| {
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
};

pub const Wifi = struct {
    const Self = @This();

    pub const max_ssid_len: usize = root.max_ssid_len;
    pub const MacAddr = root.MacAddr;
    pub const Addr = root.Addr;
    pub const Security = root.Security;

    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Event = union(enum) {
        sta: Sta.Event,
        ap: Ap.Event,
    };

    pub const CallbackFn = *const fn (ctx: *const anyopaque, source_id: u32, event: Event) void;

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        sta: *const fn (ptr: *anyopaque) Sta,
        ap: *const fn (ptr: *anyopaque) Ap,
        setEventCallback: *const fn (ptr: *anyopaque, ctx: *const anyopaque, emit_fn: CallbackFn) void,
        clearEventCallback: *const fn (ptr: *anyopaque) void,
    };

    pub fn deinit(self: Self) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn sta(self: Self) Sta {
        return self.vtable.sta(self.ptr);
    }

    pub fn ap(self: Self) Ap {
        return self.vtable.ap(self.ptr);
    }

    pub fn setEventCallback(self: Self, ctx: *const anyopaque, emit_fn: CallbackFn) void {
        self.vtable.setEventCallback(self.ptr, ctx, emit_fn);
    }

    pub fn clearEventCallback(self: Self) void {
        self.vtable.clearEventCallback(self.ptr);
    }

    pub fn make(comptime lib: type, comptime Impl: type) type {
        comptime {
            if (!@hasDecl(Impl, "Config")) @compileError("Wifi impl must define Config");
            if (!@hasDecl(Impl, "init")) @compileError("Wifi impl must define init");
            if (!@hasDecl(Impl, "deinit")) @compileError("Wifi impl must define deinit");
            if (!@hasDecl(Impl, "sta")) @compileError("Wifi impl must define sta");
            if (!@hasDecl(Impl, "ap")) @compileError("Wifi impl must define ap");
            if (!@hasDecl(Impl, "setEventCallback")) @compileError("Wifi impl must define setEventCallback");
            if (!@hasDecl(Impl, "clearEventCallback")) @compileError("Wifi impl must define clearEventCallback");
            if (!@hasField(Impl.Config, "allocator")) @compileError("Wifi impl Config must define allocator");

            _ = @as(*const fn (Impl.Config) anyerror!Impl, &Impl.init);
            _ = @as(*const fn (*Impl) void, &Impl.deinit);
            _ = @as(*const fn (*Impl) Sta, &Impl.sta);
            _ = @as(*const fn (*Impl) Ap, &Impl.ap);
            _ = @as(*const fn (*Impl, *const anyopaque, CallbackFn) void, &Impl.setEventCallback);
            _ = @as(*const fn (*Impl) void, &Impl.clearEventCallback);
        }

        const Allocator = lib.mem.Allocator;
        const Ctx = struct {
            allocator: Allocator,
            impl: Impl,

            pub fn deinit(self: *@This()) void {
                self.impl.deinit();
                self.allocator.destroy(self);
            }

            pub fn sta(self: *@This()) Sta {
                return self.impl.sta();
            }

            pub fn ap(self: *@This()) Ap {
                return self.impl.ap();
            }

            pub fn setEventCallback(self: *@This(), ctx: *const anyopaque, emit_fn: CallbackFn) void {
                self.impl.setEventCallback(ctx, emit_fn);
            }

            pub fn clearEventCallback(self: *@This()) void {
                self.impl.clearEventCallback();
            }
        };
        const VTableGen = struct {
            fn deinitFn(ptr: *anyopaque) void {
                const self: *Ctx = @ptrCast(@alignCast(ptr));
                self.deinit();
            }

            fn staFn(ptr: *anyopaque) Sta {
                const self: *Ctx = @ptrCast(@alignCast(ptr));
                return self.sta();
            }

            fn apFn(ptr: *anyopaque) Ap {
                const self: *Ctx = @ptrCast(@alignCast(ptr));
                return self.ap();
            }

            fn setEventCallbackFn(ptr: *anyopaque, ctx: *const anyopaque, emit_fn: CallbackFn) void {
                const self: *Ctx = @ptrCast(@alignCast(ptr));
                self.setEventCallback(ctx, emit_fn);
            }

            fn clearEventCallbackFn(ptr: *anyopaque) void {
                const self: *Ctx = @ptrCast(@alignCast(ptr));
                self.clearEventCallback();
            }

            const vtable = VTable{
                .deinit = deinitFn,
                .sta = staFn,
                .ap = apFn,
                .setEventCallback = setEventCallbackFn,
                .clearEventCallback = clearEventCallbackFn,
            };
        };

        return struct {
            pub const Config = Impl.Config;

            pub fn init(config: Config) !Self {
                var impl = try Impl.init(config);
                errdefer impl.deinit();

                const storage = try config.allocator.create(Ctx);
                errdefer config.allocator.destroy(storage);
                storage.* = .{
                    .allocator = config.allocator,
                    .impl = impl,
                };
                return .{
                    .ptr = storage,
                    .vtable = &VTableGen.vtable,
                };
            }
        };
    }

    pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
        const TestCase = struct {
            fn exposesStaAndApVtableSurface() !void {
                const StaImpl = struct {
                    pub fn startScan(_: *@This(), _: Sta.ScanConfig) Sta.ScanError!void {}
                    pub fn stopScan(_: *@This()) void {}
                    pub fn connect(_: *@This(), _: Sta.ConnectConfig) Sta.ConnectError!void {}
                    pub fn disconnect(_: *@This()) void {}
                    pub fn getState(_: *@This()) Sta.State {
                        return .idle;
                    }
                    pub fn addEventHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, Sta.Event) void) void {}
                    pub fn deinit(_: *@This()) void {}
                };

                const ApImpl = struct {
                    pub fn start(_: *@This(), _: Ap.Config) Ap.StartError!void {}
                    pub fn stop(_: *@This()) void {}
                    pub fn disconnectClient(_: *@This(), _: Ap.MacAddr) void {}
                    pub fn getState(_: *@This()) Ap.State {
                        return .idle;
                    }
                    pub fn addEventHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, Ap.Event) void) void {}
                    pub fn deinit(_: *@This()) void {}
                };

                const Impl = struct {
                    pub const Config = struct {
                        allocator: lib.mem.Allocator,
                    };

                    sta_impl: StaImpl = .{},
                    ap_impl: ApImpl = .{},

                    pub fn init(config: Config) !@This() {
                        _ = config;
                        return .{};
                    }

                    pub fn deinit(self: *@This()) void {
                        _ = self;
                    }

                    pub fn sta(self: *@This()) Sta {
                        return Sta.make(&self.sta_impl);
                    }

                    pub fn ap(self: *@This()) Ap {
                        return Ap.make(&self.ap_impl);
                    }

                    pub fn setEventCallback(self: *@This(), ctx: *const anyopaque, emit_fn: CallbackFn) void {
                        _ = self;
                        _ = ctx;
                        _ = emit_fn;
                    }

                    pub fn clearEventCallback(self: *@This()) void {
                        _ = self;
                    }
                };

                comptime {
                    _ = Self.deinit;
                    _ = Self.sta;
                    _ = Self.ap;
                    _ = Self.setEventCallback;
                    _ = Self.clearEventCallback;
                    _ = Self.Event;
                    _ = Self.CallbackFn;
                    _ = Self.make;
                    _ = Self.make(lib, Impl).init;
                    if (!@hasField(Self.make(lib, Impl).Config, "allocator")) {
                        @compileError("make config must expose allocator");
                    }
                }
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

                TestCase.exposesStaAndApVtableSurface() catch |err| {
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
};

pub fn make(comptime lib: type) type {
    return struct {
        pub const Ap = root.Ap;
        pub const Sta = root.Sta;

        pub fn makeWifi(comptime Impl: type) type {
            return root.Wifi.make(lib, Impl);
        }
    };
}

pub const test_runner = struct {
    pub const unit = @import("wifi/test_runner/unit.zig");
    pub const integration = @import("wifi/test_runner/integration.zig");
};

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    return test_runner.unit.make(lib);
}
