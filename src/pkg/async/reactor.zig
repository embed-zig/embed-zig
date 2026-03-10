const std = @import("std");
const timer_mod = @import("timer.zig");
const runtime = struct {
    pub const io = @import("../../runtime/io.zig");
    pub const std = @import("../../runtime/std.zig");
};

/// Event-loop reactor parameterized on an IO implementation type.
/// Borrows `*IO` to access IO operations directly, and owns
/// a `timer.Scheduler` for integrated timer management.
///
/// `IO` must satisfy the runtime IO contract
/// (ReadyCallback, registerRead, registerWrite, unregister, poll, wake).
pub fn Reactor(comptime IO: type) type {
    comptime _ = runtime.io.from(IO);

    return struct {
        const Self = @This();
        pub const ReadyCallback = IO.ReadyCallback;

        io: *IO,
        timers: timer_mod.Scheduler,
        wake_count: usize = 0,

        pub fn init(io: *IO, allocator: std.mem.Allocator) Self {
            return .{
                .io = io,
                .timers = timer_mod.Scheduler.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.timers.deinit();
        }

        pub fn registerRead(self: *Self, fd: std.posix.fd_t, cb: ReadyCallback) !void {
            try self.io.registerRead(fd, cb);
        }

        pub fn registerWrite(self: *Self, fd: std.posix.fd_t, cb: ReadyCallback) !void {
            try self.io.registerWrite(fd, cb);
        }

        pub fn unregister(self: *Self, fd: std.posix.fd_t) void {
            self.io.unregister(fd);
        }

        pub fn wake(self: *Self) void {
            self.wake_count += 1;
            self.io.wake();
        }

        pub fn drainWakeCount(self: *Self) usize {
            const drained = self.wake_count;
            self.wake_count = 0;
            return drained;
        }

        pub fn scheduleTimer(
            self: *Self,
            now_ms: u64,
            timeout_ms: u64,
        ) std.mem.Allocator.Error!timer_mod.TimerId {
            return self.timers.schedule(now_ms, timeout_ms);
        }

        pub fn scheduleTimerWithCallback(
            self: *Self,
            now_ms: u64,
            timeout_ms: u64,
            callback: ?timer_mod.CallbackFn,
            callback_ctx: ?*anyopaque,
            cancel_source: ?*@import("cancellation.zig").Source,
        ) std.mem.Allocator.Error!timer_mod.TimerId {
            return self.timers.scheduleWithCallback(now_ms, timeout_ms, callback, callback_ctx, cancel_source);
        }

        pub fn cancelTimer(self: *Self, id: timer_mod.TimerId) timer_mod.TimerError!void {
            return self.timers.cancel(id);
        }

        /// Single reactor tick:
        ///   1. Determine poll timeout from nearest timer deadline.
        ///   2. Poll IO.
        ///   3. Collect and fire ready timers.
        /// Returns: number of IO events + number of fired timers.
        pub fn tick(self: *Self, now_ms: u64, ready_buf: *std.ArrayList(timer_mod.TimerId)) !usize {
            const timeout_ms: i32 = if (self.timers.nextDeadline()) |deadline| blk: {
                if (deadline <= now_ms) break :blk 0;
                const delta = deadline - now_ms;
                break :blk if (delta > std.math.maxInt(i32)) std.math.maxInt(i32) else @intCast(delta);
            } else -1;

            const io_events = self.io.poll(timeout_ms);

            const before = ready_buf.items.len;
            try self.timers.collectReady(now_ms, ready_buf);
            const timer_events = ready_buf.items.len - before;

            return io_events + timer_events;
        }

        pub fn poll(self: *Self, timeout_ms: i32) usize {
            return self.io.poll(timeout_ms);
        }
    };
}

test "reactor wake records and drains wake count" {
    const IO = runtime.std.IO;
    var io = try IO.init(std.testing.allocator);
    defer io.deinit();
    var reactor = Reactor(IO).init(&io, std.testing.allocator);
    defer reactor.deinit();

    var i: usize = 0;
    while (i < 1000) : (i += 1) reactor.wake();

    try std.testing.expectEqual(@as(usize, 1000), reactor.drainWakeCount());
    try std.testing.expectEqual(@as(usize, 0), reactor.drainWakeCount());
}

test "reactor tick fires expired timers" {
    const IO = runtime.std.IO;
    var io = try IO.init(std.testing.allocator);
    defer io.deinit();
    var reactor = Reactor(IO).init(&io, std.testing.allocator);
    defer reactor.deinit();

    _ = try reactor.scheduleTimer(0, 50);
    _ = try reactor.scheduleTimer(0, 100);

    var ready = std.ArrayList(timer_mod.TimerId).empty;
    defer ready.deinit(std.testing.allocator);

    const events_at_50 = try reactor.tick(50, &ready);
    try std.testing.expectEqual(@as(usize, 1), events_at_50);
    try std.testing.expectEqual(@as(usize, 1), ready.items.len);

    const events_at_100 = try reactor.tick(100, &ready);
    try std.testing.expectEqual(@as(usize, 1), events_at_100);
    try std.testing.expectEqual(@as(usize, 2), ready.items.len);
}

test "reactor poll with zero timeout returns immediately" {
    const IO = runtime.std.IO;
    var io = try IO.init(std.testing.allocator);
    defer io.deinit();
    var reactor = Reactor(IO).init(&io, std.testing.allocator);
    defer reactor.deinit();

    const events = reactor.poll(0);
    try std.testing.expectEqual(@as(usize, 0), events);
}

test "reactor cancelTimer prevents firing" {
    const IO = runtime.std.IO;
    var io = try IO.init(std.testing.allocator);
    defer io.deinit();
    var reactor = Reactor(IO).init(&io, std.testing.allocator);
    defer reactor.deinit();

    const id = try reactor.scheduleTimer(0, 100);
    try reactor.cancelTimer(id);

    var ready = std.ArrayList(timer_mod.TimerId).empty;
    defer ready.deinit(std.testing.allocator);

    // No pending timers → use poll(0) to avoid blocking
    _ = reactor.poll(0);
    try reactor.timers.collectReady(200, &ready);
    try std.testing.expectEqual(@as(usize, 0), ready.items.len);
}

test "reactor scheduleTimerWithCallback fires callback on tick" {
    const Counter = struct {
        var count: usize = 0;
        fn inc(_: ?*anyopaque) void {
            count += 1;
        }
    };
    Counter.count = 0;

    const IO = runtime.std.IO;
    var io = try IO.init(std.testing.allocator);
    defer io.deinit();
    var reactor = Reactor(IO).init(&io, std.testing.allocator);
    defer reactor.deinit();

    _ = try reactor.scheduleTimerWithCallback(0, 50, Counter.inc, null, null);

    var ready = std.ArrayList(timer_mod.TimerId).empty;
    defer ready.deinit(std.testing.allocator);

    const events = try reactor.tick(50, &ready);
    try std.testing.expectEqual(@as(usize, 1), events);
    try std.testing.expectEqual(@as(usize, 1), Counter.count);
}

test "reactor multi-tick progression through multiple timers" {
    const IO = runtime.std.IO;
    var io = try IO.init(std.testing.allocator);
    defer io.deinit();
    var reactor = Reactor(IO).init(&io, std.testing.allocator);
    defer reactor.deinit();

    _ = try reactor.scheduleTimer(0, 100);
    _ = try reactor.scheduleTimer(0, 200);
    _ = try reactor.scheduleTimer(0, 300);

    var ready = std.ArrayList(timer_mod.TimerId).empty;
    defer ready.deinit(std.testing.allocator);

    _ = try reactor.tick(50, &ready);
    try std.testing.expectEqual(@as(usize, 0), ready.items.len);

    _ = try reactor.tick(100, &ready);
    try std.testing.expectEqual(@as(usize, 1), ready.items.len);

    _ = try reactor.tick(200, &ready);
    try std.testing.expectEqual(@as(usize, 2), ready.items.len);

    _ = try reactor.tick(300, &ready);
    try std.testing.expectEqual(@as(usize, 3), ready.items.len);
}

test "reactor wake drains correctly through poll" {
    const IO = runtime.std.IO;
    var io = try IO.init(std.testing.allocator);
    defer io.deinit();
    var reactor = Reactor(IO).init(&io, std.testing.allocator);
    defer reactor.deinit();

    reactor.wake();
    reactor.wake();
    reactor.wake();

    // poll(0) drains the wake pipe without blocking
    _ = reactor.poll(0);

    try std.testing.expectEqual(@as(usize, 3), reactor.drainWakeCount());
    try std.testing.expectEqual(@as(usize, 0), reactor.drainWakeCount());
}

test "reactor cancelTimer on non-existent id returns error" {
    const IO = runtime.std.IO;
    var io = try IO.init(std.testing.allocator);
    defer io.deinit();
    var reactor = Reactor(IO).init(&io, std.testing.allocator);
    defer reactor.deinit();

    try std.testing.expectError(error.TimerNotFound, reactor.cancelTimer(42));
}

test "reactor scheduleTimerWithCallback respects cancel source" {
    const cancellation_mod = @import("cancellation.zig");

    var cancel_src = cancellation_mod.Source{};

    const Counter = struct {
        var count: usize = 0;
        fn inc(_: ?*anyopaque) void {
            count += 1;
        }
    };
    Counter.count = 0;

    const IO = runtime.std.IO;
    var io = try IO.init(std.testing.allocator);
    defer io.deinit();
    var reactor = Reactor(IO).init(&io, std.testing.allocator);
    defer reactor.deinit();

    _ = try reactor.scheduleTimerWithCallback(0, 50, Counter.inc, null, &cancel_src);
    _ = cancel_src.cancel();

    var ready = std.ArrayList(timer_mod.TimerId).empty;
    defer ready.deinit(std.testing.allocator);

    // Cancelled timer → no pending timers → use poll(0) + manual collectReady
    _ = reactor.poll(0);
    try reactor.timers.collectReady(100, &ready);
    try std.testing.expectEqual(@as(usize, 0), Counter.count);
    try std.testing.expectEqual(@as(usize, 0), ready.items.len);
}

test "reactor tick with expired timer does not block" {
    const IO = runtime.std.IO;
    var io = try IO.init(std.testing.allocator);
    defer io.deinit();
    var reactor = Reactor(IO).init(&io, std.testing.allocator);
    defer reactor.deinit();

    _ = try reactor.scheduleTimer(0, 50);

    var ready = std.ArrayList(timer_mod.TimerId).empty;
    defer ready.deinit(std.testing.allocator);

    // Timer deadline=50, now=100 → poll timeout should be 0 (already expired)
    const events = try reactor.tick(100, &ready);
    try std.testing.expectEqual(@as(usize, 1), events);
    try std.testing.expectEqual(@as(usize, 1), ready.items.len);
}
