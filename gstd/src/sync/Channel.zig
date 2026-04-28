//! Channel impl backed by std thread primitives only.

const glib = @import("glib");

const time = struct {
    const duration = glib.time.duration;
    const instant = glib.time.instant.make(@import("../time/instant.zig").impl);
};

pub const ChannelFactory: glib.sync.channel.FactoryType = struct {
    fn factory(comptime std: type) glib.sync.channel.ChannelType {
        return struct {
            fn factory(comptime T: type) type {
                return Channel(std, T);
            }
        }.factory;
    }
}.factory;

fn Channel(comptime std: type, comptime T: type) type {
    return struct {
        inner: *Inner,

        const Self = @This();

        const Inner = struct {
            allocator: std.mem.Allocator,
            mutex: std.Thread.Mutex,
            can_send: std.Thread.Condition,
            can_recv: std.Thread.Condition,
            ring: []T,
            head: usize,
            tail: usize,
            len: usize,
            capacity: usize,
            closed: bool,
            slot: T,
            slot_full: bool,
            send_mutex: std.Thread.Mutex,
        };

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const ring: []T = if (capacity > 0)
                try allocator.alloc(T, capacity)
            else
                @constCast(&[_]T{});
            errdefer if (capacity > 0) allocator.free(ring);

            const inner = try allocator.create(Inner);
            inner.* = .{
                .allocator = allocator,
                .mutex = .{},
                .can_send = .{},
                .can_recv = .{},
                .ring = ring,
                .head = 0,
                .tail = 0,
                .len = 0,
                .capacity = capacity,
                .closed = false,
                .slot = undefined,
                .slot_full = false,
                .send_mutex = .{},
            };

            return .{ .inner = inner };
        }

        pub fn deinit(self: *Self) void {
            const inner = self.inner;
            if (inner.capacity > 0) inner.allocator.free(inner.ring);
            inner.allocator.destroy(inner);
        }

        pub fn close(self: *Self) void {
            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();
            if (self.inner.closed) return;
            self.inner.closed = true;
            self.inner.slot_full = false;
            self.inner.can_recv.broadcast();
            self.inner.can_send.broadcast();
        }

        pub fn send(self: *Self, value: T) !glib.sync.channel.SendResult() {
            if (self.inner.capacity == 0)
                return self.sendUnbuffered(value, null);
            return self.sendBuffered(value, null);
        }

        pub fn sendTimeout(self: *Self, value: T, timeout: time.duration.Duration) !glib.sync.channel.SendResult() {
            if (self.inner.capacity == 0)
                return self.sendUnbuffered(value, timeout);
            return self.sendBuffered(value, timeout);
        }

        pub fn recv(self: *Self) !glib.sync.channel.RecvResult(T) {
            if (self.inner.capacity == 0)
                return self.recvUnbuffered(null);
            return self.recvBuffered(null);
        }

        pub fn recvTimeout(self: *Self, timeout: time.duration.Duration) !glib.sync.channel.RecvResult(T) {
            if (self.inner.capacity == 0)
                return self.recvUnbuffered(timeout);
            return self.recvBuffered(timeout);
        }

        fn sendBuffered(self: *Self, value: T, timeout: ?time.duration.Duration) !glib.sync.channel.SendResult() {
            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();

            const deadline = makeDeadline(timeout);
            while (self.inner.len == self.inner.capacity and !self.inner.closed) {
                try waitForSend(self, deadline);
            }

            if (self.inner.closed) {
                return .{ .ok = false };
            }

            self.inner.ring[self.inner.tail] = value;
            self.inner.tail = (self.inner.tail + 1) % self.inner.capacity;
            self.inner.len += 1;
            self.inner.can_recv.signal();
            return .{ .ok = true };
        }

        fn recvBuffered(self: *Self, timeout: ?time.duration.Duration) !glib.sync.channel.RecvResult(T) {
            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();

            const deadline = makeDeadline(timeout);
            while (self.inner.len == 0 and !self.inner.closed) {
                try waitForRecv(self, deadline);
            }

            if (self.inner.len == 0) {
                return .{ .value = undefined, .ok = false };
            }

            const value = self.inner.ring[self.inner.head];
            self.inner.head = (self.inner.head + 1) % self.inner.capacity;
            self.inner.len -= 1;
            self.inner.can_send.signal();
            return .{ .value = value, .ok = true };
        }

        fn sendUnbuffered(self: *Self, value: T, timeout: ?time.duration.Duration) !glib.sync.channel.SendResult() {
            self.inner.send_mutex.lock();
            defer self.inner.send_mutex.unlock();
            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();

            const deadline = makeDeadline(timeout);
            while (self.inner.slot_full and !self.inner.closed) {
                try waitForSend(self, deadline);
            }

            if (self.inner.closed) {
                return .{ .ok = false };
            }

            self.inner.slot = value;
            self.inner.slot_full = true;
            self.inner.can_recv.signal();

            while (self.inner.slot_full and !self.inner.closed) {
                waitForSend(self, deadline) catch |err| switch (err) {
                    error.Timeout => {
                        if (self.inner.slot_full) {
                            self.inner.slot_full = false;
                        }
                        return error.Timeout;
                    },
                };
            }

            if (self.inner.closed) return .{ .ok = false };
            return .{ .ok = true };
        }

        fn recvUnbuffered(self: *Self, timeout: ?time.duration.Duration) !glib.sync.channel.RecvResult(T) {
            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();

            const deadline = makeDeadline(timeout);
            while (!self.inner.slot_full and !self.inner.closed) {
                try waitForRecv(self, deadline);
            }

            if (!self.inner.slot_full) {
                return .{ .value = undefined, .ok = false };
            }

            const value = self.inner.slot;
            self.inner.slot_full = false;
            self.inner.can_send.signal();
            return .{ .value = value, .ok = true };
        }

        fn makeDeadline(timeout: ?time.duration.Duration) ?time.instant.Time {
            const duration = timeout orelse return null;
            return time.instant.add(time.instant.now(), duration);
        }

        fn waitForSend(self: *Self, deadline: ?time.instant.Time) error{Timeout}!void {
            const value = deadline orelse {
                self.inner.can_send.wait(&self.inner.mutex);
                return;
            };
            const remaining = time.instant.sub(value, time.instant.now());
            if (remaining <= 0) return error.Timeout;
            self.inner.can_send.timedWait(&self.inner.mutex, @intCast(remaining)) catch |err| switch (err) {
                error.Timeout => return error.Timeout,
            };
        }

        fn waitForRecv(self: *Self, deadline: ?time.instant.Time) error{Timeout}!void {
            const value = deadline orelse {
                self.inner.can_recv.wait(&self.inner.mutex);
                return;
            };
            const remaining = time.instant.sub(value, time.instant.now());
            if (remaining <= 0) return error.Timeout;
            self.inner.can_recv.timedWait(&self.inner.mutex, @intCast(remaining)) catch |err| switch (err) {
                error.Timeout => return error.Timeout,
            };
        }
    };
}
