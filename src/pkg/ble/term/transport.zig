//! transport — GattTransport adaptor for xfer protocol.
//!
//! Bridges GATT write/notify to xfer's Transport interface (`send`/`recv`).
//! GATT write handler pushes data into rx_queue; xfer's recv() blocks on it.
//! xfer's send() calls the provided notify function.
//!
//! Parameterized on Mutex/Cond for runtime portability (std vs ESP).

const std = @import("std");

pub fn GattTransport(comptime Mutex: type, comptime Cond: type) type {
    return struct {
        const Self = @This();

        const QUEUE_SLOTS = 32;
        const SLOT_SIZE = 520;

        const Slot = struct {
            data: [SLOT_SIZE]u8 = undefined,
            len: usize = 0,
        };

        // xfer Transport interface
        notify_fn: *const fn (ctx: ?*anyopaque, data: []const u8) anyerror!void,
        notify_ctx: ?*anyopaque,

        // rx_queue: GATT write handler pushes, xfer recv() pops
        queue: [QUEUE_SLOTS]Slot = [_]Slot{.{}} ** QUEUE_SLOTS,
        head: usize = 0,
        tail: usize = 0,
        len: usize = 0,
        closed: bool = false,
        mutex: Mutex,
        cond: Cond,

        pub fn init(
            notify_fn: *const fn (ctx: ?*anyopaque, data: []const u8) anyerror!void,
            notify_ctx: ?*anyopaque,
        ) Self {
            return .{
                .notify_fn = notify_fn,
                .notify_ctx = notify_ctx,
                .mutex = Mutex.init(),
                .cond = Cond.init(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.cond.deinit();
            self.mutex.deinit();
        }

        /// xfer Transport: send data to peer via GATT notify.
        pub fn send(self: *Self, data: []const u8) anyerror!void {
            return self.notify_fn(self.notify_ctx, data);
        }

        /// xfer Transport: receive data from peer with timeout.
        /// Returns bytes read, or null on timeout.
        pub fn recv(self: *Self, buf: []u8, timeout_ms: u32) anyerror!?usize {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.len == 0 and !self.closed) {
                const timeout_ns: u64 = @as(u64, timeout_ms) * 1_000_000;
                const result = self.cond.timedWait(&self.mutex, timeout_ns);
                if (result == .timed_out and self.len == 0) return null;
            }

            if (self.len == 0) {
                if (self.closed) return error.Closed;
                return null;
            }

            const slot = &self.queue[self.tail];
            const n = @min(slot.len, buf.len);
            @memcpy(buf[0..n], slot.data[0..n]);
            self.tail = (self.tail + 1) % QUEUE_SLOTS;
            self.len -= 1;
            return n;
        }

        /// Called from GATT write handler context to enqueue received data.
        pub fn push(self: *Self, data: []const u8) error{Full}!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.len >= QUEUE_SLOTS) return error.Full;

            var slot = &self.queue[self.head];
            const n = @min(data.len, SLOT_SIZE);
            @memcpy(slot.data[0..n], data[0..n]);
            slot.len = n;
            self.head = (self.head + 1) % QUEUE_SLOTS;
            self.len += 1;
            self.cond.signal();
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
            self.cond.broadcast();
        }

        pub fn reset(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.head = 0;
            self.tail = 0;
            self.len = 0;
            self.closed = false;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const builtin = @import("builtin");

const TestMutex = if (builtin.os.tag == .freestanding) void else struct {
    raw: std.Thread.Mutex = .{},
    pub fn init() @This() {
        return .{};
    }
    pub fn deinit(_: *@This()) void {}
    pub fn lock(self: *@This()) void {
        self.raw.lock();
    }
    pub fn unlock(self: *@This()) void {
        self.raw.unlock();
    }
};

const TestCond = if (builtin.os.tag == .freestanding) void else struct {
    raw: std.Thread.Condition = .{},
    pub fn init() @This() {
        return .{};
    }
    pub fn deinit(_: *@This()) void {}
    pub fn wait(self: *@This(), mutex: *TestMutex) void {
        self.raw.wait(&mutex.raw);
    }
    pub fn signal(self: *@This()) void {
        self.raw.signal();
    }
    pub fn broadcast(self: *@This()) void {
        self.raw.broadcast();
    }
    pub fn timedWait(self: *@This(), mutex: *TestMutex, timeout_ns: u64) enum { signaled, timed_out } {
        self.raw.timedWait(&mutex.raw, timeout_ns) catch return .timed_out;
        return .signaled;
    }
};

fn testNotify(_: ?*anyopaque, _: []const u8) anyerror!void {}

test "GattTransport: push and recv" {
    const T = GattTransport(TestMutex, TestCond);
    var transport = T.init(testNotify, null);
    defer transport.deinit();

    try transport.push("hello");

    var buf: [64]u8 = undefined;
    const n = (try transport.recv(&buf, 100)).?;
    try std.testing.expectEqualSlices(u8, "hello", buf[0..n]);
}

test "GattTransport: recv timeout returns null" {
    const T = GattTransport(TestMutex, TestCond);
    var transport = T.init(testNotify, null);
    defer transport.deinit();

    var buf: [64]u8 = undefined;
    const result = try transport.recv(&buf, 1);
    try std.testing.expect(result == null);
}

test "GattTransport: multiple push/recv" {
    const T = GattTransport(TestMutex, TestCond);
    var transport = T.init(testNotify, null);
    defer transport.deinit();

    try transport.push("aaa");
    try transport.push("bbb");

    var buf: [64]u8 = undefined;
    const n1 = (try transport.recv(&buf, 100)).?;
    try std.testing.expectEqualSlices(u8, "aaa", buf[0..n1]);

    const n2 = (try transport.recv(&buf, 100)).?;
    try std.testing.expectEqualSlices(u8, "bbb", buf[0..n2]);
}

test "GattTransport: send calls notify_fn" {
    const Ctx = struct {
        called: bool = false,
        pub fn notify(ctx: ?*anyopaque, data: []const u8) anyerror!void {
            _ = data;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.called = true;
        }
    };
    var ctx = Ctx{};
    const T = GattTransport(TestMutex, TestCond);
    var transport = T.init(Ctx.notify, @ptrCast(&ctx));
    defer transport.deinit();

    try transport.send("test");
    try std.testing.expect(ctx.called);
}

test "GattTransport: close wakes recv" {
    const T = GattTransport(TestMutex, TestCond);
    var transport = T.init(testNotify, null);
    defer transport.deinit();

    transport.close();

    var buf: [64]u8 = undefined;
    const result = transport.recv(&buf, 1000);
    try std.testing.expectError(error.Closed, result);
}

test "GattTransport: reset clears queue" {
    const T = GattTransport(TestMutex, TestCond);
    var transport = T.init(testNotify, null);
    defer transport.deinit();

    try transport.push("data");
    transport.reset();

    var buf: [64]u8 = undefined;
    const result = try transport.recv(&buf, 1);
    try std.testing.expect(result == null);
}
