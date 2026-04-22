const Adc = @import("../Adc.zig");
const testing_api = @import("testing");

const AdcButton = @This();

pub const BuilderConfig = struct {
    button_count: usize = 16,
};

pub const Range = struct {
    min_voltage: f32,
    max_voltage: f32,

    pub fn contains(self: Range, voltage: f32) bool {
        return voltage >= self.min_voltage and voltage <= self.max_voltage;
    }

    fn overlaps(self: Range, other: Range) bool {
        return self.min_voltage <= other.max_voltage and other.min_voltage <= self.max_voltage;
    }
};

pub fn Builder(comptime config: BuilderConfig) blk: {
    if (config.button_count == 0) {
        @compileError("drivers.button.AdcButton.Builder button_count must be > 0");
    }

    break :blk struct {
        const Self = @This();

        ranges: [config.button_count]Range = undefined,
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn addRange(self: *Self, comptime min_voltage: f32, comptime max_voltage: f32) void {
            if (self.len >= config.button_count) {
                @compileError("drivers.button.AdcButton.Builder exceeded button_count");
            }

            if (max_voltage < min_voltage) {
                @compileError("drivers.button.AdcButton.Builder.addRange requires max_voltage >= min_voltage");
            }

            const next: Range = .{
                .min_voltage = min_voltage,
                .max_voltage = max_voltage,
            };

            inline for (self.ranges[0..self.len]) |range| {
                if (range.overlaps(next)) {
                    @compileError("drivers.button.AdcButton.Builder.addRange cannot add overlapping voltage ranges");
                }
            }

            self.ranges[self.len] = next;
            self.len += 1;
        }

        pub fn build(comptime builder: Self) type {
            if (builder.len == 0) {
                @compileError("drivers.button.AdcButton.Builder.build requires at least one range");
            }

            const ranges = builder.ranges[0..builder.len];
            return struct {
                const Built = @This();

                pub const range_count: usize = ranges.len;

                adc: Adc,

                pub fn init(adc: Adc) Built {
                    return .{
                        .adc = adc,
                    };
                }

                pub fn readVoltage(self: *const Built) Adc.Error!f32 {
                    return self.adc.readVoltage();
                }

                pub fn buttonCount(_: *const Built) usize {
                    return ranges.len;
                }

                pub fn pressedButton(self: *const Built) Adc.Error!?u32 {
                    const voltage = try self.adc.readVoltage();
                    inline for (ranges, 0..) |range, idx| {
                        if (range.contains(voltage)) return @intCast(idx);
                    }
                    return null;
                }
            };
        }
    };
} {
    return .{};
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn builderSelectsButtonIdByVoltage() !void {
            const Built = comptime blk: {
                var builder = AdcButton.Builder(.{});
                builder.addRange(0.10, 0.30);
                builder.addRange(1.00, 1.15);
                builder.addRange(1.80, 2.00);
                break :blk builder.build();
            };

            const Reader = struct {
                voltage: f32,

                pub fn readVoltage(self: *@This()) Adc.Error!f32 {
                    return self.voltage;
                }
            };

            var reader = Reader{ .voltage = 1.08 };
            const adc = Adc.init(&reader);
            const button = Built.init(adc);

            try lib.testing.expectEqual(@as(usize, 3), button.buttonCount());
            try lib.testing.expectEqual(@as(?u32, 1), try button.pressedButton());
            try lib.testing.expectEqual(@as(usize, 3), Built.range_count);
        }

        fn outOfRangeVoltageMeansNotPressed() !void {
            const Built = comptime blk: {
                var builder = AdcButton.Builder(.{});
                builder.addRange(0.10, 0.30);
                builder.addRange(1.00, 1.15);
                break :blk builder.build();
            };

            const Reader = struct {
                pub fn readVoltage(_: *@This()) Adc.Error!f32 {
                    return 2.50;
                }
            };

            var reader = Reader{};
            const adc = Adc.init(&reader);
            const button = Built.init(adc);

            try lib.testing.expectEqual(@as(usize, 2), button.buttonCount());
            try lib.testing.expectEqual(@as(?u32, null), try button.pressedButton());
        }

        fn propagatesAdcErrors() !void {
            const Built = comptime blk: {
                var builder = AdcButton.Builder(.{ .button_count = 1 });
                builder.addRange(0.10, 0.30);
                break :blk builder.build();
            };

            const Reader = struct {
                pub fn readVoltage(_: *@This()) Adc.Error!f32 {
                    return error.Timeout;
                }
            };

            var reader = Reader{};
            const adc = Adc.init(&reader);
            const button = Built.init(adc);

            try lib.testing.expectError(error.Timeout, button.pressedButton());
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.builderSelectsButtonIdByVoltage() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.outOfRangeVoltageMeansNotPressed() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.propagatesAdcErrors() catch |err| {
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
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
