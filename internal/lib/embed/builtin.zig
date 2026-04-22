//! builtin — re-export of Zig builtin type metadata.

const std = @import("std");

pub const Type = std.builtin.Type;
pub const AtomicOrder = std.builtin.AtomicOrder;
