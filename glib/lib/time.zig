//! time — monotonic time helpers.
//!
//! This package is independent from `stdz`. Platform code supplies the
//! monotonic clock implementation through `time.make(.{ .instant = ... })`.

const duration_mod = @import("time/duration.zig");
const instant_mod = @import("time/instant.zig");

pub const duration = duration_mod;
pub const instant = instant_mod;

pub fn make(comptime Impl: type) type {
    return struct {
        pub const instant = instant_mod.make(Impl.instant);
    };
}

pub const test_runner = struct {
    pub const unit = @import("time/test_runner/unit.zig");
};
