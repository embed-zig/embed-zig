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
            const callback_count = callback_calls.fetchAdd(1, .seq_cst) + 1;
            const state = stores.strip.get();
            switch (callback_count) {
                1 => checkState(state, ledstrip.Color.rgb(20, 0, 0)),
                2 => checkState(state, ledstrip.Color.rgb(40, 0, 0)),
                3 => checkState(state, ledstrip.Color.rgb(60, 0, 0)),
                4 => checkState(state, ledstrip.Color.rgb(80, 0, 0)),
                5 => checkState(state, ledstrip.Color.rgb(100, 0, 0)),
                else => fail(.unexpected_callback_count),
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

        fn checkState(state: anytype, expected: ledstrip.Color) void {
            if (state.brightness != expected_brightness) {
                fail(.wrong_brightness);
                return;
            }
            if (state.total_frames != 1) {
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
