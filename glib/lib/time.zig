//! time — wall-clock and monotonic time helpers.
//!
//! This package is independent from `stdz`. Platform code supplies the
//! wall-clock and monotonic clock implementations through `time.make(...)`.

const duration_mod = @import("time/duration.zig");
const instant_mod = @import("time/instant.zig");
const wall_mod = @import("time/wall.zig");

pub const duration = duration_mod;
pub const instant = instant_mod;
pub const wall = wall_mod;
pub const Time = wall_mod.Time;
pub const unix = wall_mod.unix;
pub const fromUnixMilli = wall_mod.fromUnixMilli;
pub const fromUnixMicro = wall_mod.fromUnixMicro;
pub const fromUnixNano = wall_mod.fromUnixNano;

pub fn make(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn () Time, &Impl.now);
    }

    return struct {
        pub const duration = duration_mod;
        pub const instant = instant_mod.make(Impl.instant);

        pub fn now() wall_mod.Time {
            return Impl.now();
        }

        pub fn since(earlier: wall_mod.Time) duration_mod.Duration {
            return now().sub(earlier);
        }
    };
}

pub const test_runner = struct {
    pub const unit = @import("time/test_runner/unit.zig");
};
