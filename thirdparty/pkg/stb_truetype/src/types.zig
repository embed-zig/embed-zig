const glib = @import("glib");
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

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
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

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = allocator;
            grt.std.testing.allocator.destroy(self);
        }

        fn runBitmapBoxDimensions() !void {
            const box = BitmapBox{
                .x0 = -3,
                .y0 = -7,
                .x1 = 9,
                .y1 = 5,
            };

            try grt.std.testing.expectEqual(@as(i32, 12), box.width());
            try grt.std.testing.expectEqual(@as(i32, 12), box.height());
        }

        fn runBitmapBoxDimensionsPreserveNegativeRanges() !void {
            const box = BitmapBox{
                .x0 = 10,
                .y0 = 8,
                .x1 = 3,
                .y1 = 1,
            };

            try grt.std.testing.expectEqual(@as(i32, -7), box.width());
            try grt.std.testing.expectEqual(@as(i32, -7), box.height());
        }
    };

    const runner = grt.std.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return glib.testing.TestRunner.make(Runner).new(runner);
}
