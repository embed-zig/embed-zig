//! bt.Host — type-erased BLE host bundle.

const bt = @import("../bt.zig");
const CentralMod = @import("host/Central.zig");
const Hci = @import("host/Hci.zig");
const PeripheralMod = @import("host/Peripheral.zig");
const Transport = @import("Transport.zig");

const root = @This();

pub const addr_len: usize = 6;
pub const max_name_len: usize = 32;
pub const max_adv_data_len: usize = 31;

ptr: *anyopaque,
vtable: *const VTable,

pub const Event = union(enum) {
    central: bt.Central.Event,
    peripheral: bt.Peripheral.Event,
};

pub const CallbackFn = *const fn (ctx: *const anyopaque, source_id: u32, event: Event) void;

pub const VTable = struct {
    deinit: *const fn (ptr: *anyopaque) void,
    central: *const fn (ptr: *anyopaque) bt.Central,
    peripheral: *const fn (ptr: *anyopaque) bt.Peripheral,
    setEventCallback: *const fn (ptr: *anyopaque, ctx: *const anyopaque, emit_fn: CallbackFn) void,
    clearEventCallback: *const fn (ptr: *anyopaque) void,
};

pub fn deinit(self: root) void {
    self.vtable.deinit(self.ptr);
}

pub fn central(self: root) bt.Central {
    return self.vtable.central(self.ptr);
}

pub fn peripheral(self: root) bt.Peripheral {
    return self.vtable.peripheral(self.ptr);
}

pub fn setEventCallback(self: root, ctx: *const anyopaque, emit_fn: CallbackFn) void {
    self.vtable.setEventCallback(self.ptr, ctx, emit_fn);
}

pub fn clearEventCallback(self: root) void {
    self.vtable.clearEventCallback(self.ptr);
}

