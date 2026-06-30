const glib = @import("glib");
const binding = @import("binding.zig");

const Handle = binding.Handle;
const pd_true = binding.pd_true;
const uninitialized: usize = 0;
const initializing: usize = 1;
const semaphore_max_count = glib.std.math.maxInt(u32);
const ns_per_s: u64 = 1_000_000_000;

permits: usize = 0,
handle_bits: glib.std.atomic.Value(usize) = glib.std.atomic.Value(usize).init(uninitialized),

const Semaphore = @This();

pub fn wait(self: *Semaphore) void {
    const handle = self.ensureHandle();
    while (binding.espz_semaphore_take(handle, binding.max_delay) != pd_true) {}
}

pub fn timedWait(self: *Semaphore, timeout_ns: u64) error{Timeout}!void {
    const handle = self.ensureHandle();
    if (binding.espz_semaphore_take(handle, nsToTicksCeil(timeout_ns)) == pd_true) return;
    return error.Timeout;
}

pub fn post(self: *Semaphore) void {
    const handle = self.ensureHandle();
    _ = binding.espz_semaphore_give(handle);
}

pub fn rawHandle(self: *Semaphore) Handle {
    return self.currentHandle();
}

fn ensureHandle(self: *Semaphore) Handle {
    while (true) {
        const bits = self.handle_bits.load(.acquire);
        switch (bits) {
            uninitialized => {
                if (self.handle_bits.cmpxchgWeak(uninitialized, initializing, .acq_rel, .acquire) == null) {
                    const initial: u32 = @intCast(@min(self.permits, semaphore_max_count));
                    const handle = binding.espz_semaphore_create_counting(semaphore_max_count, initial) orelse
                        @panic("freertos.thread.Semaphore: xSemaphoreCreateCounting failed");
                    self.handle_bits.store(@intFromPtr(handle), .release);
                    return handle;
                }
            },
            initializing => binding.espz_freertos_thread_yield(),
            else => return @ptrFromInt(bits),
        }
    }
}

fn currentHandle(self: *Semaphore) Handle {
    const bits = self.handle_bits.load(.acquire);
    return switch (bits) {
        uninitialized, initializing => null,
        else => @ptrFromInt(bits),
    };
}

fn nsToTicksCeil(timeout_ns: u64) u32 {
    if (timeout_ns == 0) return 0;

    const tick_rate_hz = binding.espz_freertos_tick_rate_hz();
    if (tick_rate_hz == 0) return binding.max_delay;

    const tick_ns = ns_per_s / tick_rate_hz;
    if (tick_ns == 0) return binding.max_delay;

    const extra = tick_ns - 1;
    const adjusted, const overflow = @addWithOverflow(timeout_ns, extra);
    if (overflow != 0) return binding.max_delay;
    const ticks = adjusted / tick_ns;
    if (ticks > binding.max_delay) return binding.max_delay;
    return @intCast(ticks);
}
