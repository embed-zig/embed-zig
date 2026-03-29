//! Central test runner — exercises bt.Central through the VTable interface.
//!
//! Tests lifecycle, scanning with various configs, event hooks, and
//! error conditions. Does NOT require a paired Peripheral — all tests
//! exercise the local Central state machine only.
//!
//! Paired Central/Peripheral integration scenarios live in
//! `bt/test_runner/pair.zig`.
//!
//! Usage:
//!   const runner = @import("bt/test_runner/central.zig");
//!   t.run("central", runner.make(std, &host));

const embed = @import("embed");
const Central = @import("../Central.zig");
const testing_api = @import("testing");

pub fn make(comptime lib: type, host: anytype) testing_api.TestRunner {
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

    // ---- initial state ----
    try testing.expectEqual(Central.State.idle, c.getState());
    _ = c.getAddr();

    // ---- scan: active, default config ----
    try c.startScanning(.{ .active = true, .timeout_ms = 1000 });
    try testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();
    try testing.expectEqual(Central.State.idle, c.getState());

    // ---- scan: passive ----
    try c.startScanning(.{ .active = false, .timeout_ms = 1000 });
    try testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();
    try testing.expectEqual(Central.State.idle, c.getState());

    // ---- scan: with service UUID filter (16-bit) ----
    try c.startScanning(.{
        .active = true,
        .timeout_ms = 1000,
        .service_uuids = &.{0x180D},
    });
    try testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();

    // ---- scan: multiple service UUID filters ----
    try c.startScanning(.{
        .active = true,
        .timeout_ms = 1000,
        .service_uuids = &.{ 0x180D, 0x180F, 0xFFE0 },
    });
    try testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();

    // ---- scan: allow duplicates ----
    try c.startScanning(.{
        .active = true,
        .timeout_ms = 1000,
        .filter_duplicates = false,
    });
    try testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();

    // ---- scan: custom interval/window ----
    try c.startScanning(.{
        .active = true,
        .timeout_ms = 1000,
        .interval_ms = 100,
        .window_ms = 50,
    });
    try testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();

    // ---- stop scanning while idle (no-op) ----
    try testing.expectEqual(Central.State.idle, c.getState());
    c.stopScanning();
    try testing.expectEqual(Central.State.idle, c.getState());

    // ---- event hook: register single hook ----
    var hook_called = lib.atomic.Value(bool).init(false);
    c.addEventHook(@ptrCast(&hook_called), struct {
        fn cb(ctx: ?*anyopaque, _: Central.CentralEvent) void {
            const flag: *lib.atomic.Value(bool) = @ptrCast(@alignCast(ctx.?));
            flag.store(true, .release);
        }
    }.cb);

    // ---- event hook: register multiple hooks ----
    var hook2_called = lib.atomic.Value(bool).init(false);
    c.addEventHook(@ptrCast(&hook2_called), struct {
        fn cb(ctx: ?*anyopaque, _: Central.CentralEvent) void {
            const flag: *lib.atomic.Value(bool) = @ptrCast(@alignCast(ctx.?));
            flag.store(true, .release);
        }
    }.cb);

    // ---- scan → stop → scan cycle (re-entrant) ----
    try c.startScanning(.{ .active = true, .timeout_ms = 500 });
    try testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();
    try testing.expectEqual(Central.State.idle, c.getState());
    try c.startScanning(.{ .active = true, .timeout_ms = 500 });
    try testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();
    try testing.expectEqual(Central.State.idle, c.getState());

    // ---- final state: idle ----
    try testing.expectEqual(Central.State.idle, c.getState());
}

fn requireHostPointer(comptime T: type) void {
    if (@typeInfo(T) != .pointer) {
        @compileError("central runner expects *Host instance");
    }
}
