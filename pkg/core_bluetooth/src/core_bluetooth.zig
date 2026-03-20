//! core_bluetooth — Apple CoreBluetooth backend for lib/bt.
//!
//! Implements bt.Central and bt.Peripheral by bridging to
//! CBCentralManager and CBPeripheralManager via Objective-C runtime.
//!
//! Usage:
//!   const cb = @import("core_bluetooth");
//!   var central = try cb.Central(.{}).init(allocator);
//!   defer central.deinit();
//!   try central.start();
//!   try central.startScanning(.{ .active = true });

const std = @import("std");
const bt = @import("bt");
const CBCentral = @import("CBCentral.zig");
const CBPeripheral = @import("CBPeripheral.zig");

pub fn Central(comptime config: CBCentral.Config) type {
    return struct {
        pub const InitError = std.mem.Allocator.Error;

        pub fn init(allocator: std.mem.Allocator) InitError!bt.Central {
            const impl = try allocator.create(CBCentral);
            impl.* = CBCentral.init(allocator, config);
            return bt.Central.wrap(impl);
        }
    };
}

pub fn Peripheral(comptime config: CBPeripheral.Config) type {
    return struct {
        pub const InitError = std.mem.Allocator.Error;

        pub fn init(allocator: std.mem.Allocator) InitError!bt.Peripheral {
            const impl = try allocator.create(CBPeripheral);
            impl.* = CBPeripheral.init(allocator, config);
            return bt.Peripheral.wrap(impl);
        }
    };
}

test "central" {
    var c = try Central(.{}).init(std.testing.allocator);
    defer c.deinit();
    try c.start();
    try bt.test_runner.central.run(std, c);
}

test "peripheral" {
    var p = try Peripheral(.{}).init(std.testing.allocator);
    defer p.deinit();
    try p.start();
    try bt.test_runner.peripheral.run(std, p);
}
