//! Debug utilities — platform-independent re-exports from std.debug.

const std = @import("std_re_export.zig");

pub const assert = std.debug.assert;
pub const print = std.debug.print;
