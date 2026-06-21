//! context test std — std-shaped namespace for context fake-thread tests.

const native_std = @import("std");
const task_mod = @import("task");

pub const CapturingThread = @import("std/CapturingThread.zig");
pub const FailingThread = @import("std/FailingThread.zig");

pub fn make(comptime base: type, comptime options: anytype) type {
    const HasThreadOverride = @hasField(@TypeOf(options), "Thread");
    const HasSyncOverride = @hasField(@TypeOf(options), "sync");
    const HasTaskOverride = @hasField(@TypeOf(options), "task");
    const SelectedThread = if (@hasField(@TypeOf(options), "Thread"))
        options.Thread
    else if (@hasDecl(base, "Thread"))
        base.Thread
    else
        native_std.Thread;

    const ThreadTask = struct {
        pub const Handle = SelectedThread;
        pub const Options = task_mod.Options;
        pub const Routine = task_mod.Routine;
        pub const SpawnError = SelectedThread.SpawnError;

        pub fn go(_: []const u8, launch_options: Options, routine: Routine) SpawnError!Handle {
            return SelectedThread.spawn(.{
                .stack_size = launch_options.min_stack_size,
            }, runRoutine, .{routine});
        }

        pub fn currentToken() usize {
            return 1;
        }

        fn runRoutine(routine: Routine) void {
            routine.run();
        }
    };

    return struct {
        pub const Thread = SelectedThread;
        pub const sync = if (HasSyncOverride) options.sync else if (HasThreadOverride) struct {
            pub const Mutex = SelectedThread.Mutex;
            pub const Condition = SelectedThread.Condition;
            pub const RwLock = SelectedThread.RwLock;
        } else base.sync;
        pub const task = if (HasTaskOverride) options.task else if (HasThreadOverride) ThreadTask else base.task;
        pub const mem = base.mem;
        pub const DoublyLinkedList = base.DoublyLinkedList;
        pub const debug = base.debug;
        pub const testing = base.testing;
        pub const posix = base.posix;
        pub const math = base.math;
    };
}
