//! Std-backed testing impl.

const builtin = @import("builtin");
const std = @import("std");

pub const allocator = if (builtin.is_test)
    std.testing.allocator
else
    std.heap.page_allocator;
pub const expect = std.testing.expect;
pub const expectEqual = std.testing.expectEqual;
pub const expectEqualSlices = std.testing.expectEqualSlices;
pub const expectEqualStrings = std.testing.expectEqualStrings;
pub const expectError = std.testing.expectError;
