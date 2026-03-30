//! core_bluetooth — Apple CoreBluetooth backend for lib/bt.
//!
//! Implements a bt.Host-compatible backend by bridging to
//! CBCentralManager and CBPeripheralManager via Objective-C runtime.
//!
//! Usage:
//!   const cb = @import("core_bluetooth");
//!   const Host = cb.Host;
//!   _ = Host;

const std = @import("std");
const bt = @import("bt");
const embed_std = @import("embed_std");
const CBCentral = @import("core_bluetooth/src/CBCentral.zig");
const CBPeripheral = @import("core_bluetooth/src/CBPeripheral.zig");

pub const Host = bt.Host.make(embed_std.std, struct {
    pub const CentralConfig = CBCentral.Config;
    pub const PeripheralConfig = CBPeripheral.Config;
    pub const Config = struct {
        allocator: std.mem.Allocator,
        central: CentralConfig = .{},
        peripheral: PeripheralConfig = .{},
    };

    central_impl: *CBCentral,
    peripheral_impl: *CBPeripheral,

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
        };
    }

    pub fn deinit(self: *Self) void {
        self.central_impl.deinit();
        self.peripheral_impl.deinit();
    }

    pub fn central(self: *Self) bt.Central {
        return bt.Central.wrap(self.central_impl);
    }

    pub fn peripheral(self: *Self) bt.Peripheral {
        return bt.Peripheral.wrap(self.peripheral_impl);
    }
}, embed_std.sync.Channel);

test "core_bluetooth/unit_tests" {}

test "core_bluetooth/integration_tests" {
    _ = @import("core_bluetooth/integration_test/central.zig");
    _ = @import("core_bluetooth/integration_test/peripheral.zig");
}
