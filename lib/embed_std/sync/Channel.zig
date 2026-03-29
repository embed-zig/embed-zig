//! Channel impl backed by lib thread primitives only.

const sync_mod = @import("sync");
const channel = sync_mod.channel;

pub fn ChannelFactory(comptime lib: type) fn (type) type {
    return struct {
        fn factory(comptime T: type) type {
            return Channel(lib, T);
        }
    }.factory;
}

fn Channel(comptime lib: type, comptime T: type) type {
    return struct {
        inner: *Inner,

        const Self = @This();

        const Inner = struct {
            allocator: lib.mem.Allocator,
            mutex: lib.Thread.Mutex,
            can_send: lib.Thread.Condition,
            can_recv: lib.Thread.Condition,
            ring: []T,
            head: usize,
            tail: usize,
            len: usize,
            capacity: usize,
            closed: bool,
            slot: T,
            slot_full: bool,
            send_mutex: lib.Thread.Mutex,
        };

        pub fn init(allocator: lib.mem.Allocator, capacity: usize) !Self {
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

        pub fn send(self: *Self, value: T) !channel.SendResult() {
            if (self.inner.capacity == 0)
                return self.sendUnbuffered(value);
            return self.sendBuffered(value);
        }

        pub fn recv(self: *Self) !channel.RecvResult(T) {
            if (self.inner.capacity == 0)
                return self.recvUnbuffered();
            return self.recvBuffered();
        }

        fn sendBuffered(self: *Self, value: T) !channel.SendResult() {
            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();

            while (self.inner.len == self.inner.capacity and !self.inner.closed) {
                self.inner.can_send.wait(&self.inner.mutex);
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

        fn recvBuffered(self: *Self) !channel.RecvResult(T) {
            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();

            while (self.inner.len == 0 and !self.inner.closed) {
                self.inner.can_recv.wait(&self.inner.mutex);
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

        fn sendUnbuffered(self: *Self, value: T) !channel.SendResult() {
            self.inner.send_mutex.lock();
            defer self.inner.send_mutex.unlock();
            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();

            while (self.inner.slot_full and !self.inner.closed) {
                self.inner.can_send.wait(&self.inner.mutex);
            }

            if (self.inner.closed) {
                return .{ .ok = false };
            }

            self.inner.slot = value;
            self.inner.slot_full = true;
            self.inner.can_recv.signal();

            while (self.inner.slot_full and !self.inner.closed) {
                self.inner.can_send.wait(&self.inner.mutex);
            }

            if (self.inner.closed) return .{ .ok = false };
            return .{ .ok = true };
        }

        fn recvUnbuffered(self: *Self) !channel.RecvResult(T) {
            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();

            while (!self.inner.slot_full and !self.inner.closed) {
                self.inner.can_recv.wait(&self.inner.mutex);
            }

            if (!self.inner.slot_full) {
                return .{ .value = undefined, .ok = false };
            }

            const value = self.inner.slot;
            self.inner.slot_full = false;
            self.inner.can_send.signal();
            return .{ .value = value, .ok = true };
        }
    };
}
