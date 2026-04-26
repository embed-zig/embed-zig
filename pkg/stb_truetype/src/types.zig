pub const VMetrics = struct {
    ascent: i32,
    descent: i32,
    line_gap: i32,
};

pub const HMetrics = struct {
    advance_width: i32,
    left_side_bearing: i32,
};

pub const BitmapBox = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    /// Signed width delta from `x0` to `x1`.
    ///
    /// Callers should confirm the result is positive before casting to an
    /// unsigned size for bitmap allocation.
    pub fn width(self: @This()) i32 {
        return self.x1 - self.x0;
    }

    /// Signed height delta from `y0` to `y1`.
    ///
    /// Callers should confirm the result is positive before casting to an
    /// unsigned size for bitmap allocation.
    pub fn height(self: @This()) i32 {
        return self.y1 - self.y0;
    }
};

pub fn TestRunner(comptime lib: type) @import("testing").TestRunner {
    const embed = @import("embed");
    const testing_api = @import("testing");

    const Runner = struct {
        const testing = lib.testing;

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            runBitmapBoxDimensions() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            runBitmapBoxDimensionsPreserveNegativeRanges() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }

        fn runBitmapBoxDimensions() !void {
            const box = BitmapBox{
                .x0 = -3,
                .y0 = -7,
                .x1 = 9,
                .y1 = 5,
            };

            try testing.expectEqual(@as(i32, 12), box.width());
            try testing.expectEqual(@as(i32, 12), box.height());
        }

        fn runBitmapBoxDimensionsPreserveNegativeRanges() !void {
            const box = BitmapBox{
                .x0 = 10,
                .y0 = 8,
                .x1 = 3,
                .y1 = 1,
            };

            try testing.expectEqual(@as(i32, -7), box.width());
            try testing.expectEqual(@as(i32, -7), box.height());
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}
