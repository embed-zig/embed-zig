//! Std-backed Mutex impl.

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
