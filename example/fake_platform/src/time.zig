//! Example time impl backed by std.time.

const std = @import("std");

pub fn milliTimestamp() i64 {
    return std.time.milliTimestamp();
}
