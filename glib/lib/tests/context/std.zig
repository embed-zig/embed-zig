//! context test std — std-shaped namespace for context fake-thread tests.

pub const CapturingThread = @import("std/CapturingThread.zig");
pub const FailingThread = @import("std/FailingThread.zig");

pub fn make(comptime base: type, comptime options: anytype) type {
    const SelectedThread = if (@hasField(@TypeOf(options), "Thread")) options.Thread else base.Thread;

    return struct {
        pub const Thread = SelectedThread;
        pub const mem = base.mem;
        pub const DoublyLinkedList = base.DoublyLinkedList;
    };
}
