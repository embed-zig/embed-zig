const std = @import("std");
const esp = @import("esp");
const runtime = @import("runtime");

const fd_t = std.posix.fd_t;

pub const IO = struct {
    pub const ReadyCallback = runtime.io.ReadyCallback;
    pub const Config = struct {
        tick_rate_hz: u32 = 100,
        event_queue_depth: u32 = 128,
    };

    const EventKind = enum { read_ready, write_ready };
    const Event = struct {
        kind: EventKind,
        fd: fd_t,
    };

    const WatchEntry = struct {
        read: ?ReadyCallback = null,
        write: ?ReadyCallback = null,
    };

    allocator: std.mem.Allocator,
    watchers: std.AutoHashMap(fd_t, WatchEntry),
    events: esp.freertos.queue.Queue(Event),
    wake_sem: esp.freertos.sync.Semaphore,
    wait_set: esp.freertos.queue.QueueSet,
    tick_rate_hz: u32,

    pub fn init(allocator: std.mem.Allocator) anyerror!@This() {
        return initWithConfig(allocator, .{});
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, config: Config) anyerror!@This() {
        if (config.tick_rate_hz == 0) return error.InvalidArgument;
        if (config.event_queue_depth == 0) return error.InvalidArgument;
        if (config.event_queue_depth == std.math.maxInt(u32)) return error.InvalidArgument;

        const q = try esp.freertos.queue.Queue(Event).init(config.event_queue_depth);
        errdefer {
            var qq = q;
            qq.deinit();
        }

        var wake_sem = esp.freertos.sync.Semaphore.initBinary(false) catch return error.InitFailed;
        errdefer wake_sem.deinit();

        var wait_set = try esp.freertos.queue.QueueSet.init(config.event_queue_depth + 1);
        errdefer wait_set.deinit();

        try wait_set.addMember(q.rawHandle());
        errdefer _ = wait_set.removeMember(q.rawHandle()) catch {};

        try wait_set.addMember(wake_sem.rawHandle());
        errdefer _ = wait_set.removeMember(wake_sem.rawHandle()) catch {};

        return .{
            .allocator = allocator,
            .watchers = std.AutoHashMap(fd_t, WatchEntry).init(allocator),
            .events = q,
            .wake_sem = wake_sem,
            .wait_set = wait_set,
            .tick_rate_hz = config.tick_rate_hz,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.watchers.deinit();
        _ = self.wait_set.removeMember(self.events.rawHandle()) catch {};
        _ = self.wait_set.removeMember(self.wake_sem.rawHandle()) catch {};
        self.wait_set.deinit();
        self.wake_sem.deinit();
        self.events.deinit();
    }

    pub fn registerRead(self: *@This(), fd: fd_t, cb: ReadyCallback) anyerror!void {
        var gop = try self.watchers.getOrPut(fd);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.read = cb;
    }

    pub fn registerWrite(self: *@This(), fd: fd_t, cb: ReadyCallback) anyerror!void {
        var gop = try self.watchers.getOrPut(fd);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.write = cb;
    }

    pub fn unregister(self: *@This(), fd: fd_t) void {
        _ = self.watchers.remove(fd);
    }

    pub fn poll(self: *@This(), timeout_ms: i32) usize {
        const wait_ticks = self.timeoutMsToTicks(timeout_ms);
        const selected = self.wait_set.select(wait_ticks) orelse return 0;

        if (selected == self.wake_sem.rawHandle()) {
            self.drainWake();
            return self.drainReadyEvents();
        }
        if (selected == self.events.rawHandle()) {
            const first = self.events.receive(0) catch return 0;
            return self.dispatchEvent(first) + self.drainReadyEvents();
        }
        return 0;
    }

    pub fn wake(self: *@This()) void {
        _ = self.wake_sem.give();
    }

    /// Optional bridge API: allow platform adapters to publish read readiness.
    pub fn notifyReadReady(self: *@This(), fd: fd_t) void {
        self.pushEvent(.{ .kind = .read_ready, .fd = fd });
    }

    /// Optional bridge API: allow platform adapters to publish write readiness.
    pub fn notifyWriteReady(self: *@This(), fd: fd_t) void {
        self.pushEvent(.{ .kind = .write_ready, .fd = fd });
    }

    fn drainReadyEvents(self: *@This()) usize {
        var callbacks_called: usize = 0;
        while (true) {
            const ev = self.events.receive(0) catch break;
            callbacks_called += self.dispatchEvent(ev);
        }
        return callbacks_called;
    }

    fn dispatchEvent(self: *@This(), ev: Event) usize {
        const watch = self.watchers.get(ev.fd) orelse return 0;
        return switch (ev.kind) {
            .read_ready => blk: {
                if (watch.read) |cb| {
                    cb.callback(cb.ptr, ev.fd);
                    break :blk 1;
                }
                break :blk 0;
            },
            .write_ready => blk: {
                if (watch.write) |cb| {
                    cb.callback(cb.ptr, ev.fd);
                    break :blk 1;
                }
                break :blk 0;
            },
        };
    }

    fn pushEvent(self: *@This(), ev: Event) void {
        self.events.send(&ev, 0) catch |err| switch (err) {
            error.QueueFull => {},
            else => {},
        };
    }

    fn drainWake(self: *@This()) void {
        while (self.wake_sem.take(0)) {}
    }

    fn timeoutMsToTicks(self: *const @This(), timeout_ms: i32) u32 {
        if (timeout_ms < 0) return std.math.maxInt(u32);
        if (timeout_ms == 0) return 0;
        const ms: u32 = @intCast(timeout_ms);
        return esp.freertos.msToTicks(ms, self.tick_rate_hz);
    }
};
