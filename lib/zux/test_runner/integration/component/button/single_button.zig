const testing_api = @import("testing");

const Assembler = @import("../../../../Assembler.zig");
const button = @import("../../../../component/button.zig");
const Message = @import("../../../../pipeline/Message.zig");
const drivers = @import("drivers");

fn makeBuiltApp(comptime lib: type, comptime Channel: fn (type) type) type {
    const AssemblerType = Assembler.make(lib, .{}, Channel);
    var assembler = AssemblerType.init();
    assembler.addSingleButton(.buttons, 7);
    assembler.setState("ui/button", .{.buttons});

    const BuildConfig = assembler.BuildConfig();
    const build_config: BuildConfig = .{
        .buttons = drivers.button.Single,
    };
    return assembler.build(build_config);
}

fn MockGpioImpl() type {
    return struct {
        pub fn read(_: *@This()) drivers.Gpio.Error!drivers.Gpio.Level {
            return .high;
        }

        pub fn write(_: *@This(), _: drivers.Gpio.Level) drivers.Gpio.Error!void {
        }

        pub fn setDirection(_: *@This(), _: drivers.Gpio.Direction) drivers.Gpio.Error!void {
        }
    };
}

fn TestCase(comptime lib: type, comptime BuiltApp: type) type {
    return struct {
        const Self = @This();
        const Failure = enum {
            missing_callback_count,
            unexpected_callback_count,
            wrong_source_id,
            wrong_button_id,
            missing_gesture_kind,
            wrong_gesture_kind,
            wrong_click_count,
            wrong_long_press_ns,
        };
        const AtomicUsize = lib.atomic.Value(usize);
        const AtomicU8 = lib.atomic.Value(u8);
        const press_timestamp_ns: i128 = 100 * lib.time.ns_per_ms;
        const tap_gap_ns: i128 = 20 * lib.time.ns_per_ms;
        const settle_ns: i128 = @as(i128, button.Reducer.default_multi_click_window_ns) + (100 * lib.time.ns_per_ms);

        var callback_calls: AtomicUsize = AtomicUsize.init(0);
        var callback_failure: AtomicU8 = AtomicU8.init(0);
        const expected_callback_count = 7;

        pub fn init(self: *Self, allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
            reset();
        }

        pub fn run(self: *Self, t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;

            const MockGpio = MockGpioImpl();
            const MockGpioButton = drivers.button.GpioButton.make(.{});
            var mock_gpio_impl = MockGpio{};
            const mock_gpio = drivers.Gpio.init(&mock_gpio_impl);
            var mock_button = MockGpioButton.init(mock_gpio);
            var app = BuiltApp.init(.{
                .allocator = allocator,
                .buttons = drivers.button.Single.fromGpioButton(&mock_button),
            }) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer app.deinit();

            app.store.handle("ui/button", Self.onButton) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer _ = app.store.unhandle("ui/button", Self.onButton);

            // Keep click sequencing deterministic by driving fixed-timestamp
            // messages directly instead of starting background pollers/ticks.
            driveSequence(&app) catch |err| {
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

        pub fn onButton(stores: *BuiltApp.Store.Stores) void {
            const callback_count = callback_calls.fetchAdd(1, .seq_cst) + 1;
            const state = stores.buttons.get();
            switch (callback_count) {
                1 => checkClickState(state, 1),
                2 => checkClickState(state, 2),
                3 => checkClickState(state, 1),
                4 => checkClickState(state, 2),
                5 => checkClickState(state, 3),
                6 => checkClickState(state, 4),
                7 => checkClickState(state, 5),
                else => fail(.unexpected_callback_count),
            }
        }

        fn driveSequence(app: *BuiltApp) !void {
            var timestamp_ns = press_timestamp_ns;
            try driveClicks(app, &timestamp_ns, 1, 1);
            try driveClicks(app, &timestamp_ns, 2, 2);
            try driveClicks(app, &timestamp_ns, 1, 3);
            try driveClicks(app, &timestamp_ns, 2, 4);
            try driveClicks(app, &timestamp_ns, 3, 5);
            try driveClicks(app, &timestamp_ns, 4, 6);
            try driveClicks(app, &timestamp_ns, 5, 7);
        }

        fn driveClicks(
            app: *BuiltApp,
            timestamp_ns: *i128,
            comptime tap_count: comptime_int,
            expected_callbacks_after: usize,
        ) !void {
            inline for (0..tap_count) |i| {
                try emit(app, .{
                    .origin = .manual,
                    .timestamp_ns = timestamp_ns.*,
                    .body = .{
                        .raw_single_button = .{
                            .source_id = 7,
                            .pressed = true,
                        },
                    },
                });
                timestamp_ns.* += tap_gap_ns;
                try emit(app, .{
                    .origin = .manual,
                    .timestamp_ns = timestamp_ns.*,
                    .body = .{
                        .raw_single_button = .{
                            .source_id = 7,
                            .pressed = false,
                        },
                    },
                });
                if (i + 1 < tap_count) {
                    timestamp_ns.* += tap_gap_ns;
                }
            }
            timestamp_ns.* += settle_ns;
            try emit(app, .{
                .origin = .timer,
                .timestamp_ns = timestamp_ns.*,
                .body = .{
                    .tick = .{},
                },
            });
            try waitForCallbackCount(expected_callbacks_after);
        }

        fn checkBaseState(state: button.state.Detected) bool {
            if (state.source_id != 7) {
                fail(.wrong_source_id);
                return false;
            }
            if (state.button_id != null) {
                fail(.wrong_button_id);
                return false;
            }
            if (state.gesture_kind == null) {
                fail(.missing_gesture_kind);
                return false;
            }
            return true;
        }

        fn checkClickState(state: button.state.Detected, expected_click_count: u16) void {
            if (!checkBaseState(state)) return;
            if (state.gesture_kind.? != .click) {
                fail(.wrong_gesture_kind);
                return;
            }
            if (state.click_count != expected_click_count) {
                fail(.wrong_click_count);
                return;
            }
            if (state.long_press_ns != 0) {
                fail(.wrong_long_press_ns);
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
            return error.TimedOut;
        }

        fn emit(app: *BuiltApp, message: Message) !void {
            try app.impl.runtime.pipeline.inject(message);
            while (true) {
                const recv = app.impl.runtime.pipeline.inbox.recvTimeout(0) catch |err| switch (err) {
                    error.Timeout => return,
                    else => return err,
                };
                if (!recv.ok) return;
                try app.impl.runtime.root.in.emit(recv.value);
            }
        }
    };
}

pub fn make(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
    const BuiltApp = comptime makeBuiltApp(lib, Channel);
    const Case = TestCase(lib, BuiltApp);

    const Holder = struct {
        var runner: Case = .{};
    };
    return testing_api.TestRunner.make(Case).new(&Holder.runner);
}
