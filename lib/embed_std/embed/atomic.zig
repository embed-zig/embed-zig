//! Std-backed atomic impl.

const std = @import("std");

pub const Value = std.atomic.Value;
