//! Delay — non-owning type-erased millisecond sleep hook.
//!
//! This wrapper is intentionally small for the first `lib/drivers` phase.
//! It forwards `sleepMs` to an externally owned implementation.

const Delay = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    sleepMs: *const fn (ptr: *anyopaque, ms: u32) void,
};

pub fn sleepMs(self: Delay, ms: u32) void {
    self.vtable.sleepMs(self.ptr, ms);
}

pub fn init(pointer: anytype) Delay {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Delay.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn sleepMsFn(ptr: *anyopaque, ms: u32) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.sleepMs(ms);
        }

        const vtable = VTable{
            .sleepMs = sleepMsFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}

test "drivers/unit_tests/io/Delay/dispatches_sleepMs" {
    const std = @import("std");

    const Fake = struct {
        calls: usize = 0,
        last_ms: u32 = 0,

        fn sleepMs(self: *@This(), ms: u32) void {
            self.calls += 1;
            self.last_ms = ms;
        }
    };

    var fake = Fake{};
    const delay = Delay.init(&fake);

    delay.sleepMs(10);
    delay.sleepMs(25);

    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqual(@as(u32, 25), fake.last_ms);
}
