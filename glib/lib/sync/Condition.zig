//! Condition contract — condition variable for thread coordination.

const testing_api = @import("testing");

fn waitMutexImplPtrType(comptime Impl: type) type {
    const wait_sig = @typeInfo(@TypeOf(Impl.wait)).@"fn";
    return wait_sig.params[1].type orelse @compileError("Impl.wait must accept a mutex pointer");
}

fn timedWaitMutexImplPtrType(comptime Impl: type) type {
    const timed_wait_sig = @typeInfo(@TypeOf(Impl.timedWait)).@"fn";
    return timed_wait_sig.params[1].type orelse @compileError("Impl.timedWait must accept a mutex pointer");
}

fn mutexImplFromArg(mutex: anytype, comptime ExpectedPtr: type, comptime op_name: []const u8) ExpectedPtr {
    const MutexPtr = @TypeOf(mutex);
    const ptr_info = @typeInfo(MutexPtr);
    if (ptr_info != .pointer)
        @compileError(op_name ++ " expects a pointer to a mutex wrapper");

    const Mutex = ptr_info.pointer.child;
    if (!@hasField(Mutex, "impl"))
        @compileError(op_name ++ " expects a mutex wrapper with an impl field");

    const mutex_impl = &mutex.impl;
    if (@TypeOf(mutex_impl) != ExpectedPtr)
        @compileError(op_name ++ " received a mutex from an incompatible sync implementation");

    return mutex_impl;
}

pub fn make(comptime Impl: type) type {
    comptime {
        const MutexImplPtr = waitMutexImplPtrType(Impl);
        const TimedWaitMutexImplPtr = timedWaitMutexImplPtrType(Impl);
        if (MutexImplPtr != TimedWaitMutexImplPtr)
            @compileError("Impl.wait and Impl.timedWait must use the same mutex pointer type");

        _ = @as(*const fn (*Impl, MutexImplPtr) void, &Impl.wait);
        _ = @as(*const fn (*Impl, MutexImplPtr, u64) error{Timeout}!void, &Impl.timedWait);
        _ = @as(*const fn (*Impl) void, &Impl.signal);
        _ = @as(*const fn (*Impl) void, &Impl.broadcast);
    }

    return struct {
        impl: Impl = .{},

        const Self = @This();
        const MutexImplPtr = waitMutexImplPtrType(Impl);

        pub fn wait(self: *Self, mutex: anytype) void {
            const mutex_impl = mutexImplFromArg(mutex, MutexImplPtr, "Condition.wait");
            self.impl.wait(mutex_impl);
        }

        pub fn timedWait(self: *Self, mutex: anytype, timeout_ns: u64) error{Timeout}!void {
            const mutex_impl = mutexImplFromArg(mutex, MutexImplPtr, "Condition.timedWait");
            return self.impl.timedWait(mutex_impl, timeout_ns);
        }

        pub fn signal(self: *Self) void {
            self.impl.signal();
        }

        pub fn broadcast(self: *Self) void {
            self.impl.broadcast();
        }
    };
}

pub fn TestRunner(comptime std: type) testing_api.TestRunner {
    const TestCase = struct {
        fn waitUsesMatchingMutexImpl() !void {
            const FakeMutexImpl = struct {
                locked: bool = false,
                unlock_count: usize = 0,
                lock_count: usize = 0,

                pub fn lock(self: *@This()) void {
                    self.locked = true;
                    self.lock_count += 1;
                }

                pub fn unlock(self: *@This()) void {
                    self.locked = false;
                    self.unlock_count += 1;
                }

                pub fn tryLock(self: *@This()) bool {
                    if (self.locked) return false;
                    self.lock();
                    return true;
                }
            };

            const FakeConditionImpl = struct {
                wait_count: usize = 0,

                pub fn wait(self: *@This(), mutex: *FakeMutexImpl) void {
                    self.wait_count += 1;
                    mutex.unlock();
                    mutex.lock();
                }

                pub fn timedWait(_: *@This(), _: *FakeMutexImpl, _: u64) error{Timeout}!void {}

                pub fn signal(_: *@This()) void {}

                pub fn broadcast(_: *@This()) void {}
            };

            const Mutex = @import("Mutex.zig").make(FakeMutexImpl);
            const Condition = make(FakeConditionImpl);
            var mutex: Mutex = .{};
            var condition: Condition = .{};

            mutex.lock();
            condition.wait(&mutex);
            mutex.unlock();

            try std.testing.expectEqual(@as(usize, 1), condition.impl.wait_count);
            try std.testing.expectEqual(@as(usize, 2), mutex.impl.lock_count);
            try std.testing.expectEqual(@as(usize, 2), mutex.impl.unlock_count);
        }

        fn timedWaitReturnsTimeout() !void {
            const FakeMutexImpl = struct {
                locked: bool = false,

                pub fn lock(self: *@This()) void {
                    self.locked = true;
                }

                pub fn unlock(self: *@This()) void {
                    self.locked = false;
                }

                pub fn tryLock(self: *@This()) bool {
                    if (self.locked) return false;
                    self.locked = true;
                    return true;
                }
            };

            const FakeConditionImpl = struct {
                pub fn wait(_: *@This(), mutex: *FakeMutexImpl) void {
                    mutex.unlock();
                    mutex.lock();
                }

                pub fn timedWait(_: *@This(), mutex: *FakeMutexImpl, _: u64) error{Timeout}!void {
                    mutex.unlock();
                    mutex.lock();
                    return error.Timeout;
                }

                pub fn signal(_: *@This()) void {}

                pub fn broadcast(_: *@This()) void {}
            };

            const Mutex = @import("Mutex.zig").make(FakeMutexImpl);
            const Condition = make(FakeConditionImpl);
            var mutex: Mutex = .{};
            var condition: Condition = .{};

            mutex.lock();
            defer mutex.unlock();

            try std.testing.expectError(error.Timeout, condition.timedWait(&mutex, 1));
        }

        fn signalAndBroadcastAreCallable() !void {
            const FakeMutexImpl = struct {
                pub fn lock(_: *@This()) void {}
                pub fn unlock(_: *@This()) void {}
                pub fn tryLock(_: *@This()) bool {
                    return true;
                }
            };
            const FakeConditionImpl = struct {
                pub fn wait(_: *@This(), _: *FakeMutexImpl) void {}
                pub fn timedWait(_: *@This(), _: *FakeMutexImpl, _: u64) error{Timeout}!void {}
                pub fn signal(_: *@This()) void {}
                pub fn broadcast(_: *@This()) void {}
            };

            const Condition = make(FakeConditionImpl);
            var condition: Condition = .{};

            condition.signal();
            condition.broadcast();
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.waitUsesMatchingMutexImpl() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.timedWaitReturnsTimeout() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.signalAndBroadcastAreCallable() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
