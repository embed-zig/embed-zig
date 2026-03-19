//! Example Mutex impl backed by std.Thread.Mutex.

const std = @import("std");

inner: std.Thread.Mutex = .{},

const Self = @This();

pub fn lock(self: *Self) void {
    self.inner.lock();
}

pub fn unlock(self: *Self) void {
    self.inner.unlock();
}

pub fn tryLock(self: *Self) bool {
    return self.inner.tryLock();
}
