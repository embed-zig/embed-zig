//! Peripheral test runner — exercises bt.Peripheral through the VTable interface.
//!
//! Tests lifecycle, handler registration, advertising with various configs,
//! event hooks, and error conditions. Does NOT require a paired Central.

const embed = @import("embed");
const bt = @import("../../../bt.zig");
const Peripheral = @import("../../Peripheral.zig");
const testing_api = @import("testing");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const Mocker = bt.Mocker(lib);
            var mocker = Mocker.init(lib.testing.allocator, .{});
            defer mocker.deinit();

            var host = mocker.createHost(.{}) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer host.deinit();

            t.run("peripheral", makeWithHost(lib, &host));
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
            const p = self.host.peripheral();
            p.start() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer p.stop();

            runPeripheral(lib, p) catch |err| {
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

fn runPeripheral(comptime lib: type, p: Peripheral) !void {
    const testing = lib.testing;

    try testing.expectEqual(Peripheral.State.idle, p.getState());
    _ = p.getAddr();

    p.setConfig(.{
        .services = &.{
            Peripheral.Service(0x180D, &.{
                Peripheral.Char(0x2A37, Peripheral.CharConfig.default()),
                Peripheral.Char(0x2A38, Peripheral.CharConfig.default()),
            }),
            Peripheral.Service(0xFFE0, &.{
                Peripheral.Char(0xFFE1, Peripheral.CharConfig.default()),
            }),
            Peripheral.Service(0x180F, &.{
                Peripheral.Char(0x2A19, Peripheral.CharConfig.default()),
            }),
            Peripheral.Service(0xFFF0, &.{
                Peripheral.Char(0xFFF1, Peripheral.CharConfig.default()),
            }),
        },
    });

    var ctx_val: u32 = 42;
    p.setRequestHandler(&ctx_val, struct {
        fn handler(ctx: ?*anyopaque, req: *const Peripheral.Request, rw: *Peripheral.ResponseWriter) void {
            if (req.service_uuid == 0xFFF0 and req.char_uuid == 0xFFF1) {
                const raw = ctx orelse unreachable;
                const v: *u32 = @ptrCast(@alignCast(raw));
                _ = v;
            }
            rw.ok();
        }
    }.handler);

    try p.startAdvertising(.{
        .device_name = "ZigTest",
        .service_uuids = &.{0x180D},
    });
    try testing.expectEqual(Peripheral.State.advertising, p.getState());
    p.stopAdvertising();
    try testing.expectEqual(Peripheral.State.idle, p.getState());

    try p.startAdvertising(.{
        .device_name = "ZigMultiSvc",
        .service_uuids = &.{ 0x180D, 0x180F, 0xFFE0 },
    });
    try testing.expectEqual(Peripheral.State.advertising, p.getState());
    p.stopAdvertising();

    try p.startAdvertising(.{
        .device_name = "ZigBLE-TestDevice-LongName-0123",
        .service_uuids = &.{0x180D},
    });
    try testing.expectEqual(Peripheral.State.advertising, p.getState());
    p.stopAdvertising();

    try p.startAdvertising(.{
        .service_uuids = &.{0xFFE0},
    });
    try testing.expectEqual(Peripheral.State.advertising, p.getState());
    p.stopAdvertising();

    try p.startAdvertising(.{
        .device_name = "ZigNameOnly",
    });
    try testing.expectEqual(Peripheral.State.advertising, p.getState());
    p.stopAdvertising();

    try p.startAdvertising(.{ .device_name = "ZigTest" });
    try testing.expectEqual(Peripheral.State.advertising, p.getState());
    try testing.expectError(
        error.AlreadyAdvertising,
        p.startAdvertising(.{ .device_name = "ZigTest2" }),
    );
    p.stopAdvertising();
    try testing.expectEqual(Peripheral.State.idle, p.getState());

    p.stopAdvertising();
    try testing.expectEqual(Peripheral.State.idle, p.getState());

    try p.startAdvertising(.{
        .device_name = "ZigCycle1",
        .service_uuids = &.{0x180D},
    });
    try testing.expectEqual(Peripheral.State.advertising, p.getState());
    p.stopAdvertising();
    try testing.expectEqual(Peripheral.State.idle, p.getState());
    try p.startAdvertising(.{
        .device_name = "ZigCycle2",
        .service_uuids = &.{0xFFE0},
    });
    try testing.expectEqual(Peripheral.State.advertising, p.getState());
    p.stopAdvertising();
    try testing.expectEqual(Peripheral.State.idle, p.getState());

    var hook_event_count = lib.atomic.Value(u32).init(0);
    p.addEventHook(@ptrCast(&hook_event_count), struct {
        fn cb(ctx: ?*anyopaque, _: Peripheral.Event) void {
            const counter: *lib.atomic.Value(u32) = @ptrCast(@alignCast(ctx.?));
            _ = counter.fetchAdd(1, .monotonic);
        }
    }.cb);

    try p.startAdvertising(.{ .device_name = "ZigHookTest" });
    p.stopAdvertising();
    try testing.expect(hook_event_count.load(.acquire) >= 2);

    var hook2_count = lib.atomic.Value(u32).init(0);
    p.addEventHook(@ptrCast(&hook2_count), struct {
        fn cb(ctx: ?*anyopaque, _: Peripheral.Event) void {
            const counter: *lib.atomic.Value(u32) = @ptrCast(@alignCast(ctx.?));
            _ = counter.fetchAdd(1, .monotonic);
        }
    }.cb);

    const prev1 = hook_event_count.load(.acquire);
    const prev2 = hook2_count.load(.acquire);
    try p.startAdvertising(.{ .device_name = "ZigMultiHook" });
    p.stopAdvertising();
    try testing.expect(hook_event_count.load(.acquire) > prev1);
    try testing.expect(hook2_count.load(.acquire) > prev2);

    try testing.expectEqual(Peripheral.State.idle, p.getState());
}

fn requireHostPointer(comptime T: type) void {
    if (@typeInfo(T) != .pointer) {
        @compileError("peripheral runner expects *Host instance");
    }
}
