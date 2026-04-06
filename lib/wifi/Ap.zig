//! Ap — type-erased low-level Wi-Fi access point interface.

const types = @import("types.zig");
const testing_api = @import("testing");

const Ap = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const MacAddr = types.MacAddr;
pub const Addr = types.Addr;
pub const Security = types.Security;

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
    security: Security = .wpa2,
    address: ?Addr = null,
    gateway: ?Addr = null,
    netmask: ?Addr = null,
    dhcp_enabled: bool = true,
};

pub const StartedInfo = struct {
    ssid: []const u8,
    channel: u8,
    security: Security,
};

pub const ClientInfo = struct {
    mac: MacAddr,
    ip: ?Addr = null,
    aid: u16 = 0,
};

pub const LeaseInfo = struct {
    client_mac: MacAddr,
    client_ip: Addr,
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
    disconnectClient: *const fn (ptr: *anyopaque, mac: MacAddr) void,
    getState: *const fn (ptr: *anyopaque) State,
    addEventHook: *const fn (ptr: *anyopaque, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Event) void) void,
    removeEventHook: *const fn (ptr: *anyopaque, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Event) void) void,
    getMacAddr: *const fn (ptr: *anyopaque) ?MacAddr,
    deinit: *const fn (ptr: *anyopaque) void,
};

pub fn start(self: Ap, config: Config) StartError!void {
    return self.vtable.start(self.ptr, config);
}

pub fn stop(self: Ap) void {
    self.vtable.stop(self.ptr);
}

pub fn disconnectClient(self: Ap, mac: MacAddr) void {
    self.vtable.disconnectClient(self.ptr, mac);
}

pub fn getState(self: Ap) State {
    return self.vtable.getState(self.ptr);
}

pub fn addEventHook(self: Ap, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Event) void) void {
    self.vtable.addEventHook(self.ptr, ctx, cb);
}

pub fn removeEventHook(self: Ap, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, Event) void) void {
    self.vtable.removeEventHook(self.ptr, ctx, cb);
}

pub fn getMacAddr(self: Ap) ?MacAddr {
    return self.vtable.getMacAddr(self.ptr);
}

pub fn deinit(self: Ap) void {
    self.vtable.deinit(self.ptr);
}

pub fn make(pointer: anytype) Ap {
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

        fn disconnectClientFn(ptr: *anyopaque, mac: MacAddr) void {
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

        fn getMacAddrFn(ptr: *anyopaque) ?MacAddr {
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
                pub fn disconnectClient(_: *@This(), _: MacAddr) void {}
                pub fn getState(_: *@This()) State {
                    return .idle;
                }
                pub fn addEventHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, Event) void) void {}
                pub fn deinit(_: *@This()) void {}
            };

            var impl = Impl{};
            const ap = make(&impl);

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
