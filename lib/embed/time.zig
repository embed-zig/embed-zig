//! Time contract — platform-dependent timing.
//!
//! Impl must provide:
//!   fn milliTimestamp() i64

const std = @import("std");

pub fn make(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn () i64, &Impl.milliTimestamp);
    }

    return struct {
        pub const ns_per_ms = std.time.ns_per_ms;

        pub fn milliTimestamp() i64 {
            return Impl.milliTimestamp();
        }

        /// Monotonic timer driven by milliTimestamp. Returns elapsed
        /// milliseconds. Clamps to the last seen value on backward jumps.
        pub const Timer = struct {
            started: i64,
            previous: i64,

            pub fn start() Timer {
                const now = Impl.milliTimestamp();
                return .{ .started = now, .previous = now };
            }

            /// Milliseconds since start or last reset.
            pub fn read(self: *Timer) u64 {
                const current = self.sample();
                return @intCast(current - self.started);
            }

            /// Reset the start point to now.
            pub fn reset(self: *Timer) void {
                self.started = self.sample();
            }

            /// Return milliseconds since start, then reset.
            pub fn lap(self: *Timer) u64 {
                const current = self.sample();
                defer self.started = current;
                return @intCast(current - self.started);
            }

            fn sample(self: *Timer) i64 {
                const current = Impl.milliTimestamp();
                if (current > self.previous) {
                    self.previous = current;
                }
                return self.previous;
            }
        };
    };
}
