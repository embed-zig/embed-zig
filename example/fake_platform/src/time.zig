//! Example time impl backed by std.time.

const std = @import("std");

pub fn milliTimestamp() i64 {
    return std.time.milliTimestamp();
}

pub fn nanoTimestamp() i128 {
    return std.time.nanoTimestamp();
}