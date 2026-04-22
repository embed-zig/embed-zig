//! Std-backed RwLock impl.

const std = @import("std");

inner: std.Thread.RwLock = .{},

const Self = @This();

pub fn lockShared(self: *Self) void {
    self.inner.lockShared();
}

pub fn unlockShared(self: *Self) void {
    self.inner.unlockShared();
}

pub fn lock(self: *Self) void {
    self.inner.lock();
}

pub fn unlock(self: *Self) void {
    self.inner.unlock();
}

pub fn tryLockShared(self: *Self) bool {
    return self.inner.tryLockShared();
}

pub fn tryLock(self: *Self) bool {
    return self.inner.tryLock();
}
