//! Runtime-owned sleep and delay contract.
//!
//! `sleep` accepts `time.duration.Duration`. Zero and negative durations return
//! immediately without calling the backend. Positive durations are treated as a
//! minimum sleep: platform implementations may round up to their scheduler tick.
//! `sleepMillis` and `sleepNanos` are convenience helpers for low-level callers.

const duration_mod = @import("duration.zig");

const Duration = duration_mod.Duration;

pub fn make(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn (u64) void, &Impl.sleep);
    }

    return struct {
        pub fn sleep(duration: Duration) void {
            if (duration <= 0) return;
            Impl.sleep(@intCast(duration));
        }

        pub fn sleepMillis(ms: u64) void {
            sleepNanos(saturatingMul(ms, @intCast(duration_mod.MilliSecond)));
        }

        pub fn sleepNanos(ns: u64) void {
            if (ns == 0) return;
            Impl.sleep(ns);
        }
    };
}

fn saturatingMul(a: u64, b: u64) u64 {
    const result, const overflowed = @mulWithOverflow(a, b);
    return if (overflowed != 0) max_u64 else result;
}

const max_u64: u64 = 0xffff_ffff_ffff_ffff;

pub fn TestRunner(comptime std: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const TestCase = struct {
        const FakeImpl = struct {
            var sleep_calls: usize = 0;
            var last_ns: u64 = 0;

            pub fn reset() void {
                sleep_calls = 0;
                last_ns = 0;
            }

            pub fn sleep(ns: u64) void {
                sleep_calls += 1;
                last_ns = ns;
            }
        };

        const Sleep = make(FakeImpl);

        fn zeroAndNegativeDurationsReturnImmediately() !void {
            FakeImpl.reset();

            Sleep.sleep(0);
            Sleep.sleep(-1);
            Sleep.sleepNanos(0);
            Sleep.sleepMillis(0);

            try std.testing.expectEqual(@as(usize, 0), FakeImpl.sleep_calls);
        }

        fn durationSleepsAsNanoseconds() !void {
            FakeImpl.reset();

            Sleep.sleep(42 * duration_mod.MicroSecond);

            try std.testing.expectEqual(@as(usize, 1), FakeImpl.sleep_calls);
            try std.testing.expectEqual(@as(u64, @intCast(42 * duration_mod.MicroSecond)), FakeImpl.last_ns);
        }

        fn helpersConvertToNanoseconds() !void {
            FakeImpl.reset();

            Sleep.sleepMillis(2);
            try std.testing.expectEqual(@as(usize, 1), FakeImpl.sleep_calls);
            try std.testing.expectEqual(@as(u64, @intCast(2 * duration_mod.MilliSecond)), FakeImpl.last_ns);

            Sleep.sleepNanos(7);
            try std.testing.expectEqual(@as(usize, 2), FakeImpl.sleep_calls);
            try std.testing.expectEqual(@as(u64, 7), FakeImpl.last_ns);
        }

        fn millisOverflowSaturates() !void {
            FakeImpl.reset();

            Sleep.sleepMillis(std.math.maxInt(u64));

            try std.testing.expectEqual(@as(usize, 1), FakeImpl.sleep_calls);
            try std.testing.expectEqual(std.math.maxInt(u64), FakeImpl.last_ns);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.zeroAndNegativeDurationsReturnImmediately() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.durationSleepsAsNanoseconds() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.helpersConvertToNanoseconds() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.millisOverflowSaturates() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
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
