//! Debug utilities — platform-independent re-exports from std.debug.

const std = @import("std");

pub const assert = std.debug.assert;
pub const print = std.debug.print;
