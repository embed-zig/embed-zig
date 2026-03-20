//! Testing utilities — re-exports from std.testing.

const std = @import("std");

pub const allocator = std.testing.allocator;
pub const expect = std.testing.expect;
pub const expectEqual = std.testing.expectEqual;
pub const expectEqualStrings = std.testing.expectEqualStrings;
pub const expectError = std.testing.expectError;
