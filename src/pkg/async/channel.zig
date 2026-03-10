const std = @import("std");
const runtime = struct {
    pub const sync = @import("../../runtime/sync.zig");
    pub const std = @import("../../runtime/std.zig");
};

/// Bounded channel with ring buffer storage.
/// Uses explicit `Mutex` and `Condition` primitives for thread-safe blocking
/// send/recv. Non-blocking `trySend`/`tryRecv` variants also provided.
pub fn Channel(comptime T: type, comptime Mutex: type, comptime Cond: type) type {
    comptime {
        _ = runtime.sync.Mutex(Mutex);
        _ = runtime.sync.ConditionWithMutex(Cond, Mutex);
    }

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        buf: []T,
        head: usize = 0,
        tail: usize = 0,
        len: usize = 0,
        capacity: usize,
        closed: bool = false,
        mutex: Mutex,
        not_empty: Cond,
        not_full: Cond,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!Self {
            const buf = try allocator.alloc(T, capacity);
            return .{
                .allocator = allocator,
                .buf = buf,
                .capacity = capacity,
                .mutex = Mutex.init(),
                .not_empty = Cond.init(),
                .not_full = Cond.init(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.not_full.deinit();
            self.not_empty.deinit();
            self.mutex.deinit();
            self.allocator.free(self.buf);
            self.* = undefined;
        }

        /// Blocking send — waits until space is available or channel is closed.
        pub fn send(self: *Self, value: T) error{Closed}!void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.len >= self.capacity and !self.closed) {
                self.not_full.wait(&self.mutex);
            }
            if (self.closed) return error.Closed;
            self.pushLocked(value);
            self.not_empty.signal();
        }

        /// Non-blocking send — returns `Full` immediately when buffer is at capacity.
        pub fn trySend(self: *Self, value: T) error{ Closed, Full }!void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed) return error.Closed;
            if (self.len >= self.capacity) return error.Full;
            self.pushLocked(value);
            self.not_empty.signal();
        }

        /// Blocking recv — waits until data is available.
        /// Returns `Closed` only when the channel is closed AND empty.
        pub fn recv(self: *Self) error{Closed}!T {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.len == 0 and !self.closed) {
                self.not_empty.wait(&self.mutex);
            }
            if (self.len == 0) return error.Closed;
            const item = self.popLocked();
            self.not_full.signal();
            return item;
        }

        /// Non-blocking recv — returns `Empty` immediately when buffer is empty.
        pub fn tryRecv(self: *Self) error{ Closed, Empty }!T {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.len == 0) {
                if (self.closed) return error.Closed;
                return error.Empty;
            }
            const item = self.popLocked();
            self.not_full.signal();
            return item;
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed) return;
            self.closed = true;
            self.not_empty.broadcast();
            self.not_full.broadcast();
        }

        pub fn isClosed(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.closed;
        }

        pub fn count(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.len;
        }

        pub fn isEmpty(self: *Self) bool {
            return self.count() == 0;
        }

        fn pushLocked(self: *Self, value: T) void {
            self.buf[self.tail] = value;
            self.tail = (self.tail + 1) % self.capacity;
            self.len += 1;
        }

        fn popLocked(self: *Self) T {
            const item = self.buf[self.head];
            self.head = (self.head + 1) % self.capacity;
            self.len -= 1;
            return item;
        }
    };
}

test "channel single producer single consumer preserves order" {
    var ch = try Channel(u32, runtime.std.Mutex, runtime.std.Condition).init(std.testing.allocator, 8);
    defer ch.deinit();

    var sent: u32 = 0;
    var received: u32 = 0;
    var last_recv: ?u32 = null;

    while (sent < 100) {
        while (sent < 100) {
            ch.trySend(sent) catch |err| switch (err) {
                error.Full => break,
                else => return err,
            };
            sent += 1;
        }
        while (true) {
            const got = ch.tryRecv() catch |err| switch (err) {
                error.Empty => break,
                else => return err,
            };
            if (last_recv) |prev| try std.testing.expect(got > prev);
            last_recv = got;
            received += 1;
        }
    }
    while (ch.count() > 0) {
        const got = try ch.tryRecv();
        if (last_recv) |prev| try std.testing.expect(got > prev);
        last_recv = got;
        received += 1;
    }

    try std.testing.expectEqual(@as(u32, 100), received);
}

test "channel multi producer single consumer 400 messages no loss" {
    var ch = try Channel(u64, runtime.std.Mutex, runtime.std.Condition).init(std.testing.allocator, 32);
    defer ch.deinit();

    var total_sent: usize = 0;
    var total_recv: usize = 0;
    var sum_sent: u64 = 0;
    var sum_recv: u64 = 0;

    var producer: usize = 0;
    while (producer < 4) : (producer += 1) {
        var msg: u64 = 0;
        while (msg < 100) : (msg += 1) {
            const value = producer * 1000 + msg;
            while (true) {
                ch.trySend(value) catch |err| switch (err) {
                    error.Full => {
                        const got = try ch.tryRecv();
                        sum_recv += got;
                        total_recv += 1;
                        continue;
                    },
                    else => return err,
                };
                sum_sent += value;
                total_sent += 1;
                break;
            }
        }
    }

    while (ch.count() > 0) {
        const got = try ch.tryRecv();
        sum_recv += got;
        total_recv += 1;
    }

    try std.testing.expectEqual(@as(usize, 400), total_sent);
    try std.testing.expectEqual(@as(usize, 400), total_recv);
    try std.testing.expectEqual(sum_sent, sum_recv);
}

