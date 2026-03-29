//! Std-backed heap impl.

const std = @import("std");

pub const pageSize = std.heap.pageSize;
