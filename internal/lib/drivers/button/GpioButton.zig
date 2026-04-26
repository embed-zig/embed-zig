const glib = @import("glib");
const Gpio = @import("../Gpio.zig");

const GpioButton = @This();

pub const Config = struct {
    active_level: Gpio.Level = .low,
};

pub fn make(comptime config: Config) type {
    return struct {
        const Built = @This();

        gpio: Gpio,

        pub fn init(gpio: Gpio) Built {
            return .{
                .gpio = gpio,
            };
        }

        pub fn isPressed(self: *const Built) Gpio.Error!bool {
            const level = try self.gpio.read();
            return level == config.active_level;
        }
    };
}

pub fn TestRunner(comptime lib: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn lowLevelButtonTreatsLowAsPressed() !void {
            const Built = GpioButton.make(.{ .active_level = .low });

            const Pin = struct {
                level: Gpio.Level,

                pub fn read(self: *@This()) Gpio.Error!Gpio.Level {
                    return self.level;
                }

                pub fn write(self: *@This(), level: Gpio.Level) Gpio.Error!void {
                    self.level = level;
                }

                pub fn setDirection(_: *@This(), _: Gpio.Direction) Gpio.Error!void {}
            };

            var pin = Pin{ .level = .low };
            const button = Built.init(Gpio.init(&pin));

            try lib.testing.expect(try button.isPressed());
        }

        fn highLevelButtonTreatsHighAsPressed() !void {
            const Built = GpioButton.make(.{ .active_level = .high });

            const Pin = struct {
                pub fn read(_: *@This()) Gpio.Error!Gpio.Level {
                    return .high;
                }

                pub fn write(_: *@This(), _: Gpio.Level) Gpio.Error!void {}

                pub fn setDirection(_: *@This(), _: Gpio.Direction) Gpio.Error!void {}
            };

            var pin = Pin{};
            const button = Built.init(Gpio.init(&pin));

            try lib.testing.expect(try button.isPressed());
        }

        fn propagatesGpioErrors() !void {
            const Built = GpioButton.make(.{});

            const Pin = struct {
                pub fn read(_: *@This()) Gpio.Error!Gpio.Level {
                    return error.Timeout;
                }

                pub fn write(_: *@This(), _: Gpio.Level) Gpio.Error!void {}

                pub fn setDirection(_: *@This(), _: Gpio.Direction) Gpio.Error!void {}
            };

            var pin = Pin{};
            const button = Built.init(Gpio.init(&pin));

            try lib.testing.expectError(error.Timeout, button.isPressed());
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.lowLevelButtonTreatsLowAsPressed() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.highLevelButtonTreatsHighAsPressed() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.propagatesGpioErrors() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