test "channel close drains 32 buffered messages then returns closed" {
    var ch = try Channel(u8, runtime.std.Mutex, runtime.std.Condition).init(std.testing.allocator, 32);
    defer ch.deinit();

    var i: u8 = 0;
    while (i < 32) : (i += 1) try ch.trySend(i);
    ch.close();

    var count_val: usize = 0;
    while (true) {
        _ = ch.tryRecv() catch |err| switch (err) {
            error.Closed => break,
            else => return err,
        };
        count_val += 1;
    }
    try std.testing.expectEqual(@as(usize, 32), count_val);
    try std.testing.expectError(error.Closed, ch.trySend(99));
}

test "channel capacity one alternates send and recv" {
    var ch = try Channel(u8, runtime.std.Mutex, runtime.std.Condition).init(std.testing.allocator, 1);
    defer ch.deinit();

    try ch.trySend(7);
    try std.testing.expectError(error.Full, ch.trySend(9));
    try std.testing.expectEqual(@as(u8, 7), try ch.tryRecv());
    try ch.trySend(9);
    try std.testing.expectEqual(@as(u8, 9), try ch.tryRecv());
}

test "trySend to closed channel returns Closed" {
    var ch = try Channel(u8, runtime.std.Mutex, runtime.std.Condition).init(std.testing.allocator, 4);
    defer ch.deinit();

    ch.close();
    try std.testing.expectError(error.Closed, ch.trySend(1));
    try std.testing.expect(ch.isClosed());
}

test "isClosed and isEmpty and count" {
    var ch = try Channel(u16, runtime.std.Mutex, runtime.std.Condition).init(std.testing.allocator, 4);
    defer ch.deinit();

    try std.testing.expect(!ch.isClosed());
    try std.testing.expect(ch.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), ch.count());

    try ch.trySend(42);
    try std.testing.expect(!ch.isEmpty());
    try std.testing.expectEqual(@as(usize, 1), ch.count());

    _ = try ch.tryRecv();
    try std.testing.expect(ch.isEmpty());
}

test "ring buffer wraps correctly" {
    var ch = try Channel(u32, runtime.std.Mutex, runtime.std.Condition).init(std.testing.allocator, 4);
    defer ch.deinit();

    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        try ch.trySend(i);
        try std.testing.expectEqual(i, try ch.tryRecv());
    }
    try std.testing.expect(ch.isEmpty());
}

test "tryRecv on empty channel returns Empty" {
    var ch = try Channel(u8, runtime.std.Mutex, runtime.std.Condition).init(std.testing.allocator, 4);
    defer ch.deinit();

    try std.testing.expectError(error.Empty, ch.tryRecv());
}

test "tryRecv on closed empty channel returns Closed" {
    var ch = try Channel(u8, runtime.std.Mutex, runtime.std.Condition).init(std.testing.allocator, 4);
    defer ch.deinit();

    ch.close();
    try std.testing.expectError(error.Closed, ch.tryRecv());
}

test "fill channel to exact capacity then Full" {
    var ch = try Channel(u16, runtime.std.Mutex, runtime.std.Condition).init(std.testing.allocator, 4);
    defer ch.deinit();

    try ch.trySend(1);
    try ch.trySend(2);
    try ch.trySend(3);
    try ch.trySend(4);
    try std.testing.expectEqual(@as(usize, 4), ch.count());
    try std.testing.expectError(error.Full, ch.trySend(5));
}

test "channel close preserves pending data" {
    var ch = try Channel(u32, runtime.std.Mutex, runtime.std.Condition).init(std.testing.allocator, 8);
    defer ch.deinit();

    try ch.trySend(10);
    try ch.trySend(20);
    try ch.trySend(30);
    ch.close();

    try std.testing.expectEqual(@as(u32, 10), try ch.tryRecv());
    try std.testing.expectEqual(@as(u32, 20), try ch.tryRecv());
    try std.testing.expectEqual(@as(u32, 30), try ch.tryRecv());
    try std.testing.expectError(error.Closed, ch.tryRecv());
}

test "channel of structs preserves fields" {
    const Msg = struct { id: u32, value: u64 };
    var ch = try Channel(Msg, runtime.std.Mutex, runtime.std.Condition).init(std.testing.allocator, 4);
    defer ch.deinit();

    try ch.trySend(.{ .id = 1, .value = 100 });
    try ch.trySend(.{ .id = 2, .value = 200 });

    const m1 = try ch.tryRecv();
    try std.testing.expectEqual(@as(u32, 1), m1.id);
    try std.testing.expectEqual(@as(u64, 100), m1.value);

    const m2 = try ch.tryRecv();
    try std.testing.expectEqual(@as(u32, 2), m2.id);
    try std.testing.expectEqual(@as(u64, 200), m2.value);
}

