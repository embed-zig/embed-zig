//! Condition contract — condition variable for thread coordination.
//!
//! Impl must provide:
//!   fn wait(*Impl, *MutexImpl) void
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

        pub fn signal(self: *Self) void {
            self.impl.signal();
        }

        pub fn broadcast(self: *Self) void {
            self.impl.broadcast();
        }
    };
}
