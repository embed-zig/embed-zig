const testing_api = @import("testing");

const common = @import("common.zig");
const ledstrip = @import("ledstrip");

fn TestCase(comptime lib: type, comptime BuiltApp: type) type {
    return struct {
        const Self = @This();
        const Failure = enum {
            missing_callback_count,
            unexpected_callback_count,
            wrong_brightness,
            wrong_current_color,
            wrong_total_frames,
            timed_out_waiting_for_color,
        };

        var callback_mu: lib.Thread.Mutex = .{};
        var callback_calls: usize = 0;
        var callback_failure: ?Failure = null;
        const expected_callback_count = 5;
        const expected_brightness: u8 = 128;

        pub fn init(self: *Self, allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
            reset();
        }

        pub fn run(self: *Self, t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;

            const DummyStrip = common.DummyStrip(1);
            var dummy_strip = DummyStrip{};
            var app = BuiltApp.init(.{
                .allocator = allocator,
                .strip = dummy_strip.handle(),
            }) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer app.deinit();

            app.store.handle("ui/led_strip", Self.onLedStrip) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer _ = app.store.unhandle("ui/led_strip", Self.onLedStrip);

            app.start() catch |err| {
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
            if (currentCallbackCalls() != expected_callback_count) {
                t.logFatal(@tagName(Failure.missing_callback_count));
                return false;
            }
            return true;
        }

        pub fn deinit(self: *Self, allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }

        pub fn onLedStrip(stores: *BuiltApp.Store.Stores) void {
            callback_mu.lock();
            defer callback_mu.unlock();

            callback_calls += 1;
            const state = stores.strip.get();
            switch (callback_calls) {
                1 => checkStateLocked(state, ledstrip.Color.rgb(20, 0, 0)),
                2 => checkStateLocked(state, ledstrip.Color.rgb(40, 0, 0)),
                3 => checkStateLocked(state, ledstrip.Color.rgb(60, 0, 0)),
                4 => checkStateLocked(state, ledstrip.Color.rgb(80, 0, 0)),
                5 => checkStateLocked(state, ledstrip.Color.rgb(100, 0, 0)),
                else => failLocked(.unexpected_callback_count),
            }
        }

        fn driveSequence(app: *BuiltApp) !void {
            const initial_frame = BuiltApp.FrameType.solid(ledstrip.Color.rgb(40, 0, 0));
            try app.set_led_strip_pixels(.strip, initial_frame, expected_brightness);
            try waitForCallbackCount(1);

            const animated_frame = BuiltApp.FrameType.solid(ledstrip.Color.rgb(200, 0, 0));
            try app.set_led_strip_animated(.strip, animated_frame, expected_brightness, 4);
            try waitForCallbackCount(5);
        }

        fn checkStateLocked(state: anytype, expected: ledstrip.Color) void {
            if (state.brightness != expected_brightness) {
                failLocked(.wrong_brightness);
                return;
            }
            if (state.total_frames != 1) {
                failLocked(.wrong_total_frames);
                return;
            }
            if (!common.colorEql(state.current.pixels[0], expected)) {
                failLocked(.wrong_current_color);
            }
        }

        fn reset() void {
            callback_mu.lock();
            defer callback_mu.unlock();
            callback_calls = 0;
            callback_failure = null;
        }

        fn failLocked(next: Failure) void {
            if (callback_failure == null) {
                callback_failure = next;
            }
        }

        fn currentCallbackCalls() usize {
            callback_mu.lock();
            defer callback_mu.unlock();
            return callback_calls;
        }

        fn currentFailure() ?Failure {
            callback_mu.lock();
            defer callback_mu.unlock();
            return callback_failure;
        }

        fn waitForCallbackCount(expected: usize) !void {
            var attempts: usize = 0;
            while (attempts < 300) : (attempts += 1) {
                if (currentCallbackCalls() >= expected) return;
                lib.Thread.sleep(10 * lib.time.ns_per_ms);
            }
            callback_mu.lock();
            defer callback_mu.unlock();
            failLocked(.timed_out_waiting_for_color);
            return error.TimedOut;
        }
    };
}

pub fn make(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
    const BuiltApp = comptime common.makeBuiltApp(lib, Channel, 1);
    const Case = TestCase(lib, BuiltApp);

    const Holder = struct {
        var runner: Case = .{};
    };
    return testing_api.TestRunner.make(Case).new(&Holder.runner);
}
