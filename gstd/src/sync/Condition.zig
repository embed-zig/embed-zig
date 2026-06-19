const std = @import("std");

const Mutex = @import("Mutex.zig");

inner: std.Thread.Condition = .{},

const Condition = @This();

pub fn wait(self: *Condition, mutex: *Mutex) void {
    self.inner.wait(&mutex.inner);
}

pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
    self.inner.timedWait(&mutex.inner, timeout_ns) catch |err| switch (err) {
        error.Timeout => return error.Timeout,
        else => unreachable,
    };
}

pub fn signal(self: *Condition) void {
    self.inner.signal();
}

pub fn broadcast(self: *Condition) void {
    self.inner.broadcast();
}
