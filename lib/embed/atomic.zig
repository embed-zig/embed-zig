//! Atomic utilities — re-exports from std.atomic.

const re_export = struct {
    const std = @import("std");

    pub const Value = std.atomic.Value;
};

pub const Value = re_export.Value;
