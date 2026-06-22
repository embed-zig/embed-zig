const Mutex = @import("Mutex.zig").Impl;

pub const Impl = struct {
    mutex: Mutex = .{},

    pub fn lockShared(self: *Impl) void {
        self.mutex.lock();
    }

    pub fn unlockShared(self: *Impl) void {
        self.mutex.unlock();
    }

    pub fn lock(self: *Impl) void {
        self.mutex.lock();
    }

    pub fn unlock(self: *Impl) void {
        self.mutex.unlock();
    }

    pub fn tryLockShared(self: *Impl) bool {
        return self.mutex.tryLock();
    }

    pub fn tryLock(self: *Impl) bool {
        return self.mutex.tryLock();
    }

    pub fn deinit(self: *Impl) void {
        self.mutex.deinit();
    }
};
