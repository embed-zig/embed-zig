//! Central test runner — exercises bt.Central through the VTable interface.
//!
//! Tests lifecycle, scanning with various configs, event hooks, and
//! error conditions. Does NOT require a paired Peripheral.

const embed = @import("embed");
const bt = @import("../../../bt.zig");
const Central = @import("../../Central.zig");
const testing_api = @import("testing");

pub fn make(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const Mocker = bt.Mocker(lib, Channel);
            var mocker = Mocker.init(lib.testing.allocator, .{});
            defer mocker.deinit();

            var host = mocker.createHost(.{}) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer host.deinit();

            t.run("central", makeWithHost(lib, &host));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}

pub fn makeWithHost(comptime lib: type, host: anytype) testing_api.TestRunner {
    const HostPtr = @TypeOf(host);
    comptime requireHostPointer(HostPtr);

    const Runner = struct {
        host: HostPtr,

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = allocator;
            const c = self.host.central();
            c.start() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer c.stop();

            runCentral(lib, c) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{ .host = host };
    return testing_api.TestRunner.make(Runner).new(runner);
}

fn runCentral(comptime lib: type, c: Central) !void {
    const testing = lib.testing;

    try testing.expectEqual(Central.State.idle, c.getState());
    _ = c.getAddr();

    try c.startScanning(.{ .active = true, .timeout_ms = 1000 });
    try testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();
    try testing.expectEqual(Central.State.idle, c.getState());

    try c.startScanning(.{ .active = false, .timeout_ms = 1000 });
    try testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();
    try testing.expectEqual(Central.State.idle, c.getState());

    try c.startScanning(.{
        .active = true,
        .timeout_ms = 1000,
        .service_uuids = &.{0x180D},
    });
    try testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();

    try c.startScanning(.{
        .active = true,
        .timeout_ms = 1000,
        .service_uuids = &.{ 0x180D, 0x180F, 0xFFE0 },
    });
    try testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();

    try c.startScanning(.{
        .active = true,
        .timeout_ms = 1000,
        .filter_duplicates = false,
    });
    try testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();

    try c.startScanning(.{
        .active = true,
        .timeout_ms = 1000,
        .interval_ms = 100,
        .window_ms = 50,
    });
    try testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();

    try testing.expectEqual(Central.State.idle, c.getState());
    c.stopScanning();
    try testing.expectEqual(Central.State.idle, c.getState());

    var hook_called = lib.atomic.Value(bool).init(false);
    c.addEventHook(@ptrCast(&hook_called), struct {
        fn cb(ctx: ?*anyopaque, _: Central.Event) void {
            const flag: *lib.atomic.Value(bool) = @ptrCast(@alignCast(ctx.?));
            flag.store(true, .release);
        }
    }.cb);

    var hook2_called = lib.atomic.Value(bool).init(false);
    c.addEventHook(@ptrCast(&hook2_called), struct {
        fn cb(ctx: ?*anyopaque, _: Central.Event) void {
            const flag: *lib.atomic.Value(bool) = @ptrCast(@alignCast(ctx.?));
            flag.store(true, .release);
        }
    }.cb);

    try c.startScanning(.{ .active = true, .timeout_ms = 500 });
    try testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();
    try testing.expectEqual(Central.State.idle, c.getState());
    try c.startScanning(.{ .active = true, .timeout_ms = 500 });
    try testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();
    try testing.expectEqual(Central.State.idle, c.getState());

    try testing.expectEqual(Central.State.idle, c.getState());
}

fn requireHostPointer(comptime T: type) void {
    if (@typeInfo(T) != .pointer) {
        @compileError("central runner expects *Host instance");
    }
}
