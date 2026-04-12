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
        const AtomicUsize = lib.atomic.Value(usize);
        const AtomicU8 = lib.atomic.Value(u8);

        var callback_calls: AtomicUsize = AtomicUsize.init(0);
        var callback_failure: AtomicU8 = AtomicU8.init(0);
        var visible_state_mu: lib.Thread.Mutex = .{};
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
            visible_state_mu.lock();
            defer visible_state_mu.unlock();

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

            const callback_count = callback_calls.fetchAdd(1, .seq_cst) + 1;
            if (callback_count > expected_callback_count) {
                fail(.unexpected_callback_count);
                return;
            }
            checkState(
                state,
                expected_colors[callback_count - 1],
                if (callback_count == 1) 255 else 128,
                if (callback_count == 1) 1 else 2,
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

        fn checkState(state: anytype, expected: ledstrip.Color, expected_brightness: u8, expected_frames: usize) void {
            if (state.brightness != expected_brightness) {
                fail(.wrong_brightness);
                return;
            }
            if (state.total_frames != expected_frames) {
                fail(.wrong_total_frames);
                return;
            }
            if (!common.colorEql(state.current.pixels[0], expected)) {
                fail(.wrong_current_color);
            }
        }

        fn reset() void {
            callback_calls.store(0, .seq_cst);
            callback_failure.store(0, .seq_cst);
            visible_state_mu.lock();
            last_visible_color = null;
            visible_state_mu.unlock();
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
                if (currentCallbackCalls() >= expected) return;
                lib.Thread.sleep(10 * lib.time.ns_per_ms);
            }
            fail(.timed_out_waiting_for_color);
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