pub fn make(comptime lib: type, comptime Impl: type, comptime Channel: fn (type) type) type {
    _ = Channel;
    comptime {
        if (!@hasDecl(Impl, "Config")) @compileError("Host impl must define Config");
        if (!@hasDecl(Impl, "init")) @compileError("Host impl must define init");
        if (!@hasDecl(Impl, "deinit")) @compileError("Host impl must define deinit");
        if (!@hasDecl(Impl, "central")) @compileError("Host impl must define central");
        if (!@hasDecl(Impl, "peripheral")) @compileError("Host impl must define peripheral");
        if (!@hasDecl(Impl, "setEventCallback")) @compileError("Host impl must define setEventCallback");
        if (!@hasDecl(Impl, "clearEventCallback")) @compileError("Host impl must define clearEventCallback");
        if (!@hasField(Impl.Config, "allocator")) @compileError("Host impl Config must define allocator");

        _ = @as(*const fn (bt.Hci, Impl.Config) anyerror!Impl, &Impl.init);
        _ = @as(*const fn (*Impl) void, &Impl.deinit);
        _ = @as(*const fn (*Impl) bt.Central, &Impl.central);
        _ = @as(*const fn (*Impl) bt.Peripheral, &Impl.peripheral);
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

        pub fn central(self: *@This()) bt.Central {
            return self.impl.central();
        }

        pub fn peripheral(self: *@This()) bt.Peripheral {
            return self.impl.peripheral();
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

        fn centralFn(ptr: *anyopaque) bt.Central {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            return self.central();
        }

        fn peripheralFn(ptr: *anyopaque) bt.Peripheral {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            return self.peripheral();
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
            .central = centralFn,
            .peripheral = peripheralFn,
            .setEventCallback = setEventCallbackFn,
            .clearEventCallback = clearEventCallbackFn,
        };
    };

    return struct {
        pub const Config = Impl.Config;

        pub fn init(hci: bt.Hci, config: Config) !root {
            var impl = try Impl.init(hci, config);
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

pub fn makeHci(comptime lib: type, comptime Channel: fn (type) type) type {
    const CentralImpl = CentralMod.make(lib);
    const PeripheralImpl = PeripheralMod.make(lib);
    const Base = make(lib, struct {
        pub const Config = struct {
            allocator: lib.mem.Allocator,
            source_id: u32 = 0,
        };

        central_impl: CentralImpl,
        peripheral_impl: PeripheralImpl,
        source_id: u32,
        callback_ctx: ?*const anyopaque = null,
        callback_fn: ?CallbackFn = null,
        callback_installed: bool = false,

        const Self = @This();

        pub fn init(hci_value: bt.Hci, config: Config) !Self {
            return .{
                .central_impl = CentralImpl.init(hci_value, config.allocator),
                .peripheral_impl = PeripheralImpl.init(hci_value, config.allocator),
                .source_id = config.source_id,
            };
        }

        pub fn deinit(self: *Self) void {
            self.clearEventCallback();
            self.central_impl.deinit();
            self.peripheral_impl.deinit();
        }

        pub fn central(self: *Self) bt.Central {
            return bt.Central.wrap(&self.central_impl);
        }

        pub fn peripheral(self: *Self) bt.Peripheral {
            return bt.Peripheral.wrap(&self.peripheral_impl);
        }

        pub fn setEventCallback(self: *Self, ctx: *const anyopaque, emit_fn: CallbackFn) void {
            self.callback_ctx = ctx;
            self.callback_fn = emit_fn;

            if (!self.callback_installed) {
                self.central().addEventHook(self, onCentralEvent);
                self.peripheral().addEventHook(self, onPeripheralEvent);
                self.callback_installed = true;
            }
        }

        pub fn clearEventCallback(self: *Self) void {
            if (self.callback_installed) {
                self.central().removeEventHook(self, onCentralEvent);
                self.peripheral().removeEventHook(self, onPeripheralEvent);
                self.callback_installed = false;
            }
            self.callback_ctx = null;
            self.callback_fn = null;
        }

        fn emitEvent(self: *Self, event: Event) void {
            const ctx = self.callback_ctx orelse return;
            const emit_fn = self.callback_fn orelse return;
            emit_fn(ctx, self.source_id, event);
        }

        fn onCentralEvent(ctx: ?*anyopaque, event: bt.Central.Event) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.emitEvent(.{ .central = event });
        }

        fn onPeripheralEvent(ctx: ?*anyopaque, event: bt.Peripheral.Event) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.emitEvent(.{ .peripheral = event });
        }
    }, Channel);

    return struct {
        pub const Config = Base.Config;

        pub fn init(hci: bt.Hci, config: Config) !root {
            return Base.init(hci, config);
        }
    };
}

pub fn makeHciTransport(
    comptime lib: type,
    comptime Channel: fn (type) type,
 ) type {
    const HciType = Hci.make(lib);
    const Base = makeHci(lib, Channel);

    return struct {
        pub const Config = struct {
            hci: HciType.Config = .{},
            source_id: u32 = 0,
        };

        pub fn init(allocator: lib.mem.Allocator, transport: Transport, config: Config) !root {
            const hci_ptr = try allocator.create(HciType);
            errdefer allocator.destroy(hci_ptr);
            hci_ptr.* = HciType.init(transport, config.hci);
            errdefer hci_ptr.deinit();

            const inner_host = try Base.init(bt.Hci.wrap(hci_ptr), .{
                .allocator = allocator,
                .source_id = config.source_id,
            });
            errdefer inner_host.deinit();

            const Storage = struct {
                allocator: lib.mem.Allocator,
                hci: *HciType,
                host: root,

                pub fn deinit(self: *@This()) void {
                    self.host.deinit();
                    self.hci.deinit();
                    self.allocator.destroy(self.hci);
                    self.allocator.destroy(self);
                }

                pub fn central(self: *@This()) bt.Central {
                    return self.host.central();
                }

                pub fn peripheral(self: *@This()) bt.Peripheral {
                    return self.host.peripheral();
                }

                pub fn setEventCallback(self: *@This(), ctx: *const anyopaque, emit_fn: CallbackFn) void {
                    self.host.setEventCallback(ctx, emit_fn);
                }

                pub fn clearEventCallback(self: *@This()) void {
                    self.host.clearEventCallback();
                }
            };
            const VTableGen = struct {
                fn deinitFn(ptr: *anyopaque) void {
                    const self: *Storage = @ptrCast(@alignCast(ptr));
                    self.deinit();
                }

                fn centralFn(ptr: *anyopaque) bt.Central {
                    const self: *Storage = @ptrCast(@alignCast(ptr));
                    return self.central();
                }

                fn peripheralFn(ptr: *anyopaque) bt.Peripheral {
                    const self: *Storage = @ptrCast(@alignCast(ptr));
                    return self.peripheral();
                }

                fn setEventCallbackFn(ptr: *anyopaque, ctx: *const anyopaque, emit_fn: CallbackFn) void {
                    const self: *Storage = @ptrCast(@alignCast(ptr));
                    self.setEventCallback(ctx, emit_fn);
                }

                fn clearEventCallbackFn(ptr: *anyopaque) void {
                    const self: *Storage = @ptrCast(@alignCast(ptr));
                    self.clearEventCallback();
                }

                const vtable = VTable{
                    .deinit = deinitFn,
                    .central = centralFn,
                    .peripheral = peripheralFn,
                    .setEventCallback = setEventCallbackFn,
                    .clearEventCallback = clearEventCallbackFn,
                };
            };

            const storage = try allocator.create(Storage);
            errdefer allocator.destroy(storage);
            storage.* = .{
                .allocator = allocator,
                .hci = hci_ptr,
                .host = inner_host,
            };
            return .{
                .ptr = storage,
                .vtable = &VTableGen.vtable,
            };
        }
    };
}

test "bt/unit_tests/Host_exposes_vtable_surface" {
    const std = @import("std");
    const TestChannel = @import("embed_std").sync.Channel;

    comptime {
        _ = root.deinit;
        _ = root.central;
        _ = root.peripheral;
        _ = root.setEventCallback;
        _ = root.clearEventCallback;
        _ = root.Event;
        _ = root.CallbackFn;
        _ = root.make;
        _ = root.makeHci;
        _ = root.makeHciTransport;
        _ = makeHci(std, TestChannel).init;
        _ = makeHciTransport(std, TestChannel).init;
        if (!@hasField(makeHciTransport(std, TestChannel).Config, "source_id")) {
            @compileError("makeHciTransport config must expose source_id");
        }
    }
}
