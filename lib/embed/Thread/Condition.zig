//! Condition contract — condition variable for thread coordination.
//!
//! Impl must provide:
//!   fn wait(*Impl, *MutexImpl) void
//!   fn timedWait(*Impl, *MutexImpl, u64) error{Timeout}!void
//!   fn signal(*Impl) void
//!   fn broadcast(*Impl) void

pub fn make(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn (*Impl) void, &Impl.signal);
        _ = @as(*const fn (*Impl) void, &Impl.broadcast);
    }

    return struct {
        impl: Impl = .{},

        const Self = @This();

        pub fn wait(self: *Self, mutex: anytype) void {
            self.impl.wait(&mutex.impl);
        }

        pub fn timedWait(self: *Self, mutex: anytype, timeout_ns: u64) error{Timeout}!void {
            return self.impl.timedWait(&mutex.impl, timeout_ns);
        }

        pub fn signal(self: *Self) void {
            self.impl.signal();
        }

        pub fn broadcast(self: *Self) void {
            self.impl.broadcast();
        }
    };
}
