//! testing.std — std-shaped namespace for test harness internals.
//!
//! The caller still chooses the runtime `std` namespace. This wrapper keeps the
//! harness on the same surface while swapping in testing-only implementations.

const isolation_thread_mod = @import("IsolationThread.zig");

pub fn make(comptime base: type, comptime options: anytype) type {
    const has_thread_override = @hasField(@TypeOf(options), "Thread");
    const SelectedIsolateThread = if (@hasField(@TypeOf(options), "isolate_thread"))
        options.isolate_thread
    else if (has_thread_override)
        false
    else if (@hasDecl(base, "isolate_thread"))
        base.isolate_thread
    else
        true;
    const ThreadBase = if (has_thread_override)
        struct {
            pub const mem = base.mem;
            pub const Thread = options.Thread;
        }
    else
        base;
    const SelectedThread = isolation_thread_mod.make(ThreadBase, .{ .isolate = SelectedIsolateThread });
    const SelectedLog = if (@hasField(@TypeOf(options), "log")) options.log else base.log;
    const SelectedMem = if (@hasField(@TypeOf(options), "mem")) options.mem else base.mem;
    const SelectedFmt = if (@hasField(@TypeOf(options), "fmt")) options.fmt else base.fmt;
    const SelectedPosix = if (@hasField(@TypeOf(options), "posix"))
        options.posix
    else if (@hasDecl(base, "posix"))
        base.posix
    else
        struct {};
    const SelectedTesting = if (@hasField(@TypeOf(options), "testing")) options.testing else base.testing;

    return struct {
        pub const isolate_thread = SelectedIsolateThread;
        pub const Thread = SelectedThread;

        pub const log = SelectedLog;
        pub const mem = SelectedMem;
        pub const fmt = SelectedFmt;
        pub const posix = SelectedPosix;
        pub const testing = SelectedTesting;

        pub const ArrayList = base.ArrayList;
        pub const ArrayListUnmanaged = base.ArrayListUnmanaged;
        pub const atomic = base.atomic;
        pub const math = base.math;
    };
}
