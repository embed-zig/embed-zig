//! Time contract — platform-dependent timing.
//!
//! Impl must provide:
//!   fn milliTimestamp() i64
//!   fn nanoTimestamp() i128

const std = @import("std_re_export.zig");
const std_compat = @import("std_compat.zig");

pub fn make(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn () i64, &Impl.milliTimestamp);
        _ = @as(*const fn () i128, &Impl.nanoTimestamp);
    }

    return struct {
        pub const ns_per_ms = std.time.ns_per_ms;

        pub fn milliTimestamp() i64 {
            return Impl.milliTimestamp();
        }

        pub fn nanoTimestamp() i128 {
            return Impl.nanoTimestamp();
        }

        /// Monotonic timer driven by nanoTimestamp. Returns elapsed
        /// nanoseconds. Clamps to the last seen value on backward jumps.
        pub const Timer = struct {
            started: i128,
            previous: i128,

            pub const Error = std_compat.time.Timer.Error;

            pub fn start() Error!Timer {
                const now = Impl.nanoTimestamp();
                return .{ .started = now, .previous = now };
            }

            /// Nanoseconds since start or last reset.
            pub fn read(self: *Timer) u64 {
                const current = self.sample();
                return @intCast(current - self.started);
            }

            /// Reset the start point to now.
            pub fn reset(self: *Timer) void {
                self.started = self.sample();
            }

            /// Return nanoseconds since start, then reset.
            pub fn lap(self: *Timer) u64 {
                const current = self.sample();
                defer self.started = current;
                return @intCast(current - self.started);
            }

            fn sample(self: *Timer) i128 {
                const current = Impl.nanoTimestamp();
                if (current > self.previous) {
                    self.previous = current;
                }
                return self.previous;
            }
        };
    };
}
