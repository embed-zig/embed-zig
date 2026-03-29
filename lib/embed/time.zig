//! Time contract — platform-dependent timing.
//!
//! Impl must provide:
//!   fn milliTimestamp() i64
//!   fn nanoTimestamp() i128
//!
//! `nanoTimestamp()` is the monotonic nanosecond source for `Timer` and for
//! timeout/deadline calculations built on top of `embed.time`.

const zig_std = @import("std");

const re_export = struct {
    const std = @import("std");

    pub const ns_per_us = std.time.ns_per_us;
    pub const ns_per_ms = std.time.ns_per_ms;
    pub const ns_per_s = std.time.ns_per_s;
    pub const ns_per_min = std.time.ns_per_min;
    pub const ns_per_hour = std.time.ns_per_hour;
    pub const ns_per_day = std.time.ns_per_day;
    pub const ns_per_week = std.time.ns_per_week;

    pub const us_per_ms = std.time.us_per_ms;
    pub const us_per_s = std.time.us_per_s;
    pub const us_per_min = std.time.us_per_min;
    pub const us_per_hour = std.time.us_per_hour;
    pub const us_per_day = std.time.us_per_day;
    pub const us_per_week = std.time.us_per_week;

    pub const ms_per_s = std.time.ms_per_s;
    pub const ms_per_min = std.time.ms_per_min;
    pub const ms_per_hour = std.time.ms_per_hour;
    pub const ms_per_day = std.time.ms_per_day;
    pub const ms_per_week = std.time.ms_per_week;

    pub const s_per_min = std.time.s_per_min;
    pub const s_per_hour = std.time.s_per_hour;
    pub const s_per_day = std.time.s_per_day;
    pub const s_per_week = std.time.s_per_week;
};

const std_compat = struct {
    pub const Timer = struct {
        pub const Error = error{TimerUnsupported};
    };
};

pub const ns_per_us = re_export.ns_per_us;
pub const ns_per_ms = re_export.ns_per_ms;
pub const ns_per_s = re_export.ns_per_s;
pub const ns_per_min = re_export.ns_per_min;
pub const ns_per_hour = re_export.ns_per_hour;
pub const ns_per_day = re_export.ns_per_day;
pub const ns_per_week = re_export.ns_per_week;

pub const us_per_ms = re_export.us_per_ms;
pub const us_per_s = re_export.us_per_s;
pub const us_per_min = re_export.us_per_min;
pub const us_per_hour = re_export.us_per_hour;
pub const us_per_day = re_export.us_per_day;
pub const us_per_week = re_export.us_per_week;

pub const ms_per_s = re_export.ms_per_s;
pub const ms_per_min = re_export.ms_per_min;
pub const ms_per_hour = re_export.ms_per_hour;
pub const ms_per_day = re_export.ms_per_day;
pub const ms_per_week = re_export.ms_per_week;

pub const s_per_min = re_export.s_per_min;
pub const s_per_hour = re_export.s_per_hour;
pub const s_per_day = re_export.s_per_day;
pub const s_per_week = re_export.s_per_week;

pub fn make(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn () i64, &Impl.milliTimestamp);
        _ = @as(*const fn () i128, &Impl.nanoTimestamp);
    }

    return struct {
        pub const ns_per_us = re_export.ns_per_us;
        pub const ns_per_ms = re_export.ns_per_ms;
        pub const ns_per_s = re_export.ns_per_s;
        pub const ns_per_min = re_export.ns_per_min;
        pub const ns_per_hour = re_export.ns_per_hour;
        pub const ns_per_day = re_export.ns_per_day;
        pub const ns_per_week = re_export.ns_per_week;

        pub const us_per_ms = re_export.us_per_ms;
        pub const us_per_s = re_export.us_per_s;
        pub const us_per_min = re_export.us_per_min;
        pub const us_per_hour = re_export.us_per_hour;
        pub const us_per_day = re_export.us_per_day;
        pub const us_per_week = re_export.us_per_week;

        pub const ms_per_s = re_export.ms_per_s;
        pub const ms_per_min = re_export.ms_per_min;
        pub const ms_per_hour = re_export.ms_per_hour;
        pub const ms_per_day = re_export.ms_per_day;
        pub const ms_per_week = re_export.ms_per_week;

        pub const s_per_min = re_export.s_per_min;
        pub const s_per_hour = re_export.s_per_hour;
        pub const s_per_day = re_export.s_per_day;
        pub const s_per_week = re_export.s_per_week;

        pub fn milliTimestamp() i64 {
            return Impl.milliTimestamp();
        }

        pub fn nanoTimestamp() i128 {
            return Impl.nanoTimestamp();
        }

        /// Timer driven by the monotonic `nanoTimestamp()` backend. Returns
        /// elapsed nanoseconds. Clamps to the last seen value on backward
        /// jumps so consumers never observe negative elapsed time if a backend
        /// violates that contract.
        pub const Timer = struct {
            started: i128,
            previous: i128,

            pub const Error = std_compat.Timer.Error;

            pub fn start() Error!Timer {
                const now = Impl.nanoTimestamp();
                return .{ .started = now, .previous = now };
            }

            /// Nanoseconds since start or last reset.
            pub fn read(self: *Timer) u64 {
                const current = self.sample();
                return elapsedToU64(current - self.started);
            }

            /// Reset the start point to now.
            pub fn reset(self: *Timer) void {
                self.started = self.sample();
            }

            /// Return nanoseconds since start, then reset.
            pub fn lap(self: *Timer) u64 {
                const current = self.sample();
                defer self.started = current;
                return elapsedToU64(current - self.started);
            }

            fn sample(self: *Timer) i128 {
                const current = Impl.nanoTimestamp();
                if (current > self.previous) {
                    self.previous = current;
                }
                return self.previous;
            }

            fn elapsedToU64(delta_ns: i128) u64 {
                if (delta_ns <= 0) return 0;

                const max_u64_ns: i128 = @intCast(zig_std.math.maxInt(u64));
                if (delta_ns >= max_u64_ns) return zig_std.math.maxInt(u64);

                return @intCast(delta_ns);
            }
        };
    };
}

test "embed/unit_tests/time/Timer_clamps_backward_jumps" {
    const Impl = struct {
        pub var index: usize = 0;
        pub const samples = [_]i128{ 100, 110, 105, 120, 115 };

        pub fn milliTimestamp() i64 {
            return 0;
        }

        pub fn nanoTimestamp() i128 {
            defer index += 1;
            return samples[index];
        }
    };

    const time = make(Impl);
    Impl.index = 0;

    var timer = try time.Timer.start();
    try zig_std.testing.expectEqual(@as(u64, 10), timer.read());
    try zig_std.testing.expectEqual(@as(u64, 10), timer.read());
    try zig_std.testing.expectEqual(@as(u64, 20), timer.lap());
    try zig_std.testing.expectEqual(@as(u64, 0), timer.read());
}

test "embed/unit_tests/time/Timer_saturates_elapsed_to_u64_max" {
    const max_u64_ns: i128 = @intCast(zig_std.math.maxInt(u64));
    const Impl = struct {
        pub var index: usize = 0;
        pub const samples = [_]i128{ 0, max_u64_ns + 123 };

        pub fn milliTimestamp() i64 {
            return 0;
        }

        pub fn nanoTimestamp() i128 {
            defer index += 1;
            return samples[index];
        }
    };

    const time = make(Impl);
    Impl.index = 0;

    var timer = try time.Timer.start();
    try zig_std.testing.expectEqual(zig_std.math.maxInt(u64), timer.read());
}
