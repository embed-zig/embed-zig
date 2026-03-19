//! Example Condition impl backed by std.Thread.Condition.

const std = @import("std");
const Mutex = @import("Mutex.zig");

inner: std.Thread.Condition = .{},

const Self = @This();

pub fn wait(self: *Self, mutex: *Mutex) void {
    self.inner.wait(&mutex.inner);
}

pub fn signal(self: *Self) void {
    self.inner.signal();
}

pub fn broadcast(self: *Self) void {
    self.inner.broadcast();
}
