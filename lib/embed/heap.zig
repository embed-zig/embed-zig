//! Heap contract — platform-dependent heap helpers.
//!
//! Impl must provide:
//!   fn pageSize() usize

const std = @import("std");

pub fn make(comptime Impl: type) type {
    comptime {
        if (@TypeOf(Impl.pageSize) != @TypeOf(std.heap.pageSize))
            @compileError("Impl.pageSize must match std.heap.pageSize");
    }

    return struct {
        pub inline fn pageSize() usize {
            return Impl.pageSize();
        }
    };
}
