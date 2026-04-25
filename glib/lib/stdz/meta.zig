//! Meta utilities — re-exports from std.meta.

const re_export = struct {
    const std = @import("std");

    pub const eql = std.meta.eql;
};

pub const eql = re_export.eql;
