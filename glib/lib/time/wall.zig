const duration_mod = @import("duration.zig");

const Duration = duration_mod.Duration;

const nanos_per_second: i128 = duration_mod.Second;
const nanos_per_milli: i128 = duration_mod.MilliSecond;
const nanos_per_micro: i128 = duration_mod.MicroSecond;
const millis_per_second: i128 = duration_mod.Second / duration_mod.MilliSecond;
const micros_per_second: i128 = duration_mod.Second / duration_mod.MicroSecond;
const max_i64: i64 = 9_223_372_036_854_775_807;
const min_i64: i64 = -9_223_372_036_854_775_808;

pub const Time = struct {
    sec: i64 = 0,
    nsec: u32 = 0,

    pub const Order = enum {
        lt,
        eq,
        gt,
    };

    pub fn unix(self: Time) i64 {
        return self.sec;
    }

    pub fn unixMilli(self: Time) i64 {
        return clampI64(@as(i128, self.sec) * millis_per_second + @divFloor(self.nsec, nanos_per_milli));
    }

    pub fn unixMicro(self: Time) i64 {
        return clampI64(@as(i128, self.sec) * micros_per_second + @divFloor(self.nsec, nanos_per_micro));
    }

    pub fn unixNano(self: Time) i128 {
        return @as(i128, self.sec) * nanos_per_second + self.nsec;
    }

    pub fn add(self: Time, duration: Duration) Time {
        return fromUnixNano(self.unixNano() + duration);
    }

    pub fn sub(self: Time, earlier: Time) Duration {
        return clampDuration(self.unixNano() - earlier.unixNano());
    }

    pub fn cmp(self: Time, other: Time) Order {
        if (self.sec < other.sec) return .lt;
        if (self.sec > other.sec) return .gt;
        if (self.nsec < other.nsec) return .lt;
        if (self.nsec > other.nsec) return .gt;
        return .eq;
    }

    pub fn before(self: Time, other: Time) bool {
        return self.cmp(other) == .lt;
    }

    pub fn after(self: Time, other: Time) bool {
        return self.cmp(other) == .gt;
    }

    pub fn equal(self: Time, other: Time) bool {
        return self.sec == other.sec and self.nsec == other.nsec;
    }

    pub fn isZero(self: Time) bool {
        return self.equal(.{});
    }
};

pub const Maximum: Time = .{
    .sec = max_i64,
    .nsec = @intCast(nanos_per_second - 1),
};

pub const Minimum: Time = .{
    .sec = min_i64,
    .nsec = 0,
};

pub fn unix(sec: i64, nsec: i64) Time {
    return normalize(@as(i128, sec), nsec);
}

pub fn fromUnixMilli(timestamp: i64) Time {
    return fromUnixNano(@as(i128, timestamp) * duration_mod.MilliSecond);
}

pub fn fromUnixMicro(timestamp: i64) Time {
    return fromUnixNano(@as(i128, timestamp) * duration_mod.MicroSecond);
}

pub fn fromUnixNano(timestamp: i128) Time {
    return normalize(@divFloor(timestamp, nanos_per_second), @mod(timestamp, nanos_per_second));
}

fn normalize(sec: i128, nsec: i128) Time {
    const normalized_sec = sec + @divFloor(nsec, nanos_per_second);
    const normalized_nsec = @mod(nsec, nanos_per_second);

    if (normalized_sec > max_i64) return Maximum;
    if (normalized_sec < min_i64) return Minimum;

    return .{
        .sec = @intCast(normalized_sec),
        .nsec = @intCast(normalized_nsec),
    };
}

fn clampDuration(value: i128) Duration {
    if (value > duration_mod.Maximum) return duration_mod.Maximum;
    if (value < duration_mod.Minimum) return duration_mod.Minimum;
    return @intCast(value);
}

fn clampI64(value: i128) i64 {
    if (value > max_i64) return max_i64;
    if (value < min_i64) return min_i64;
    return @intCast(value);
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

            const t = unix(1, 234_567_890);
            std.testing.expectEqual(@as(i64, 1), t.unix()) catch return false;
            std.testing.expectEqual(@as(i64, 1_234), t.unixMilli()) catch return false;
            std.testing.expectEqual(@as(i64, 1_234_567), t.unixMicro()) catch return false;
            std.testing.expectEqual(@as(i128, 1_234_567_890), t.unixNano()) catch return false;
            std.testing.expect(fromUnixMilli(1_234).equal(unix(1, 234_000_000))) catch return false;
            std.testing.expect(fromUnixMicro(1_234_567).equal(unix(1, 234_567_000))) catch return false;

            const normalized = unix(1, 1_500_000_000);
            std.testing.expectEqual(@as(i64, 2), normalized.sec) catch return false;
            std.testing.expectEqual(@as(u32, 500_000_000), normalized.nsec) catch return false;

            const negative_normalized = unix(1, -1);
            std.testing.expectEqual(@as(i64, 0), negative_normalized.sec) catch return false;
            std.testing.expectEqual(@as(u32, 999_999_999), negative_normalized.nsec) catch return false;

            const negative = fromUnixNano(-1);
            std.testing.expectEqual(@as(i64, -1), negative.sec) catch return false;
            std.testing.expectEqual(@as(u32, 999_999_999), negative.nsec) catch return false;
            std.testing.expectEqual(@as(i128, -1), negative.unixNano()) catch return false;
            std.testing.expect(fromUnixNano(@as(i128, max_i64) * duration_mod.Second + duration_mod.Second).equal(Maximum)) catch return false;
            std.testing.expect(fromUnixNano(@as(i128, min_i64) * duration_mod.Second - duration_mod.Second).equal(Minimum)) catch return false;

            const later = t.add(2 * duration_mod.Second);
            std.testing.expectEqual(Time.Order.lt, t.cmp(later)) catch return false;
            std.testing.expectEqual(Time.Order.eq, t.cmp(unix(1, 234_567_890))) catch return false;
            std.testing.expectEqual(Time.Order.gt, later.cmp(t)) catch return false;
            std.testing.expect(later.after(t)) catch return false;
            std.testing.expect(t.before(later)) catch return false;
            std.testing.expect(later.equal(unix(3, 234_567_890))) catch return false;
            std.testing.expectEqual(@as(Duration, 2 * duration_mod.Second), later.sub(t)) catch return false;
            std.testing.expectEqual(duration_mod.Maximum, Maximum.sub(Minimum)) catch return false;
            std.testing.expectEqual(duration_mod.Minimum, Minimum.sub(Maximum)) catch return false;
            std.testing.expect(t.isZero() == false) catch return false;
            std.testing.expect((Time{}).isZero()) catch return false;
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
