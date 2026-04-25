//! RwLock contract — reader-writer lock.
//!
//! Impl must provide (same as std.Thread.RwLock):
//!   fn lockShared(*Impl) void
//!   fn unlockShared(*Impl) void
//!   fn lock(*Impl) void
//!   fn unlock(*Impl) void
//!   fn tryLockShared(*Impl) bool
//!   fn tryLock(*Impl) bool

pub fn make(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn (*Impl) void, &Impl.lockShared);
        _ = @as(*const fn (*Impl) void, &Impl.unlockShared);
        _ = @as(*const fn (*Impl) void, &Impl.lock);
        _ = @as(*const fn (*Impl) void, &Impl.unlock);
        _ = @as(*const fn (*Impl) bool, &Impl.tryLockShared);
        _ = @as(*const fn (*Impl) bool, &Impl.tryLock);
    }

    return struct {
        impl: Impl = .{},

        const Self = @This();

        pub fn lockShared(self: *Self) void {
            self.impl.lockShared();
        }

        pub fn unlockShared(self: *Self) void {
            self.impl.unlockShared();
        }

        pub fn lock(self: *Self) void {
            self.impl.lock();
        }

        pub fn unlock(self: *Self) void {
            self.impl.unlock();
        }

        pub fn tryLockShared(self: *Self) bool {
            return self.impl.tryLockShared();
        }

        pub fn tryLock(self: *Self) bool {
            return self.impl.tryLock();
        }
    };
}
