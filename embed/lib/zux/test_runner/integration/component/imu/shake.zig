const glib = @import("glib");

const common = @import("common.zig");
const component_imu = @import("../../../../component/Imu.zig");
const drivers = @import("drivers");

fn TestCase(comptime grt: type, comptime BuiltApp: type) type {
    return struct {
        const Self = @This();
        const Failure = enum {
            missing_callback_count,
            unexpected_callback_count,
            callback_during_noise,
            wrong_source_id,
            missing_motion,
            wrong_motion_kind,
            motion_should_clear,
        };
        const AtomicUsize = grt.std.atomic.Value(usize);
        const AtomicU8 = grt.std.atomic.Value(u8);

        var callback_calls: AtomicUsize = AtomicUsize.init(0);
        var callback_failure: AtomicU8 = AtomicU8.init(0);

        pub fn init(self: *Self, allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
            reset();
        }

        pub fn run(self: *Self, t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;

            var dummy_imu = common.DummyImuImpl{};
            var app = BuiltApp.init(.{
                .allocator = allocator,
                .sensor = drivers.imu.init(&dummy_imu),
            }) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer app.deinit();

            app.store.handle("io/imu", Self.onImu) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer _ = app.store.unhandle("io/imu", Self.onImu);

            app.start(.{}) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };

            driveSequence(&app) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };

            app.stop() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };

            if (currentFailure()) |failure| {
                t.logFatal(@tagName(failure));
                return false;
            }
            if (currentCallbackCalls() != 4) {
                t.logFatal(@tagName(Failure.missing_callback_count));
                return false;
            }
            return true;
        }

        pub fn deinit(self: *Self, allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }

        pub fn onImu(stores: *BuiltApp.Store.Stores) void {
            const callback_count = callback_calls.fetchAdd(1, .seq_cst) + 1;
            const state = stores.sensor.get();
            switch (callback_count) {
                1 => checkShakeState(state),
                2 => checkClearedState(state),
                3 => checkShakeState(state),
                4 => checkClearedState(state),
                else => fail(.unexpected_callback_count),
            }
        }

        fn driveSequence(app: *BuiltApp) !void {
            // The device sits on a desk with minor vibration first.
            try pushAccel(app, .{ .x = 0.0, .y = 0.0, .z = 1.00 }, 10 * glib.time.duration.MilliSecond);
            try pushAccel(app, .{ .x = 0.0, .y = 0.0, .z = 1.12 }, 10 * glib.time.duration.MilliSecond);
            try pushAccel(app, .{ .x = 0.0, .y = 0.0, .z = 0.96 }, 10 * glib.time.duration.MilliSecond);
            try ensureNoCallback(20 * glib.time.duration.MilliSecond, .callback_during_noise);

            // Then a real hand shake happens as a magnitude burst without reorientation.
            try pushAccel(app, .{ .x = 0.0, .y = 0.0, .z = 2.80 }, 10 * glib.time.duration.MilliSecond);
            try pushAccel(app, .{ .x = 0.0, .y = 0.0, .z = 0.20 }, 10 * glib.time.duration.MilliSecond);
            try pushAccel(app, .{ .x = 0.0, .y = 0.0, .z = 2.60 }, 50 * glib.time.duration.MilliSecond);
            try pushAccel(app, .{ .x = 0.0, .y = 0.0, .z = 1.00 }, 40 * glib.time.duration.MilliSecond);
            try app.imu_accel(.sensor, .{ .x = 0.0, .y = 0.0, .z = 1.00 });
            try waitForCallbackCount(1);

            // Once the device settles, the transient shake motion should clear.
            try app.imu_accel(.sensor, .{ .x = 0.0, .y = 0.0, .z = 1.00 });
            try waitForCallbackCount(2);

            // A second deliberate shake should re-enter the same motion cleanly.
            try pushAccel(app, .{ .x = 0.0, .y = 0.0, .z = 2.70 }, 10 * glib.time.duration.MilliSecond);
            try pushAccel(app, .{ .x = 0.0, .y = 0.0, .z = 0.30 }, 10 * glib.time.duration.MilliSecond);
            try pushAccel(app, .{ .x = 0.0, .y = 0.0, .z = 2.50 }, 50 * glib.time.duration.MilliSecond);
            try pushAccel(app, .{ .x = 0.0, .y = 0.0, .z = 1.00 }, 40 * glib.time.duration.MilliSecond);
            try app.imu_accel(.sensor, .{ .x = 0.0, .y = 0.0, .z = 1.00 });
            try waitForCallbackCount(3);

            // And another calm sample should clear the store again.
            try app.imu_accel(.sensor, .{ .x = 0.0, .y = 0.0, .z = 1.00 });
            try waitForCallbackCount(4);
        }

        fn pushAccel(app: *BuiltApp, accel: BuiltApp.Imu.Vec3, sleep_duration: glib.time.duration.Duration) !void {
            try app.imu_accel(.sensor, accel);
            grt.std.Thread.sleep(@intCast(sleep_duration));
        }

        fn ensureNoCallback(window: glib.time.duration.Duration, failure: Failure) !void {
            grt.std.Thread.sleep(@intCast(window));
            if (currentFailure() != null) return error.CallbackFailed;
            if (currentCallbackCalls() != 0) {
                fail(failure);
                return error.CallbackFailed;
            }
        }

        fn checkShakeState(state: component_imu.State) void {
            if (state.source_id != 17) {
                fail(.wrong_source_id);
                return;
            }
            if (state.motion == null) {
                fail(.missing_motion);
                return;
            }
            if (state.motion.? != .shake) {
                fail(.wrong_motion_kind);
            }
        }

        fn checkClearedState(state: component_imu.State) void {
            if (state.source_id != 17) {
                fail(.wrong_source_id);
                return;
            }
            if (state.motion != null) {
                fail(.motion_should_clear);
            }
        }

        fn reset() void {
            callback_calls.store(0, .seq_cst);
            callback_failure.store(0, .seq_cst);
        }

        fn fail(next: Failure) void {
            const encoded: u8 = @as(u8, @intFromEnum(next)) + 1;
            _ = callback_failure.cmpxchgStrong(0, encoded, .seq_cst, .seq_cst);
        }

        fn currentCallbackCalls() usize {
            return callback_calls.load(.seq_cst);
        }

        fn currentFailure() ?Failure {
            const encoded = callback_failure.load(.seq_cst);
            if (encoded == 0) return null;
            return @enumFromInt(encoded - 1);
        }

        fn waitForCallbackCount(expected: usize) !void {
            const poll_interval = 10 * glib.time.duration.MilliSecond;
            var attempts: usize = 0;
            while (attempts < 300) : (attempts += 1) {
                if (currentFailure() != null) return error.CallbackFailed;
                if (currentCallbackCalls() >= expected) return;
                grt.std.Thread.sleep(@intCast(poll_interval));
            }
            fail(.missing_callback_count);
            return error.TimedOut;
        }
    };
}

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const BuiltApp = comptime common.makeBuiltApp(grt);
    const Case = TestCase(grt, BuiltApp);

    const Holder = struct {
        var runner: Case = .{};
    };
    return glib.testing.TestRunner.make(Case).new(&Holder.runner);
}
