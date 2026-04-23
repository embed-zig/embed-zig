//! Std-backed time impl.

const std = @import("std");

pub const Instant = std.time.Instant;

pub fn milliTimestamp() i64 {
    return std.time.milliTimestamp();
}

pub fn nanoTimestamp() i128 {
    return std.time.nanoTimestamp();
}
