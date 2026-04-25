//! Time contract — platform-dependent timing.
//!
//! Impl must provide:
//!   fn milliTimestamp() i64
//!   fn nanoTimestamp() i128
//!   const Instant
//!
//! `Impl.Instant` should match the `std.time.Instant` surface (`now`, `order`,
//! `since`) so platform runtimes can supply their own boot-relative / uptime
//! notion directly.
//!
//! `nanoTimestamp()` is the monotonic nanosecond source for `Timer` and for
//! timeout/deadline calculations built on top of `stdz.time`.

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

fn verifyInstantInterface(comptime Instant: type) void {
    if (@TypeOf(Instant) != type) {
        @compileError("stdz.time.make requires Impl.Instant to be a type");
    }

    if (!@hasDecl(Instant, "now")) {
        @compileError("stdz.time.make requires Impl.Instant.now");
    }
    if (!@hasDecl(Instant, "order")) {
        @compileError("stdz.time.make requires Impl.Instant.order");
    }
    if (!@hasDecl(Instant, "since")) {
        @compileError("stdz.time.make requires Impl.Instant.since");
    }

    _ = @as(*const fn () anyerror!Instant, &Instant.now);
    _ = @as(*const fn (Instant, Instant) zig_std.math.Order, &Instant.order);
    _ = @as(*const fn (Instant, Instant) u64, &Instant.since);
}

pub fn make(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn () i64, &Impl.milliTimestamp);
        _ = @as(*const fn () i128, &Impl.nanoTimestamp);
        if (!@hasDecl(Impl, "Instant")) {
            @compileError("stdz.time.make requires Impl.Instant with a std.time.Instant-shaped interface");
        }
        verifyInstantInterface(Impl.Instant);
    }

    return struct {
        const Self = @This();

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

        pub const Instant = Impl.Instant;

        /// Timer driven by the monotonic `nanoTimestamp()` backend. Returns
        /// elapsed nanoseconds. Clamps to the last seen value on backward
        /// jumps so consumers never observe negative elapsed time if a backend
        /// violates that contract.
        pub const Timer = struct {
            started: i128,
            previous: i128,

            /// Kept as a std-shaped error union even though the current
            /// `stdz.time` contract only requires timestamp functions and
            /// therefore has no active runtime start-failure path today.
            pub const Error = std_compat.Timer.Error;

            pub fn start() Error!Timer {
                const now = Impl.nanoTimestamp();
                return .{ .started = now, .previous = now };
            }

            /// Nanoseconds since start or last reset.
            pub fn read(self: *Timer) u64 {
                const current = self.sample();
                return Self.elapsedSince(self.started, current);
            }

            /// Reset the start point to now.
            pub fn reset(self: *Timer) void {
                self.started = self.sample();
            }

            /// Return nanoseconds since start, then reset.
            pub fn lap(self: *Timer) u64 {
                const current = self.sample();
                defer self.started = current;
                return Self.elapsedSince(self.started, current);
            }

            fn sample(self: *Timer) i128 {
                const current = Impl.nanoTimestamp();
                if (current > self.previous) {
                    self.previous = current;
                }
                return self.previous;
            }

        };

        fn elapsedSince(started: i128, current: i128) u64 {
            if (current <= started) return 0;

            const delta_ns, const overflowed = @subWithOverflow(current, started);
            if (overflowed != 0) return zig_std.math.maxInt(u64);
            return Self.elapsedToU64(delta_ns);
        }

        fn elapsedToU64(delta_ns: i128) u64 {
            if (delta_ns <= 0) return 0;

            const max_u64_ns: i128 = @intCast(zig_std.math.maxInt(u64));
            if (delta_ns >= max_u64_ns) return zig_std.math.maxInt(u64);

            return @intCast(delta_ns);
        }
    };
}

