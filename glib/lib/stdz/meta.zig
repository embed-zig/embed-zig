//! Meta utilities — re-exports from std.meta.

const re_export = struct {
    const std = @import("std");

    pub const eql = std.meta.eql;
    pub const FieldEnum = std.meta.FieldEnum;
    pub const hasFn = std.meta.hasFn;
};

pub const eql = re_export.eql;
pub const FieldEnum = re_export.FieldEnum;
pub const hasFn = re_export.hasFn;