test "channel stress test 1000 messages" {
    var ch = try Channel(u32, runtime.std.Mutex, runtime.std.Condition).init(std.testing.allocator, 16);
    defer ch.deinit();

    var sent: u32 = 0;
    var received: u32 = 0;
    var sum_sent: u64 = 0;
    var sum_recv: u64 = 0;

    while (sent < 1000) {
        while (sent < 1000) {
            ch.trySend(sent) catch |err| switch (err) {
                error.Full => break,
                else => return err,
            };
            sum_sent += sent;
            sent += 1;
        }
        while (true) {
            const val = ch.tryRecv() catch |err| switch (err) {
                error.Empty => break,
                else => return err,
            };
            sum_recv += val;
            received += 1;
        }
    }
    while (ch.count() > 0) {
        const val = try ch.tryRecv();
        sum_recv += val;
        received += 1;
    }

    try std.testing.expectEqual(@as(u32, 1000), received);
    try std.testing.expectEqual(sum_sent, sum_recv);
}

test "close then trySend then tryRecv drains correctly" {
    var ch = try Channel(u8, runtime.std.Mutex, runtime.std.Condition).init(std.testing.allocator, 8);
    defer ch.deinit();

    try ch.trySend(1);
    try ch.trySend(2);
    ch.close();

    try std.testing.expectError(error.Closed, ch.trySend(3));
    try std.testing.expectEqual(@as(u8, 1), try ch.tryRecv());
    try std.testing.expectEqual(@as(u8, 2), try ch.tryRecv());
    try std.testing.expectError(error.Closed, ch.tryRecv());
}

test "channel capacity zero is always full for send" {
    var ch = try Channel(u8, runtime.std.Mutex, runtime.std.Condition).init(std.testing.allocator, 0);
    defer ch.deinit();

    try std.testing.expectError(error.Full, ch.trySend(1));
    try std.testing.expectError(error.Empty, ch.tryRecv());
    try std.testing.expectEqual(@as(usize, 0), ch.count());
}

test "channel capacity zero close then recv returns closed" {
    var ch = try Channel(u8, runtime.std.Mutex, runtime.std.Condition).init(std.testing.allocator, 0);
    defer ch.deinit();

    ch.close();
    try std.testing.expectError(error.Closed, ch.tryRecv());
    try std.testing.expectError(error.Closed, ch.recv());
}

test "channel close is idempotent and preserves buffered value" {
    var ch = try Channel(u16, runtime.std.Mutex, runtime.std.Condition).init(std.testing.allocator, 4);
    defer ch.deinit();

    try ch.trySend(42);
    ch.close();
    ch.close();

    try std.testing.expect(ch.isClosed());
    try std.testing.expectEqual(@as(usize, 1), ch.count());
    try std.testing.expectEqual(@as(u16, 42), try ch.tryRecv());
    try std.testing.expectError(error.Closed, ch.tryRecv());
}

test "channel blocking send on closed channel returns Closed" {
    var ch = try Channel(u32, runtime.std.Mutex, runtime.std.Condition).init(std.testing.allocator, 2);
    defer ch.deinit();

    ch.close();
    try std.testing.expectError(error.Closed, ch.send(7));
}

test "channel blocking recv on closed empty channel returns Closed" {
    var ch = try Channel(u32, runtime.std.Mutex, runtime.std.Condition).init(std.testing.allocator, 2);
    defer ch.deinit();

    ch.close();
    try std.testing.expectError(error.Closed, ch.recv());
}

test "channel close does not drop buffered count" {
    var ch = try Channel(u8, runtime.std.Mutex, runtime.std.Condition).init(std.testing.allocator, 3);
    defer ch.deinit();

    try ch.trySend(9);
    try ch.trySend(8);
    ch.close();

    try std.testing.expectEqual(@as(usize, 2), ch.count());
    _ = try ch.tryRecv();
    try std.testing.expectEqual(@as(usize, 1), ch.count());
    _ = try ch.tryRecv();
    try std.testing.expectEqual(@as(usize, 0), ch.count());
    try std.testing.expectError(error.Closed, ch.tryRecv());
}

test "channel count remains bounded during wraparound churn" {
    var ch = try Channel(u32, runtime.std.Mutex, runtime.std.Condition).init(std.testing.allocator, 3);
    defer ch.deinit();

    var i: u32 = 0;
    while (i < 40) : (i += 1) {
        ch.trySend(i) catch |err| switch (err) {
            error.Full => _ = try ch.tryRecv(),
            else => return err,
        };
        try std.testing.expect(ch.count() <= 3);
    }
}

test "channel bool payload preserves true false ordering" {
    var ch = try Channel(bool, runtime.std.Mutex, runtime.std.Condition).init(std.testing.allocator, 4);
    defer ch.deinit();

    try ch.trySend(true);
    try ch.trySend(false);

    try std.testing.expectEqual(true, try ch.tryRecv());
    try std.testing.expectEqual(false, try ch.tryRecv());
    try std.testing.expect(ch.isEmpty());
}
