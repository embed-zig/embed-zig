const glib = @import("glib");

const BK_OK = 0;
const wait_forever: u32 = 0xffff_ffff;
const ns_per_ms: u64 = 1_000_000;
const max_count: c_int = glib.std.math.maxInt(c_int);

const RawSemaphore = ?*anyopaque;

extern fn rtos_init_semaphore_ex(semaphore: *RawSemaphore, max_count: c_int, init_count: c_int) c_int;
extern fn rtos_get_semaphore(semaphore: *RawSemaphore, timeout_ms: u32) c_int;
extern fn rtos_set_semaphore(semaphore: *RawSemaphore) c_int;
extern fn rtos_deinit_semaphore(semaphore: *RawSemaphore) c_int;

pub const Impl = struct {
    permits: usize = 0,
    semaphore: RawSemaphore = null,

    pub fn wait(self: *Impl) void {
        self.ensureInit();
        _ = rtos_get_semaphore(&self.semaphore, wait_forever);
    }

    pub fn timedWait(self: *Impl, timeout_ns: u64) error{Timeout}!void {
        self.ensureInit();
        if (rtos_get_semaphore(&self.semaphore, nsToMsCeil(timeout_ns)) == BK_OK) return;
        return error.Timeout;
    }

    pub fn post(self: *Impl) void {
        self.ensureInit();
        _ = rtos_set_semaphore(&self.semaphore);
    }

    pub fn deinit(self: *Impl) void {
        if (self.semaphore != null) {
            _ = rtos_deinit_semaphore(&self.semaphore);
            self.semaphore = null;
        }
    }

    fn ensureInit(self: *Impl) void {
        if (self.semaphore == null) {
            const initial: c_int = @intCast(@min(self.permits, @as(usize, @intCast(max_count))));
            _ = rtos_init_semaphore_ex(&self.semaphore, max_count, initial);
        }
    }
};

fn nsToMsCeil(ns: u64) u32 {
    if (ns == 0) return 0;
    const ms = (ns + ns_per_ms - 1) / ns_per_ms;
    return @intCast(@min(ms, glib.std.math.maxInt(u32)));
}
