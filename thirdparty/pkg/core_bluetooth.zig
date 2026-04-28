//! core_bluetooth — Apple CoreBluetooth backend for lib/bt.
//!
//! Implements a bt.Host-compatible backend impl by bridging to
//! CBCentralManager and CBPeripheralManager via Objective-C runtime.
//!
//! Usage:
//!   const cb = @import("core_bluetooth");
//!   const Bt = bt.make(gstd.runtime);
//!   const Host = Bt.makeHost(cb.Host);
//!   _ = Host;

const std = @import("std");
const bt = @import("embed").bt;
const CBCentral = @import("core_bluetooth/src/CBCentral.zig");
const CBPeripheral = @import("core_bluetooth/src/CBPeripheral.zig");

pub const Host = struct {
    pub const CentralConfig = CBCentral.Config;
    pub const PeripheralConfig = CBPeripheral.Config;
    pub const Config = struct {
        allocator: std.mem.Allocator,
        source_id: u32 = 0,
        central: CentralConfig = .{},
        peripheral: PeripheralConfig = .{},
    };

    central_impl: *CBCentral,
    peripheral_impl: *CBPeripheral,
    source_id: u32,
    callback_ctx: ?*const anyopaque = null,
    callback_fn: ?bt.Host.CallbackFn = null,
    callback_installed: bool = false,

    const Self = @This();

    pub fn init(_: bt.Hci, config: Config) !Self {
        const central_impl = try config.allocator.create(CBCentral);
        errdefer config.allocator.destroy(central_impl);
        central_impl.* = CBCentral.init(config.allocator, config.central);

        const peripheral_impl = try config.allocator.create(CBPeripheral);
        errdefer central_impl.deinit();
        peripheral_impl.* = CBPeripheral.init(config.allocator, config.peripheral);

        return .{
            .central_impl = central_impl,
            .peripheral_impl = peripheral_impl,
            .source_id = config.source_id,
        };
    }

    pub fn deinit(self: *Self) void {
        self.clearEventCallback();
        self.central_impl.deinit();
        self.peripheral_impl.deinit();
    }

    pub fn central(self: *Self) bt.Central {
        return bt.Central.make(self.central_impl);
    }

    pub fn peripheral(self: *Self) bt.Peripheral {
        return bt.Peripheral.make(self.peripheral_impl);
    }

    pub fn setEventCallback(self: *Self, ctx: *const anyopaque, emit_fn: bt.Host.CallbackFn) void {
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

    fn emitEvent(self: *Self, event: bt.Host.Event) void {
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
};

pub const test_runner = struct {
    pub const unit = @import("core_bluetooth/test_runner/unit.zig");
    pub const integration = @import("core_bluetooth/test_runner/integration.zig");
};
