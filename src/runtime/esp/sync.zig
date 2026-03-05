const std = @import("std");
const esp = @import("esp");
const runtime = @import("runtime");

const tick_rate_hz: u32 = 100;
const cond_max_waiters: u32 = 1024;
const notify_max_pending: u32 = 4096;

fn nsToTicks(timeout_ns: u64) u32 {
    if (timeout_ns == 0) return 0;
    const ms_ceil = (timeout_ns + (std.time.ns_per_ms - 1)) / std.time.ns_per_ms;
    const ms_u32: u32 = if (ms_ceil > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(ms_ceil);
    const ticks = esp.freertos.msToTicks(ms_u32, tick_rate_hz);
    return if (ticks == 0) 1 else ticks;
}

pub const Mutex = struct {
    raw: esp.freertos.sync.Mutex,

    pub fn init() @This() {
        return .{ .raw = esp.freertos.sync.Mutex.init() catch @panic("freertos: Mutex.init failed") };
    }

    pub fn deinit(self: *@This()) void {
        self.raw.deinit();
    }

    pub fn lock(self: *@This()) void {
        self.raw.lock();
    }

    pub fn unlock(self: *@This()) void {
        self.raw.unlock();
    }
};

pub const Condition = struct {
    wait_sem: esp.freertos.sync.Semaphore,
    waiters: std.atomic.Value(u32),

    pub const MutexType = Mutex;

    pub fn init() @This() {
        return .{
            .wait_sem = esp.freertos.sync.Semaphore.initCounting(cond_max_waiters, 0) catch @panic("freertos: Condition sem init failed"),
            .waiters = std.atomic.Value(u32).init(0),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.wait_sem.deinit();
    }

    pub fn wait(self: *@This(), mutex: *Mutex) void {
        _ = self.waiters.fetchAdd(1, .acq_rel);
        mutex.unlock();
        _ = self.wait_sem.take(esp.freertos.sync.max_delay);
        mutex.lock();
        _ = self.waiters.fetchSub(1, .acq_rel);
    }

    pub fn timedWait(self: *@This(), mutex: *Mutex, timeout_ns: u64) runtime.sync.types.TimedWaitResult {
        _ = self.waiters.fetchAdd(1, .acq_rel);
        mutex.unlock();
        const ok = self.wait_sem.take(nsToTicks(timeout_ns));
        mutex.lock();
        _ = self.waiters.fetchSub(1, .acq_rel);
        return if (ok) .signaled else .timed_out;
    }

    pub fn signal(self: *@This()) void {
        if (self.waiters.load(.acquire) > 0) {
            _ = self.wait_sem.give();
        }
    }

    pub fn broadcast(self: *@This()) void {
        const n = self.waiters.load(.acquire);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            _ = self.wait_sem.give();
        }
    }
};

pub const Notify = struct {
    sem: esp.freertos.sync.Semaphore,

    pub fn init() @This() {
        return .{
            .sem = esp.freertos.sync.Semaphore.initCounting(notify_max_pending, 0) catch @panic("freertos: Notify sem init failed"),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.sem.deinit();
    }

    pub fn signal(self: *@This()) void {
        _ = self.sem.give();
    }

    pub fn wait(self: *@This()) void {
        _ = self.sem.take(esp.freertos.sync.max_delay);
    }

    pub fn timedWait(self: *@This(), timeout_ns: u64) bool {
        return self.sem.take(nsToTicks(timeout_ns));
    }
};
