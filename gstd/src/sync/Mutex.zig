const std = @import("std");

inner: std.Thread.Mutex = .{},

const Mutex = @This();

pub fn lock(self: *Mutex) void {
    self.inner.lock();
}

pub fn unlock(self: *Mutex) void {
    self.inner.unlock();
}

pub fn tryLock(self: *Mutex) bool {
    return self.inner.tryLock();
}
