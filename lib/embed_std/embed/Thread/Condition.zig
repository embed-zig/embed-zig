//! Std-backed Condition impl.

const std = @import("std");
const Mutex = @import("Mutex.zig");

inner: std.Thread.Condition = .{},

const Self = @This();

pub fn wait(self: *Self, mutex: *Mutex) void {
    self.inner.wait(&mutex.inner);
}

pub fn timedWait(self: *Self, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
    self.inner.timedWait(&mutex.inner, timeout_ns) catch return error.Timeout;
}

pub fn signal(self: *Self) void {
    self.inner.signal();
}

pub fn broadcast(self: *Self) void {
    self.inner.broadcast();
}
