//! Memory utilities — re-exports from std.mem.

const std = @import("std");

pub const Allocator = std.mem.Allocator;
pub const nativeToBig = std.mem.nativeToBig;
pub const bigToNative = std.mem.bigToNative;
pub const indexOfScalar = std.mem.indexOfScalar;
