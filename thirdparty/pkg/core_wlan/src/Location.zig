const glib = @import("glib");
const std = @import("std");

const objc = @import("objc.zig");

pub const AuthorizationStatus = enum(objc.NSInteger) {
    not_determined = 0,
    restricted = 1,
    denied = 2,
    authorized_always = 3,
    authorized_when_in_use = 4,
    unknown = -1,
};

pub fn authorizationStatus() AuthorizationStatus {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const manager = makeLocationManager() orelse return .unknown;
    defer objc.release(manager);

    return mapStatus(objc.msgSend(objc.NSInteger, manager, objc.sel("authorizationStatus"), .{}));
}

pub fn requestWhenInUseAuthorization(timeout: glib.time.duration.Duration) AuthorizationStatus {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const manager = makeLocationManager() orelse return .unknown;
    defer objc.release(manager);

    const initial = mapStatus(objc.msgSend(objc.NSInteger, manager, objc.sel("authorizationStatus"), .{}));
    if (initial != .not_determined) return initial;

    objc.msgSend(void, manager, objc.sel("requestWhenInUseAuthorization"), .{});

    const deadline = std.time.nanoTimestamp() + @max(timeout, 0);
    while (std.time.nanoTimestamp() < deadline) {
        runLoopOnce(0.1);

        const next = mapStatus(objc.msgSend(objc.NSInteger, manager, objc.sel("authorizationStatus"), .{}));
        if (next != .not_determined) return next;
    }

    return .not_determined;
}

fn makeLocationManager() ?objc.Id {
    const CLLocationManager = objc.getClass("CLLocationManager");
    return objc.msgSend(objc.Id, objc.alloc(CLLocationManager), objc.sel("init"), .{});
}

fn runLoopOnce(seconds: f64) void {
    const run_loop = objc.msgSend(objc.Id, objc.getClass("NSRunLoop"), objc.sel("currentRunLoop"), .{});
    const until = objc.msgSend(objc.Id, objc.getClass("NSDate"), objc.sel("dateWithTimeIntervalSinceNow:"), .{
        seconds,
    });
    objc.msgSend(void, run_loop, objc.sel("runUntilDate:"), .{
        until,
    });
}

fn mapStatus(raw: objc.NSInteger) AuthorizationStatus {
    return switch (raw) {
        0 => .not_determined,
        1 => .restricted,
        2 => .denied,
        3 => .authorized_always,
        4 => .authorized_when_in_use,
        else => .unknown,
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn mapStatusCoversKnownCoreLocationValues() !void {
            try grt.std.testing.expectEqual(AuthorizationStatus.not_determined, mapStatus(0));
            try grt.std.testing.expectEqual(AuthorizationStatus.restricted, mapStatus(1));
            try grt.std.testing.expectEqual(AuthorizationStatus.denied, mapStatus(2));
            try grt.std.testing.expectEqual(AuthorizationStatus.authorized_always, mapStatus(3));
            try grt.std.testing.expectEqual(AuthorizationStatus.authorized_when_in_use, mapStatus(4));
            try grt.std.testing.expectEqual(AuthorizationStatus.unknown, mapStatus(99));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.mapStatusCoversKnownCoreLocationValues() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
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
