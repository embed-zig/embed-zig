const testing_api = @import("testing");

const Assembler = @import("../../../../Assembler.zig");
const button = @import("../../../../component/button.zig");
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

fn MockGpioImpl(comptime lib: type) type {
    return struct {
        mu: lib.Thread.Mutex = .{},
        level: drivers.Gpio.Level = .high,

        pub fn read(self: *@This()) drivers.Gpio.Error!drivers.Gpio.Level {
            self.mu.lock();
            defer self.mu.unlock();
            return self.level;
        }

        pub fn write(self: *@This(), level: drivers.Gpio.Level) drivers.Gpio.Error!void {
            self.mu.lock();
            defer self.mu.unlock();
            self.level = level;
        }

        pub fn setDirection(_: *@This(), _: drivers.Gpio.Direction) drivers.Gpio.Error!void {
        }

        pub fn setLevel(self: *@This(), level: drivers.Gpio.Level) void {
            self.mu.lock();
            defer self.mu.unlock();
            self.level = level;
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

        var callback_mu: lib.Thread.Mutex = .{};
        var callback_calls: usize = 0;
        var callback_failure: ?Failure = null;
        const expected_callback_count = 9;

        pub fn init(self: *Self, allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
            reset();
        }

        pub fn run(self: *Self, t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;

            const MockGpio = MockGpioImpl(lib);
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

            app.start() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };

            driveSequence(&app, &mock_gpio_impl) catch |err| {
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

        pub fn onButton(stores: *BuiltApp.Store.Stores) void {
            callback_mu.lock();
            defer callback_mu.unlock();

            callback_calls += 1;
            const state = stores.buttons.get();
            switch (callback_calls) {
                1 => checkClickStateLocked(state, 1),
                2 => checkClickStateLocked(state, 2),
                3 => checkLongPressStateLocked(state),
                4 => checkClickStateLocked(state, 1),
                5 => checkClickStateLocked(state, 2),
                6 => checkClickStateLocked(state, 3),
                7 => checkClickStateLocked(state, 4),
                8 => checkClickStateLocked(state, 5),
                9 => checkLongPressStateLocked(state),
                else => failLocked(.unexpected_callback_count),
            }
        }

        fn driveSequence(app: *BuiltApp, mock_gpio: anytype) !void {
            try driveClicks(app, mock_gpio, 1, 1);
            try driveClicks(app, mock_gpio, 2, 2);
            try driveLongPress1(app, mock_gpio, 3);
            try driveClicks(app, mock_gpio, 1, 4);
            try driveClicks(app, mock_gpio, 2, 5);
            try driveClicks(app, mock_gpio, 3, 6);
            try driveClicks(app, mock_gpio, 4, 7);
            try driveClicks(app, mock_gpio, 5, 8);
            try driveLongPress1(app, mock_gpio, 9);
        }

        fn driveClicks(
            app: *BuiltApp,
            mock_gpio: anytype,
            comptime tap_count: comptime_int,
            expected_callbacks_after: usize,
        ) !void {
            inline for (0..tap_count) |i| {
                mock_gpio.setLevel(.low);
                try app.press_single_button(.buttons);
                lib.Thread.sleep(20 * lib.time.ns_per_ms);
                mock_gpio.setLevel(.high);
                try app.release_single_button(.buttons);
                if (i + 1 < tap_count) {
                    lib.Thread.sleep(20 * lib.time.ns_per_ms);
                }
            }
            lib.Thread.sleep(button.Reducer.default_multi_click_window_ns + (100 * lib.time.ns_per_ms));
            try waitForCallbackCount(expected_callbacks_after);
        }

        fn driveLongPress1(app: *BuiltApp, mock_gpio: anytype, expected_callbacks_after: usize) !void {
            mock_gpio.setLevel(.low);
            try app.press_single_button(.buttons);
            lib.Thread.sleep(1200 * lib.time.ns_per_ms);
            mock_gpio.setLevel(.high);
            try app.release_single_button(.buttons);
            lib.Thread.sleep(100 * lib.time.ns_per_ms);
            try waitForCallbackCount(expected_callbacks_after);
        }

        fn checkBaseStateLocked(state: button.state.Detected) bool {
            if (state.source_id != 7) {
                failLocked(.wrong_source_id);
                return false;
            }
            if (state.button_id != null) {
                failLocked(.wrong_button_id);
                return false;
            }
            if (state.gesture_kind == null) {
                failLocked(.missing_gesture_kind);
                return false;
            }
            return true;
        }

        fn checkClickStateLocked(state: button.state.Detected, expected_click_count: u16) void {
            if (!checkBaseStateLocked(state)) return;
            if (state.gesture_kind.? != .click) {
                failLocked(.wrong_gesture_kind);
                return;
            }
            if (state.click_count != expected_click_count) {
                failLocked(.wrong_click_count);
                return;
            }
            if (state.long_press_ns != 0) {
                failLocked(.wrong_long_press_ns);
            }
        }

        fn checkLongPressStateLocked(state: button.state.Detected) void {
            if (!checkBaseStateLocked(state)) return;
            if (state.gesture_kind.? != .long_press) {
                failLocked(.wrong_gesture_kind);
                return;
            }
            if (state.click_count != 0) {
                failLocked(.wrong_click_count);
                return;
            }
            if (state.long_press_ns < button.Reducer.default_long_press_ns) {
                failLocked(.wrong_long_press_ns);
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
                if (currentFailure() != null) return error.CallbackFailed;
                if (currentCallbackCalls() >= expected) return;
                lib.Thread.sleep(10 * lib.time.ns_per_ms);
            }
            return error.TimedOut;
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
