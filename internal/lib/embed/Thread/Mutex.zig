//! Mutex contract — mutual exclusion lock.
//!
//! Impl must provide:
//!   fn lock(*Impl) void
//!   fn unlock(*Impl) void
//!   fn tryLock(*Impl) bool

pub fn make(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn (*Impl) void, &Impl.lock);
        _ = @as(*const fn (*Impl) void, &Impl.unlock);
        _ = @as(*const fn (*Impl) bool, &Impl.tryLock);
    }

    return struct {
        impl: Impl = .{},

        const Self = @This();

        pub fn lock(self: *Self) void {
            self.impl.lock();
        }

        pub fn unlock(self: *Self) void {
            self.impl.unlock();
        }

        pub fn tryLock(self: *Self) bool {
            return self.impl.tryLock();
        }
    };
}
