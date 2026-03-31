const Context = @This();

pub const Type = ?*anyopaque;

/// Caller contract:
/// - `ctx` must have originally been created from a pointer to `T`
/// - the pointer must satisfy `T`'s alignment
/// This helper only performs the nullable cast boundary; it does not provide
/// runtime type checking for `anyopaque`.
pub fn cast(comptime T: type, ctx: Type) ?*T {
    const ptr = ctx orelse return null;
    return @ptrCast(@alignCast(ptr));
}

test "zux/event/Context/unit_tests/cast" {
    const std = @import("std");

    var value: u32 = 7;
    const ctx: Type = @ptrCast(&value);
    const casted = cast(u32, ctx).?;

    try std.testing.expectEqual(@as(u32, 7), casted.*);
}

test "zux/event/Context/unit_tests/cast_null_returns_null" {
    const std = @import("std");

    try std.testing.expect(cast(u32, null) == null);
}
