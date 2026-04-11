const testing_api = @import("testing");

const common = @import("common.zig");
const ledstrip = @import("ledstrip");

fn baseFrame(comptime FrameType: type) FrameType {
    return .{
        .pixels = .{
            ledstrip.Color.red,
            ledstrip.Color.green,
            ledstrip.Color.blue,
        },
    };
}

fn TestCase(comptime lib: type, comptime BuiltApp: type) type {
    return struct {
        const Self = @This();
        const Failure = enum {
            missing_callback_count,
            wrong_brightness,
            wrong_current_frame,
            wrong_total_frames,
            timed_out_waiting_for_color,
        };

        var callback_mu: lib.Thread.Mutex = .{};
        var callback_calls: usize = 0;
        var callback_failure: ?Failure = null;
        var last_visible_frame: ?BuiltApp.FrameType = null;
        const expected_callback_count = 25;

        pub fn init(self: *Self, allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
            reset();
        }

        pub fn run(self: *Self, t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;

            const DummyStrip = common.DummyStrip(3);
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

            const FrameType = BuiltApp.FrameType;
            // Golden frames from pipeline with 1ms tick, 8ms transition, and 8ms hold.
            const expected_frames = [_]FrameType{
                .{ .pixels = .{
                    ledstrip.Color.red,
                    ledstrip.Color.green,
                    ledstrip.Color.blue,
                } },
                .{ .pixels = .{
                    ledstrip.Color.rgb(223, 32, 0),
                    ledstrip.Color.rgb(0, 223, 32),
                    ledstrip.Color.rgb(32, 0, 223),
                } },
                .{ .pixels = .{
                    ledstrip.Color.rgb(191, 64, 0),
                    ledstrip.Color.rgb(0, 191, 64),
                    ledstrip.Color.rgb(64, 0, 191),
                } },
                .{ .pixels = .{
                    ledstrip.Color.rgb(159, 96, 0),
                    ledstrip.Color.rgb(0, 159, 96),
                    ledstrip.Color.rgb(96, 0, 159),
                } },
                .{ .pixels = .{
                    ledstrip.Color.rgb(127, 128, 0),
                    ledstrip.Color.rgb(0, 127, 128),
                    ledstrip.Color.rgb(128, 0, 127),
                } },
                .{ .pixels = .{
                    ledstrip.Color.rgb(95, 160, 0),
                    ledstrip.Color.rgb(0, 95, 160),
                    ledstrip.Color.rgb(160, 0, 95),
                } },
                .{ .pixels = .{
                    ledstrip.Color.rgb(63, 192, 0),
                    ledstrip.Color.rgb(0, 63, 192),
                    ledstrip.Color.rgb(192, 0, 63),
                } },
                .{ .pixels = .{
                    ledstrip.Color.rgb(31, 224, 0),
                    ledstrip.Color.rgb(0, 31, 224),
                    ledstrip.Color.rgb(224, 0, 31),
                } },
                .{ .pixels = .{
                    ledstrip.Color.green,
                    ledstrip.Color.blue,
                    ledstrip.Color.red,
                } },
                .{ .pixels = .{
                    ledstrip.Color.rgb(0, 223, 32),
                    ledstrip.Color.rgb(32, 0, 223),
                    ledstrip.Color.rgb(223, 32, 0),
                } },
                .{ .pixels = .{
                    ledstrip.Color.rgb(0, 191, 64),
                    ledstrip.Color.rgb(64, 0, 191),
                    ledstrip.Color.rgb(191, 64, 0),
                } },
                .{ .pixels = .{
                    ledstrip.Color.rgb(0, 159, 96),
                    ledstrip.Color.rgb(96, 0, 159),
                    ledstrip.Color.rgb(159, 96, 0),
                } },
                .{ .pixels = .{
                    ledstrip.Color.rgb(0, 127, 128),
                    ledstrip.Color.rgb(128, 0, 127),
                    ledstrip.Color.rgb(127, 128, 0),
                } },
                .{ .pixels = .{
                    ledstrip.Color.rgb(0, 95, 160),
                    ledstrip.Color.rgb(160, 0, 95),
                    ledstrip.Color.rgb(95, 160, 0),
                } },
                .{ .pixels = .{
                    ledstrip.Color.rgb(0, 63, 192),
                    ledstrip.Color.rgb(192, 0, 63),
                    ledstrip.Color.rgb(63, 192, 0),
                } },
                .{ .pixels = .{
                    ledstrip.Color.rgb(0, 31, 224),
                    ledstrip.Color.rgb(224, 0, 31),
                    ledstrip.Color.rgb(31, 224, 0),
                } },
                .{ .pixels = .{
                    ledstrip.Color.blue,
                    ledstrip.Color.red,
                    ledstrip.Color.green,
                } },
                .{ .pixels = .{
                    ledstrip.Color.rgb(32, 0, 223),
                    ledstrip.Color.rgb(223, 32, 0),
                    ledstrip.Color.rgb(0, 223, 32),
                } },
                .{ .pixels = .{
                    ledstrip.Color.rgb(64, 0, 191),
                    ledstrip.Color.rgb(191, 64, 0),
                    ledstrip.Color.rgb(0, 191, 64),
                } },
                .{ .pixels = .{
                    ledstrip.Color.rgb(96, 0, 159),
                    ledstrip.Color.rgb(159, 96, 0),
                    ledstrip.Color.rgb(0, 159, 96),
                } },
                .{ .pixels = .{
                    ledstrip.Color.rgb(128, 0, 127),
                    ledstrip.Color.rgb(127, 128, 0),
                    ledstrip.Color.rgb(0, 127, 128),
                } },
                .{ .pixels = .{
                    ledstrip.Color.rgb(160, 0, 95),
                    ledstrip.Color.rgb(95, 160, 0),
                    ledstrip.Color.rgb(0, 95, 160),
                } },
                .{ .pixels = .{
                    ledstrip.Color.rgb(192, 0, 63),
                    ledstrip.Color.rgb(63, 192, 0),
                    ledstrip.Color.rgb(0, 63, 192),
                } },
                .{ .pixels = .{
                    ledstrip.Color.rgb(224, 0, 31),
                    ledstrip.Color.rgb(31, 224, 0),
                    ledstrip.Color.rgb(0, 31, 224),
                } },
                .{ .pixels = .{
                    ledstrip.Color.red,
                    ledstrip.Color.green,
                    ledstrip.Color.blue,
                } },
            };
            const state = stores.strip.get();
            if (last_visible_frame) |last| {
                if (state.current.eql(last)) return;
            }
            last_visible_frame = state.current;

            callback_calls += 1;
            if (callback_calls > expected_callback_count) return;
            checkStateLocked(
                state,
                expected_frames[callback_calls - 1],
                255,
                if (callback_calls == 1) 1 else 3,
            );
        }

        fn driveSequence(app: *BuiltApp) !void {
            const original = baseFrame(BuiltApp.FrameType);
            try app.set_led_strip_pixels(.strip, original, 255);
            try waitForCallbackCount(1);

            const duration_ns = 8 * lib.time.ns_per_ms;
            const interval_ns = 8 * lib.time.ns_per_ms;
            try app.set_led_strip_rotate(.strip, original, 255, duration_ns, interval_ns);
            try waitForCallbackCount(expected_callback_count);
        }

        fn checkStateLocked(state: anytype, expected: BuiltApp.FrameType, expected_brightness: u8, expected_frames: usize) void {
            if (state.brightness != expected_brightness) {
                failLocked(.wrong_brightness);
                return;
            }
            if (state.total_frames != expected_frames) {
                failLocked(.wrong_total_frames);
                return;
            }
            if (!state.current.eql(expected)) {
                failLocked(.wrong_current_frame);
            }
        }

        fn reset() void {
            callback_mu.lock();
            defer callback_mu.unlock();
            callback_calls = 0;
            callback_failure = null;
            last_visible_frame = null;
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
    const BuiltApp = comptime common.makeBuiltApp(lib, Channel, 3);
    const Case = TestCase(lib, BuiltApp);

    const Holder = struct {
        var runner: Case = .{};
    };
    return testing_api.TestRunner.make(Case).new(&Holder.runner);
}
