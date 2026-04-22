//! Io — re-exports from std.Io (buffered VTable-based I/O).

const re_export = struct {
    const std = @import("std");

    pub const Reader = std.Io.Reader;
    pub const Writer = std.Io.Writer;
    pub const Limit = std.Io.Limit;
};

pub const Reader = re_export.Reader;
pub const Writer = re_export.Writer;
pub const Limit = re_export.Limit;
