const testing_api = @import("testing");

const common = @import("common.zig");
const component_imu = @import("../../../../component/Imu.zig");
const drivers = @import("drivers");

fn TestCase(comptime lib: type, comptime BuiltApp: type) type {
    return struct {
        const Self = @This();
        const Failure = enum {
            missing_callback_count,
            unexpected_callback_count,
            callback_during_prelude,
            callback_after_recovery,
            wrong_source_id,
            missing_motion,
            wrong_motion_kind,
            motion_should_clear,
        };
        const AtomicUsize = lib.atomic.Value(usize);
        const AtomicU8 = lib.atomic.Value(u8);

        var callback_calls: AtomicUsize = AtomicUsize.init(0);
        var callback_failure: AtomicU8 = AtomicU8.init(0);

        pub fn init(self: *Self, allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
            reset();
        }

        pub fn run(self: *Self, t: *testing_api.T, allocator: lib.mem.Allocator) bool {
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

            app.start() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };

            driveSequence(&app) catch |err| {
                if (currentFailure()) |failure| {
                    t.logFatal(@tagName(failure));
                } else {
                    t.logFatal(@errorName(err));
                }
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
            if (currentCallbackCalls() != 2) {
                t.logFatal(@tagName(Failure.missing_callback_count));
                return false;
            }
            return true;
        }

        pub fn deinit(self: *Self, allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }

        pub fn onImu(stores: *BuiltApp.Store.Stores) void {
            const callback_count = callback_calls.fetchAdd(1, .seq_cst) + 1;
            const state = stores.sensor.get();
            switch (callback_count) {
                1 => checkFreeFallState(state),
                2 => checkClearedState(state),
                else => fail(.unexpected_callback_count),
            }
        }

        fn driveSequence(app: *BuiltApp) !void {
            // Baseline: held steady with small handling noise first.
            try pushAccel(app, .{ .x = 0.0, .y = 0.0, .z = 1.0 }, 40);
            try pushAccel(app, .{ .x = 0.08, .y = 0.02, .z = 0.96 }, 40);
            try pushAccel(app, .{ .x = 0.02, .y = 0.00, .z = 1.03 }, 40);
            try ensureCallbackCount(0, .callback_during_prelude);

            // The device slips into a real low-g drop window.
            try pushAccel(app, .{ .x = 0.0, .y = 0.0, .z = 0.64 }, 40);
            try pushAccel(app, .{ .x = 0.0, .y = 0.0, .z = 0.41 }, 40);
            try pushAccel(app, .{ .x = 0.0, .y = 0.0, .z = 0.21 }, 50);
            try pushAccel(app, .{ .x = 0.0, .y = 0.0, .z = 0.10 }, 50);
            try pushAccel(app, .{ .x = 0.0, .y = 0.0, .z = 0.05 }, 40);
            try app.imu_accel(.sensor, .{ .x = 0.00, .y = 0.00, .z = 0.03 });
            try waitForCallbackCount(1);

            // After impact/recovery, the transient free-fall motion should clear.
            try pushAccel(app, .{ .x = 0.0, .y = 0.0, .z = 1.0 }, 40);
            try waitForCallbackCount(2);
            try pushAccel(app, .{ .x = 0.0, .y = 0.0, .z = 1.0 }, 40);
            try ensureCallbackCount(2, .callback_after_recovery);
        }

        fn pushAccel(app: *BuiltApp, accel: BuiltApp.Imu.Vec3, sleep_ms: u64) !void {
            try app.imu_accel(.sensor, accel);
            lib.Thread.sleep(sleep_ms * lib.time.ns_per_ms);
        }

        fn ensureCallbackCount(expected: usize, failure: Failure) !void {
            if (currentFailure() != null) return error.CallbackFailed;
            if (currentCallbackCalls() != expected) {
                fail(failure);
                return error.CallbackFailed;
            }
        }

        fn checkFreeFallState(state: component_imu.State) void {
            if (state.source_id != 17) {
                fail(.wrong_source_id);
                return;
            }
            if (state.motion == null) {
                fail(.missing_motion);
                return;
            }
            if (state.motion.? != .free_fall) {
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
            var attempts: usize = 0;
            while (attempts < 300) : (attempts += 1) {
                if (currentFailure() != null) return error.CallbackFailed;
                if (currentCallbackCalls() >= expected) return;
                lib.Thread.sleep(10 * lib.time.ns_per_ms);
            }
            fail(.missing_callback_count);
            return error.TimedOut;
        }
    };
}

pub fn make(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
    const BuiltApp = comptime common.makeBuiltApp(lib, Channel);
    const Case = TestCase(lib, BuiltApp);

    const Holder = struct {
        var runner: Case = .{};
    };
    return testing_api.TestRunner.make(Case).new(&Holder.runner);
}
