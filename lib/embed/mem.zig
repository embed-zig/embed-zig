//! Memory utilities — re-exports from std.mem.

const std = @import("std");

pub const Allocator = std.mem.Allocator;
pub const readInt = std.mem.readInt;
pub const writeInt = std.mem.writeInt;
pub const eql = std.mem.eql;
pub const nativeToBig = std.mem.nativeToBig;
pub const bigToNative = std.mem.bigToNative;
pub const indexOf = std.mem.indexOf;
pub const indexOfScalar = std.mem.indexOfScalar;
pub const lastIndexOfScalar = std.mem.lastIndexOfScalar;
pub const trim = std.mem.trim;
