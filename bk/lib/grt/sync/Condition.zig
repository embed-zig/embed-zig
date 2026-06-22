const glib = @import("glib");
const Mutex = @import("Mutex.zig").Impl;

const BK_OK = 0;
const wait_forever: u32 = 0xffff_ffff;
const ns_per_ms: u64 = 1_000_000;

const RawSemaphore = ?*anyopaque;

extern fn rtos_init_semaphore_ex(semaphore: *RawSemaphore, max_count: c_int, init_count: c_int) c_int;
extern fn rtos_get_semaphore(semaphore: *RawSemaphore, timeout_ms: u32) c_int;
extern fn rtos_set_semaphore(semaphore: *RawSemaphore) c_int;
extern fn rtos_deinit_semaphore(semaphore: *RawSemaphore) c_int;

pub const Impl = struct {
    semaphore: RawSemaphore = null,
    lock: Mutex = .{},
    waiters: u32 = 0,

    pub fn wait(self: *Impl, mutex: *Mutex) void {
        self.ensureInit();
        self.lock.lock();
        self.waiters += 1;
        self.lock.unlock();

        mutex.unlock();
        _ = rtos_get_semaphore(&self.semaphore, wait_forever);
        mutex.lock();

        self.lock.lock();
        if (self.waiters != 0) self.waiters -= 1;
        self.lock.unlock();
    }

    pub fn timedWait(self: *Impl, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
        self.ensureInit();
        self.lock.lock();
        self.waiters += 1;
        self.lock.unlock();

        mutex.unlock();
        const rc = rtos_get_semaphore(&self.semaphore, nsToMsCeil(timeout_ns));
        mutex.lock();

        self.lock.lock();
        if (self.waiters != 0) self.waiters -= 1;
        self.lock.unlock();

        if (rc != BK_OK) return error.Timeout;
    }

    pub fn signal(self: *Impl) void {
        self.ensureInit();
        self.lock.lock();
        const should_signal = self.waiters != 0;
        self.lock.unlock();
        if (should_signal) {
            _ = rtos_set_semaphore(&self.semaphore);
        }
    }

    pub fn broadcast(self: *Impl) void {
        self.ensureInit();
        self.lock.lock();
        const count = self.waiters;
        self.lock.unlock();

        var i: u32 = 0;
        while (i < count) : (i += 1) {
            _ = rtos_set_semaphore(&self.semaphore);
        }
    }

    pub fn deinit(self: *Impl) void {
        if (self.semaphore != null) {
            _ = rtos_deinit_semaphore(&self.semaphore);
            self.semaphore = null;
        }
        self.lock.deinit();
    }

    fn ensureInit(self: *Impl) void {
        if (self.semaphore == null) {
            _ = rtos_init_semaphore_ex(&self.semaphore, 1024, 0);
        }
    }
};

fn nsToMsCeil(ns: u64) u32 {
    if (ns == 0) return 0;
    const ms = (ns + ns_per_ms - 1) / ns_per_ms;
    return @intCast(@min(ms, glib.std.math.maxInt(u32)));
}
