//! Reusable event payload types for pkg/event.
//!
//! These are building blocks. Users compose their own `union(enum)` from
//! whichever payloads they need, then pass that union as `EventType` to
//! `Bus`, `Periph`, `Middleware`, etc.

const std = @import("std");

/// Peripheral-level generic event payload.
/// `id` identifies the source peripheral instance (e.g. "btn.power").
pub const PeriphEvent = struct {
    id: []const u8,
    code: u16 = 0,
    data: i64 = 0,
};

/// Custom user-defined event payload.
pub const CustomEvent = struct {
    id: []const u8,
    data: i64 = 0,
};

/// Board-level system events.
pub const SystemEvent = enum {
    ready,
    low_battery,
    sleep,
    wake,
    err,
};

/// Board-level timer event.
pub const TimerEvent = struct {
    id: u8,
    data: u32 = 0,
};

/// Validate that a type is a tagged union suitable for use as an EventType.
pub fn assertTaggedUnion(comptime T: type) void {
    const info = @typeInfo(T);
    if (info != .@"union") @compileError("EventType must be a union(enum), got " ++ @typeName(T));
    if (info.@"union".tag_type == null) @compileError("EventType must be a tagged union (union(enum))");
}

test "PeriphEvent can be instantiated" {
    const ev = PeriphEvent{ .id = "btn.test", .code = 2, .data = 3 };
    try std.testing.expectEqualStrings("btn.test", ev.id);
    try std.testing.expectEqual(@as(u16, 2), ev.code);
}

test "assertTaggedUnion accepts tagged union" {
    const Good = union(enum) { a: u32, b: f32 };
    comptime assertTaggedUnion(Good);
}
