//! Memory utilities — re-exports from std.mem.

const std = @import("std_re_export.zig");

pub const Allocator = std.mem.Allocator;
pub const bigToNative = std.mem.bigToNative;
pub const endsWith = std.mem.endsWith;
pub const eql = std.mem.eql;
pub const indexOf = std.mem.indexOf;
pub const indexOfScalar = std.mem.indexOfScalar;
pub const lastIndexOfScalar = std.mem.lastIndexOfScalar;
pub const nativeToBig = std.mem.nativeToBig;
pub const readInt = std.mem.readInt;
pub const slice = std.mem.slice;
pub const sliceFrom = std.mem.sliceFrom;
pub const sliceFromEnd = std.mem.sliceFromEnd;
pub const sliceTo = std.mem.sliceTo;
pub const sliceToEnd = std.mem.sliceToEnd;
pub const trim = std.mem.trim;
pub const writeInt = std.mem.writeInt;
