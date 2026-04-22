//! Atomic utilities.
//!
//! By default this re-exports `std.atomic.Value`, but runtimes may provide a
//! compatible `Value` implementation through `stdz.make`.

const std = @import("std");

pub const Value = std.atomic.Value;

pub fn make(comptime Impl: type) type {
    return struct {
        pub const Value = Impl.Value;
    };
}
