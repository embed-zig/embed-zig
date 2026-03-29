//! Debug utilities — platform-independent re-exports from std.debug.

const re_export = struct {
    const std = @import("std");

    pub const assert = std.debug.assert;
    pub const print = std.debug.print;
};

pub const assert = re_export.assert;
pub const print = re_export.print;
