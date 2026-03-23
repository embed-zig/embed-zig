//! Io — re-exports from std.Io (buffered VTable-based I/O).

const std = @import("std_re_export.zig");

pub const Reader = std.Io.Reader;
pub const Writer = std.Io.Writer;
pub const Limit = std.Io.Limit;
