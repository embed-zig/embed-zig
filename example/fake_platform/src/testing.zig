//! Example testing impl backed by std.testing.

const std = @import("std");

pub const allocator = std.testing.allocator;
