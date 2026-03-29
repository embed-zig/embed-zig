//! Testing utilities — testing helpers with injectable allocator.

const zig_std = @import("std");
pub const Allocator = @import("testing/Allocator.zig");

pub fn make(comptime Impl: type, comptime lib: type) type {
    comptime {
        _ = @as(zig_std.mem.Allocator, Impl.allocator);
        _ = Impl.expect;
        _ = Impl.expectEqual;
        _ = Impl.expectEqualSlices;
        _ = Impl.expectEqualStrings;
        _ = Impl.expectError;
    }

    return struct {
        var allocator_state = Allocator.init(Impl.allocator);

        pub const allocator = allocator_state.allocator();
        pub const Stats = Allocator.Stats;
        pub const expect = Impl.expect;
        pub const expectEqual = Impl.expectEqual;
        pub const expectEqualSlices = Impl.expectEqualSlices;
        pub const expectEqualStrings = Impl.expectEqualStrings;
        pub const expectError = Impl.expectError;

        pub fn allocatorStats() Stats {
            return allocator_state.stats();
        }

        pub fn resetAllocatorStats() void {
            allocator_state.resetStats();
        }

        /// Run a zero-argument test body on a worker thread and fail if it
        /// does not complete within `timeout_ms`.
        pub fn run(callable: anytype, timeout_ms: u32) anyerror!void {
            const Callable = @TypeOf(callable);
            comptime requireRunnable(Callable);

            const State = struct {
                allocator: zig_std.mem.Allocator,
                mutex: lib.Thread.Mutex = .{},
                cond: lib.Thread.Condition = .{},
                done: bool = false,
                cleanup_by_worker: bool = false,
                err: ?anyerror = null,
            };

            const Worker = struct {
                fn main(fn_value: Callable, state: *State) void {
                    invokeRunnable(fn_value) catch |err| {
                        finish(state, err);
                        return;
                    };
                    finish(state, null);
                }

                fn finish(state: *State, err: ?anyerror) void {
                    state.mutex.lock();
                    state.err = err;
                    state.done = true;
                    const cleanup_by_worker = state.cleanup_by_worker;
                    state.cond.broadcast();
                    state.mutex.unlock();

                    if (cleanup_by_worker) state.allocator.destroy(state);
                }
            };

            const state = try allocator.create(State);
            var caller_owns_state = true;
            errdefer if (caller_owns_state) allocator.destroy(state);
            state.* = .{
                .allocator = allocator,
            };

            const worker = try lib.Thread.spawn(.{}, Worker.main, .{ callable, state });
            const deadline_ns = lib.time.nanoTimestamp() + @as(i128, timeout_ms) * @as(i128, lib.time.ns_per_ms);

            state.mutex.lock();
            while (!state.done) {
                const remaining_ns = deadline_ns - lib.time.nanoTimestamp();
                if (remaining_ns <= 0) {
                    state.cleanup_by_worker = true;
                    caller_owns_state = false;
                    state.mutex.unlock();
                    worker.detach();
                    return error.Timeout;
                }

                state.cond.timedWait(&state.mutex, @intCast(remaining_ns)) catch |err| switch (err) {
                    error.Timeout => {
                        if (!state.done) {
                            state.cleanup_by_worker = true;
                            caller_owns_state = false;
                            state.mutex.unlock();
                            worker.detach();
                            return error.Timeout;
                        }
                    },
                };
            }
            const run_err = state.err;
            state.mutex.unlock();

            worker.join();
            allocator.destroy(state);
            caller_owns_state = false;
            if (run_err) |err| return err;
        }
    };
}

fn requireRunnable(comptime T: type) void {
    const sig = callableSignature(T);
    if (sig.params.len != 0) {
        @compileError("testing.run expects a zero-argument function");
    }

    const Ret = sig.return_type orelse @compileError("testing.run expects a function with a return type");
    switch (@typeInfo(Ret)) {
        .void => {},
        .error_union => |eu| {
            if (eu.payload != void) {
                @compileError("testing.run expects fn() void or fn() !void");
            }
        },
        else => @compileError("testing.run expects fn() void or fn() !void"),
    }
}

fn callableSignature(comptime T: type) zig_std.builtin.Type.Fn {
    return switch (@typeInfo(T)) {
        .@"fn" => |sig| sig,
        .pointer => |ptr| switch (@typeInfo(ptr.child)) {
            .@"fn" => |sig| sig,
            else => @compileError("testing.run expects a function or function pointer"),
        },
        else => @compileError("testing.run expects a function or function pointer"),
    };
}

fn invokeRunnable(callable: anytype) anyerror!void {
    const Ret = comptime blk: {
        const sig = callableSignature(@TypeOf(callable));
        break :blk sig.return_type orelse @compileError("testing.run expects a function with a return type");
    };

    switch (@typeInfo(Ret)) {
        .void => {
            @call(.auto, callable, .{});
        },
        .error_union => {
            try @call(.auto, callable, .{});
        },
        else => unreachable,
    }
}

test "embed/unit_tests/testing/run_completes_before_timeout" {
    const testing = make(TestImpl, TestLib);

    try testing.run(struct {
        fn body() !void {
            try testing.expect(true);
        }
    }.body, 100);
}

test "embed/unit_tests/testing/run_propagates_worker_error" {
    const testing = make(TestImpl, TestLib);

    try testing.expectError(error.Boom, testing.run(struct {
        fn body() !void {
            return error.Boom;
        }
    }.body, 100));
}

const TestImpl = struct {
    pub const allocator = zig_std.testing.allocator;
    pub const expect = zig_std.testing.expect;
    pub const expectEqual = zig_std.testing.expectEqual;
    pub const expectEqualSlices = zig_std.testing.expectEqualSlices;
    pub const expectEqualStrings = zig_std.testing.expectEqualStrings;
    pub const expectError = zig_std.testing.expectError;
};

const TestLib = struct {
    pub const Thread = struct {
        pub const SpawnConfig = struct {};

        pub const Mutex = zig_std.Thread.Mutex;

        pub const Condition = struct {
            inner: zig_std.Thread.Condition = .{},

            pub fn wait(self: *Condition, mutex: *Mutex) void {
                self.inner.wait(mutex);
            }

            pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
                self.inner.timedWait(mutex, timeout_ns) catch return error.Timeout;
            }

            pub fn signal(self: *Condition) void {
                self.inner.signal();
            }

            pub fn broadcast(self: *Condition) void {
                self.inner.broadcast();
            }
        };

        inner: zig_std.Thread,

        pub fn spawn(_: SpawnConfig, comptime f: anytype, args: anytype) !Thread {
            return .{
                .inner = try zig_std.Thread.spawn(.{}, f, args),
            };
        }

        pub fn join(self: Thread) void {
            self.inner.join();
        }

        pub fn detach(self: Thread) void {
            self.inner.detach();
        }
    };

    pub const time = struct {
        pub const ns_per_ms = zig_std.time.ns_per_ms;

        pub fn nanoTimestamp() i128 {
            return zig_std.time.nanoTimestamp();
        }
    };
};
