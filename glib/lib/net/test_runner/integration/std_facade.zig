const native_std = @import("std");
const LegacySpawnConfig = @import("../../LegacySpawnConfig.zig");

pub fn make(comptime base: type, comptime net: type) type {
    return struct {
        pub const meta = if (@hasDecl(base, "meta")) base.meta else native_std.meta;
        pub const mem = base.mem;
        pub const fmt = base.fmt;
        pub const log = base.log;
        pub const debug = base.debug;
        pub const testing = base.testing;
        pub const crypto = base.crypto;
        pub const math = base.math;
        pub const ascii = base.ascii;
        pub const atomic = base.atomic;
        pub const posix = if (@hasDecl(base, "posix")) base.posix else native_std.posix;
        pub const time = if (@hasDecl(base, "time")) base.time else native_std.time;

        pub const ArrayList = base.ArrayList;
        pub const ArrayListUnmanaged = base.ArrayListUnmanaged;
        pub const AutoHashMap = base.AutoHashMap;
        pub const AutoHashMapUnmanaged = base.AutoHashMapUnmanaged;
        pub const StringHashMap = base.StringHashMap;
        pub const StringHashMapUnmanaged = base.StringHashMapUnmanaged;
        pub const HashMap = base.HashMap;
        pub const HashMapUnmanaged = base.HashMapUnmanaged;
        pub const BoundedArray = base.BoundedArray;

        pub const sync = net.sync;
        pub const task = net.task;
        pub const Thread = ThreadFacade(net);
    };
}

fn ThreadFacade(comptime net: type) type {
    const Task = net.task;
    const Sync = net.sync;
    const allocator = native_std.heap.page_allocator;

    return struct {
        inner: Task.Handle,

        pub const SpawnConfig = LegacySpawnConfig;
        pub const SpawnError = Task.SpawnError;
        pub const Mutex = Sync.Mutex;
        pub const Condition = Sync.Condition;
        pub const RwLock = Sync.RwLock;

        pub fn spawn(config: SpawnConfig, comptime f: anytype, args: anytype) SpawnError!@This() {
            const Args = @TypeOf(args);
            const Runner = struct {
                captured_args: Args,

                fn run(self: *@This()) void {
                    const captured_args = self.captured_args;
                    allocator.destroy(self);
                    @call(.auto, f, captured_args);
                }
            };

            const runner = allocator.create(Runner) catch @panic("net integration test thread allocation failed");
            runner.* = .{ .captured_args = args };
            const handle = try Task.go("testing/net/thread", .{
                .min_stack_size = config.stack_size,
            }, Task.Routine.init(runner, Runner.run));
            return .{ .inner = handle };
        }

        pub fn join(self: @This()) void {
            self.inner.join();
        }

        pub fn detach(self: @This()) void {
            if (@hasDecl(Task.Handle, "detach")) {
                self.inner.detach();
            } else {
                self.inner.join();
            }
        }

        pub fn sleep(ns: u64) void {
            const max_duration: u64 = @intCast(native_std.math.maxInt(i64));
            net.time.sleep(@intCast(@min(ns, max_duration)));
        }
    };
}
