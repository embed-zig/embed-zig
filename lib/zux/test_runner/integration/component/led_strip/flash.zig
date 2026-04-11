const testing_api = @import("testing");

const common = @import("common.zig");
const ledstrip = @import("ledstrip");

fn TestCase(comptime lib: type, comptime BuiltApp: type) type {
    return struct {
        const Self = @This();
        const Failure = enum {
            missing_callback_count,
            wrong_brightness,
            wrong_current_color,
            wrong_total_frames,
            timed_out_waiting_for_color,
        };

        var callback_mu: lib.Thread.Mutex = .{};
        var callback_calls: usize = 0;
        var callback_failure: ?Failure = null;
        var last_visible_color: ?ledstrip.Color = null;
        const expected_callback_count = 25;

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
            if (currentCallbackCalls() < expected_callback_count) {
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

            const expected_colors = [_]ledstrip.Color{
                ledstrip.Color.white,
                ledstrip.Color.rgb(223, 223, 223),
                ledstrip.Color.rgb(191, 191, 191),
                ledstrip.Color.rgb(159, 159, 159),
                ledstrip.Color.rgb(128, 127, 127),
                ledstrip.Color.rgb(128, 95, 95),
                ledstrip.Color.rgb(128, 63, 63),
                ledstrip.Color.rgb(128, 31, 31),
                ledstrip.Color.rgb(128, 0, 0),
                ledstrip.Color.rgb(112, 0, 0),
                ledstrip.Color.rgb(96, 0, 0),
                ledstrip.Color.rgb(80, 0, 0),
                ledstrip.Color.rgb(64, 0, 0),
                ledstrip.Color.rgb(48, 0, 0),
                ledstrip.Color.rgb(32, 0, 0),
                ledstrip.Color.rgb(16, 0, 0),
                ledstrip.Color.black,
                ledstrip.Color.rgb(16, 0, 0),
                ledstrip.Color.rgb(32, 0, 0),
                ledstrip.Color.rgb(48, 0, 0),
                ledstrip.Color.rgb(64, 0, 0),
                ledstrip.Color.rgb(80, 0, 0),
                ledstrip.Color.rgb(96, 0, 0),
                ledstrip.Color.rgb(112, 0, 0),
                ledstrip.Color.rgb(128, 0, 0),
            };
            const state = stores.strip.get();
            if (last_visible_color) |last| {
                if (common.colorEql(last, state.current.pixels[0])) return;
            }
            last_visible_color = state.current.pixels[0];

            callback_calls += 1;
            if (callback_calls > expected_callback_count) return;
            checkStateLocked(
                state,
                expected_colors[callback_calls - 1],
                if (callback_calls == 1) 255 else 128,
                if (callback_calls == 1) 1 else 2,
            );
        }

        fn driveSequence(app: *BuiltApp) !void {
            try app.set_led_strip_pixels(.strip, BuiltApp.FrameType.solid(ledstrip.Color.white), 255);
            try waitForCallbackCount(1);

            const duration_ns = 8 * lib.time.ns_per_ms;
            const interval_ns = 8 * lib.time.ns_per_ms;
            try app.set_led_strip_flash(
                .strip,
                BuiltApp.FrameType.solid(ledstrip.Color.red),
                128,
                duration_ns,
                interval_ns,
            );
            try waitForCallbackCount(expected_callback_count);
        }

        fn checkStateLocked(state: anytype, expected: ledstrip.Color, expected_brightness: u8, expected_frames: usize) void {
            if (state.brightness != expected_brightness) {
                failLocked(.wrong_brightness);
                return;
            }
            if (state.total_frames != expected_frames) {
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
            last_visible_color = null;
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
