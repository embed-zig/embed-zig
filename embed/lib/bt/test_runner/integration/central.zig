//! Central test runner — exercises bt.Central through the VTable interface.
//!
//! Tests lifecycle, scanning with various configs, event hooks, and
//! error conditions. Does NOT require a paired Peripheral.

const glib = @import("glib");

const bt = @import("../../../bt.zig");
const Central = @import("../../Central.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const Mocker = bt.Mocker(grt);
            var mocker = Mocker.init(grt.std.testing.allocator, .{});
            defer mocker.deinit();

            var host = mocker.createHost(.{}) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer host.deinit();

            t.run("central", makeWithHost(grt, &host));
            return t.wait();
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

pub fn makeWithHost(comptime grt: type, host: anytype) glib.testing.TestRunner {
    const HostPtr = @TypeOf(host);
    comptime requireHostPointer(HostPtr);

    const Runner = struct {
        host: HostPtr,

        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = allocator;
            const c = self.host.central();
            c.start() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer c.stop();

            runCentral(grt, c) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = allocator;
            grt.std.testing.allocator.destroy(self);
        }
    };

    const runner = grt.std.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{ .host = host };
    return glib.testing.TestRunner.make(Runner).new(runner);
}

fn runCentral(comptime grt: type, c: Central) !void {
    try grt.std.testing.expectEqual(Central.State.idle, c.getState());
    _ = c.getAddr();

    try c.startScanning(.{ .active = true, .timeout = 1000 * glib.time.duration.MilliSecond });
    try grt.std.testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();
    try grt.std.testing.expectEqual(Central.State.idle, c.getState());

    try c.startScanning(.{ .active = false, .timeout = 1000 * glib.time.duration.MilliSecond });
    try grt.std.testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();
    try grt.std.testing.expectEqual(Central.State.idle, c.getState());

    try c.startScanning(.{
        .active = true,
        .timeout = 1000 * glib.time.duration.MilliSecond,
        .service_uuids = &.{0x180D},
    });
    try grt.std.testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();

    try c.startScanning(.{
        .active = true,
        .timeout = 1000 * glib.time.duration.MilliSecond,
        .service_uuids = &.{ 0x180D, 0x180F, 0xFFE0 },
    });
    try grt.std.testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();

    try c.startScanning(.{
        .active = true,
        .timeout = 1000 * glib.time.duration.MilliSecond,
        .filter_duplicates = false,
    });
    try grt.std.testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();

    try c.startScanning(.{
        .active = true,
        .timeout = 1000 * glib.time.duration.MilliSecond,
        .interval = 100 * glib.time.duration.MilliSecond,
        .window = 50 * glib.time.duration.MilliSecond,
    });
    try grt.std.testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();

    try grt.std.testing.expectEqual(Central.State.idle, c.getState());
    c.stopScanning();
    try grt.std.testing.expectEqual(Central.State.idle, c.getState());

    var hook_called = grt.std.atomic.Value(bool).init(false);
    c.addEventHook(@ptrCast(&hook_called), struct {
        fn cb(ctx: ?*anyopaque, _: Central.Event) void {
            const flag: *grt.std.atomic.Value(bool) = @ptrCast(@alignCast(ctx.?));
            flag.store(true, .release);
        }
    }.cb);

    var hook2_called = grt.std.atomic.Value(bool).init(false);
    c.addEventHook(@ptrCast(&hook2_called), struct {
        fn cb(ctx: ?*anyopaque, _: Central.Event) void {
            const flag: *grt.std.atomic.Value(bool) = @ptrCast(@alignCast(ctx.?));
            flag.store(true, .release);
        }
    }.cb);

    try c.startScanning(.{ .active = true, .timeout = 500 * glib.time.duration.MilliSecond });
    try grt.std.testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();
    try grt.std.testing.expectEqual(Central.State.idle, c.getState());
    try c.startScanning(.{ .active = true, .timeout = 500 * glib.time.duration.MilliSecond });
    try grt.std.testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();
    try grt.std.testing.expectEqual(Central.State.idle, c.getState());

    try grt.std.testing.expectEqual(Central.State.idle, c.getState());
}

fn requireHostPointer(comptime T: type) void {
    if (@typeInfo(T) != .pointer) {
        @compileError("central runner expects *Host instance");
    }
}
