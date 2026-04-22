//! Std-backed testing impl.

const std = @import("std");

pub const allocator = std.testing.allocator;
pub const expect = std.testing.expect;
pub const expectEqual = std.testing.expectEqual;
pub const expectEqualSlices = std.testing.expectEqualSlices;
pub const expectEqualStrings = std.testing.expectEqualStrings;
pub const expectError = std.testing.expectError;
