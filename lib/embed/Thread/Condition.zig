//! Condition contract — condition variable for thread coordination.
//!
//! Impl must provide:
//!   fn wait(*Impl, *MutexImpl) void
//!   fn timedWait(*Impl, *MutexImpl, u64) error{Timeout}!void
//!   fn signal(*Impl) void
//!   fn broadcast(*Impl) void

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
        @compileError(op_name ++ " received a mutex from an incompatible Thread implementation");

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

test "embed/unit_tests/Thread/Condition/make_accepts_matching_mutex_impl" {
    const MutexImpl = struct {
        state: u8 = 0,
    };
    const ConditionImpl = struct {
        pub fn wait(_: *@This(), _: *MutexImpl) void {}

        pub fn timedWait(_: *@This(), _: *MutexImpl, _: u64) error{Timeout}!void {}

        pub fn signal(_: *@This()) void {}

        pub fn broadcast(_: *@This()) void {}
    };

    const Condition = make(ConditionImpl);
    const Mutex = struct {
        impl: MutexImpl = .{},
    };

    var cond: Condition = .{};
    var mutex: Mutex = .{};

    cond.wait(&mutex);
    try cond.timedWait(&mutex, 1);
    cond.signal();
    cond.broadcast();
}
