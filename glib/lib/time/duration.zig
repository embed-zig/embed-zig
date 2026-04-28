pub const Duration = i64;
pub const Maximum: Duration = 9_223_372_036_854_775_807;
pub const Minimum: Duration = -9_223_372_036_854_775_808;

pub const NanoSecond: Duration = 1;
pub const MicroSecond: Duration = 1_000 * NanoSecond;
pub const MilliSecond: Duration = 1_000 * MicroSecond;
pub const Second: Duration = 1_000 * MilliSecond;
pub const Minute: Duration = 60 * Second;
pub const Hour: Duration = 60 * Minute;
pub const Day: Duration = 24 * Hour;
pub const Week: Duration = 7 * Day;

pub fn magnitude(duration: Duration) u64 {
    if (duration == Minimum) {
        return @as(u64, @intCast(Maximum)) + 1;
    }
    if (duration < 0) {
        return @intCast(-duration);
    }
    return @intCast(duration);
}

pub fn TestRunner(comptime std: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), _: *testing_api.T, _: std.mem.Allocator) bool {
            _ = self;

            std.testing.expectEqual(@as(Duration, 1), NanoSecond) catch return false;
            std.testing.expectEqual(@as(Duration, 1_000), MicroSecond) catch return false;
            std.testing.expectEqual(@as(Duration, 1_000_000), MilliSecond) catch return false;
            std.testing.expectEqual(@as(Duration, 1_000_000_000), Second) catch return false;
            std.testing.expectEqual(@as(Duration, 60_000_000_000), Minute) catch return false;
            std.testing.expectEqual(@as(Duration, 3_600_000_000_000), Hour) catch return false;
            std.testing.expectEqual(@as(u64, 42), magnitude(42)) catch return false;
            std.testing.expectEqual(@as(u64, 42), magnitude(-42)) catch return false;
            std.testing.expectEqual(@as(u64, 9_223_372_036_854_775_808), magnitude(Minimum)) catch return false;
            return true;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
