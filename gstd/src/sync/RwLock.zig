const std = @import("std");

inner: std.Thread.RwLock = .{},

const RwLock = @This();

pub fn lockShared(self: *RwLock) void {
    self.inner.lockShared();
}

pub fn unlockShared(self: *RwLock) void {
    self.inner.unlockShared();
}

pub fn lock(self: *RwLock) void {
    self.inner.lock();
}

pub fn unlock(self: *RwLock) void {
    self.inner.unlock();
}

pub fn tryLockShared(self: *RwLock) bool {
    return self.inner.tryLockShared();
}

pub fn tryLock(self: *RwLock) bool {
    return self.inner.tryLock();
}
