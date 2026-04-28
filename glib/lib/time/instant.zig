pub const Time = u64;
pub const Maximum: Time = 18_446_744_073_709_551_615;

const instant_type = Time;

const duration_mod = @import("duration.zig");
const Duration = duration_mod.Duration;

pub fn sub(later: Time, earlier: Time) Duration {
    if (later >= earlier) {
        const delta = later - earlier;
        if (delta > @as(u64, @intCast(duration_mod.Maximum))) return duration_mod.Maximum;
        return @intCast(delta);
    }

    const delta = earlier - later;
    if (delta > @as(u64, @intCast(duration_mod.Maximum))) return duration_mod.Minimum;
    return -@as(Duration, @intCast(delta));
}

pub fn add(instant: Time, duration: Duration) Time {
    if (duration >= 0) {
        const result, const overflowed = @addWithOverflow(instant, @as(u64, @intCast(duration)));
        return if (overflowed != 0) Maximum else result;
    }

    const delta = duration_mod.magnitude(duration);
    return if (delta >= instant) 0 else instant - delta;
}

pub fn make(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn () Time, &Impl.now);
    }

    return struct {
        pub const Time = instant_type;
        pub const Maximum = @import("instant.zig").Maximum;
        pub const sub = @import("instant.zig").sub;
        pub const add = @import("instant.zig").add;

        pub fn now() instant_type {
            return Impl.now();
        }

        pub fn since(earlier: instant_type) Duration {
            return @import("instant.zig").sub(now(), earlier);
        }
    };
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

            std.testing.expectEqual(@as(Duration, 7 * duration_mod.Second), sub(@intCast(9 * duration_mod.Second), @intCast(2 * duration_mod.Second))) catch return false;
            std.testing.expectEqual(-@as(Duration, 7 * duration_mod.Second), sub(@intCast(2 * duration_mod.Second), @intCast(9 * duration_mod.Second))) catch return false;
            std.testing.expectEqual(duration_mod.Maximum, sub(Maximum, 0)) catch return false;
            std.testing.expectEqual(duration_mod.Minimum, sub(0, Maximum)) catch return false;
            std.testing.expectEqual(@as(Time, @intCast(11 * duration_mod.Second)), add(@intCast(9 * duration_mod.Second), 2 * duration_mod.Second)) catch return false;
            std.testing.expectEqual(@as(Time, @intCast(7 * duration_mod.Second)), add(@intCast(9 * duration_mod.Second), -2 * duration_mod.Second)) catch return false;
            std.testing.expectEqual(Maximum, add(Maximum - 1, 2)) catch return false;
            std.testing.expectEqual(@as(Time, 0), add(1, -2)) catch return false;
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
