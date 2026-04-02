//! wifi.Wifi — type-erased Wi-Fi adapter bundle.

const Ap = @import("Ap.zig");
const Sta = @import("Sta.zig");
const types = @import("types.zig");

const root = @This();

pub const max_ssid_len: usize = types.max_ssid_len;
pub const MacAddr = types.MacAddr;
pub const Addr = types.Addr;
pub const Security = types.Security;

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

pub fn deinit(self: root) void {
    self.vtable.deinit(self.ptr);
}

pub fn sta(self: root) Sta {
    return self.vtable.sta(self.ptr);
}

pub fn ap(self: root) Ap {
    return self.vtable.ap(self.ptr);
}

pub fn setEventCallback(self: root, ctx: *const anyopaque, emit_fn: CallbackFn) void {
    self.vtable.setEventCallback(self.ptr, ctx, emit_fn);
}

pub fn clearEventCallback(self: root) void {
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

        pub fn init(config: Config) !root {
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

test "wifi/unit_tests/Wifi_exposes_sta_and_ap_vtable_surface" {
    const std = @import("std");

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
            allocator: std.mem.Allocator,
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
            return Sta.wrap(&self.sta_impl);
        }

        pub fn ap(self: *@This()) Ap {
            return Ap.wrap(&self.ap_impl);
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
        _ = root.deinit;
        _ = root.sta;
        _ = root.ap;
        _ = root.setEventCallback;
        _ = root.clearEventCallback;
        _ = root.Event;
        _ = root.CallbackFn;
        _ = root.make;
        _ = make(std, Impl).init;
        if (!@hasField(make(std, Impl).Config, "allocator")) {
            @compileError("make config must expose allocator");
        }
    }
}
