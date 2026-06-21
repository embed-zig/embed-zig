//! testing.std — std-shaped namespace for test harness internals.
//!
//! The caller still chooses the runtime `std` namespace. This wrapper keeps the
//! harness on the same data/log surface while providing testing-owned sync and
//! task backends.

const sync_mod = @import("sync");
const task_mod = @import("task");
const native_std = @import("std");

pub fn make(comptime base: type, comptime options: anytype) type {
    const SelectedLog = if (@hasField(@TypeOf(options), "log")) options.log else base.log;
    const SelectedMem = if (@hasField(@TypeOf(options), "mem")) options.mem else base.mem;
    const SelectedFmt = if (@hasField(@TypeOf(options), "fmt")) options.fmt else base.fmt;
    const SelectedDebug = if (@hasField(@TypeOf(options), "debug")) options.debug else base.debug;
    const SelectedAscii = if (@hasField(@TypeOf(options), "ascii")) options.ascii else base.ascii;
    const SelectedCrypto = if (@hasField(@TypeOf(options), "crypto")) options.crypto else base.crypto;
    const SelectedTime = if (@hasField(@TypeOf(options), "time"))
        options.time
    else if (@hasDecl(base, "time"))
        base.time
    else
        native_std.time;
    const HasSyncOverride = @hasField(@TypeOf(options), "sync");
    const HasTaskOverride = @hasField(@TypeOf(options), "task");
    const HasBaseSync = @hasDecl(base, "sync");
    const HasBaseTask = @hasDecl(base, "task");
    const SelectedPosix = if (@hasField(@TypeOf(options), "posix"))
        options.posix
    else if (@hasDecl(base, "posix"))
        base.posix
    else
        struct {};
    const SelectedTesting = if (@hasField(@TypeOf(options), "testing")) options.testing else base.testing;

    const SyncImpl = struct {
        const NativeWorker = @field(native_std, "Thread");

        pub const Mutex = NativeWorker.Mutex;
        pub const Condition = NativeWorker.Condition;
        pub const RwLock = NativeWorker.RwLock;
    };

    const TaskImpl = struct {
        const NativeWorker = @field(native_std, "Thread");

        pub const Handle = NativeWorker;
        pub const Options = task_mod.Options;
        pub const Routine = task_mod.Routine;
        pub const SpawnError = NativeWorker.SpawnError;

        pub fn go(_: []const u8, launch_options: Options, routine: Routine) SpawnError!Handle {
            return NativeWorker.spawn(.{
                .stack_size = stackSize(launch_options.min_stack_size),
            }, runRoutine, .{routine});
        }

        pub fn currentToken() usize {
            const value: usize = @intCast(NativeWorker.getCurrentId());
            return if (value == 0) 1 else value;
        }

        fn runRoutine(routine: Routine) void {
            routine.run();
        }

        fn stackSize(min_stack_size: usize) usize {
            if (min_stack_size == 0) return NativeWorker.SpawnConfig.default_stack_size;
            return min_stack_size;
        }
    };

    return struct {
        pub const log = SelectedLog;
        pub const mem = SelectedMem;
        pub const fmt = SelectedFmt;
        pub const debug = SelectedDebug;
        pub const ascii = SelectedAscii;
        pub const crypto = SelectedCrypto;
        pub const time = SelectedTime;
        pub const posix = SelectedPosix;
        pub const testing = SelectedTesting;

        pub const sync = if (HasSyncOverride) options.sync else if (HasBaseSync) base.sync else struct {
            pub const Mutex = sync_mod.Mutex.make(SyncImpl.Mutex);
            pub const Condition = sync_mod.Condition.make(SyncImpl.Condition);
            pub const RwLock = sync_mod.RwLock.make(SyncImpl.RwLock);
        };
        pub const task = if (HasTaskOverride) options.task else if (HasBaseTask) base.task else TaskImpl;

        pub const ArrayList = base.ArrayList;
        pub const ArrayListUnmanaged = base.ArrayListUnmanaged;
        pub const DoublyLinkedList = base.DoublyLinkedList;
        pub const atomic = base.atomic;
        pub const math = base.math;
    };
}
