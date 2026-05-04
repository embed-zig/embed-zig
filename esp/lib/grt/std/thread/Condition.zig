const glib = @import("glib");
const binding = @import("binding.zig");
const heap_binding = @import("../heap/binding.zig");
const Mutex = @import("Mutex.zig");

const Handle = binding.Handle;
const pd_true = binding.pd_true;

const uninitialized: usize = 0;
const initializing: usize = 1;
const semaphore_max_count = glib.std.math.maxInt(u32);
const ns_per_s: u64 = 1_000_000_000;

state_bits: glib.std.atomic.Value(usize) = glib.std.atomic.Value(usize).init(uninitialized),

const Condition = @This();

const State = struct {
    lock: Mutex = .{},
    waiters: usize = 0,
    semaphore: Handle,
};

pub fn wait(self: *Condition, mutex: *Mutex) void {
    const state = self.ensureState();
    state.lock.lock();
    state.waiters += 1;
    state.lock.unlock();

    mutex.unlock();
    defer mutex.lock();

    while (binding.espz_semaphore_take(state.semaphore, binding.max_delay) != pd_true) {}
}

pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
    const state = self.ensureState();
    const timeout_ticks = nsToTicksCeil(timeout_ns);

    state.lock.lock();
    state.waiters += 1;
    state.lock.unlock();

    mutex.unlock();
    defer mutex.lock();

    if (binding.espz_semaphore_take(state.semaphore, timeout_ticks) == pd_true) return;

    state.lock.lock();
    if (state.waiters > 0) {
        state.waiters -= 1;
        state.lock.unlock();
        return error.Timeout;
    }
    state.lock.unlock();

    while (binding.espz_semaphore_take(state.semaphore, binding.max_delay) != pd_true) {}
}

pub fn signal(self: *Condition) void {
    const state = self.ensureState();

    state.lock.lock();
    if (state.waiters == 0) {
        state.lock.unlock();
        return;
    }
    state.waiters -= 1;
    state.lock.unlock();

    _ = binding.espz_semaphore_give(state.semaphore);
}

pub fn broadcast(self: *Condition) void {
    const state = self.ensureState();

    state.lock.lock();
    const waiter_count = state.waiters;
    state.waiters = 0;
    state.lock.unlock();

    for (0..waiter_count) |_| {
        _ = binding.espz_semaphore_give(state.semaphore);
    }
}

fn ensureState(self: *Condition) *State {
    while (true) {
        const bits = self.state_bits.load(.acquire);
        switch (bits) {
            uninitialized => {
                if (self.state_bits.cmpxchgWeak(uninitialized, initializing, .acq_rel, .acquire) == null) {
                    const raw = heap_binding.espz_heap_caps_malloc(
                        @sizeOf(State),
                        default_internal_caps(),
                    ) orelse @panic("freertos.thread.Condition: heap_caps_malloc failed");
                    const state: *State = @ptrCast(@alignCast(raw));
                    state.* = .{
                        .semaphore = binding.espz_semaphore_create_counting(semaphore_max_count, 0) orelse
                            @panic("freertos.thread.Condition: xSemaphoreCreateCounting failed"),
                    };
                    self.state_bits.store(@intFromPtr(state), .release);
                    return state;
                }
            },
            initializing => binding.espz_freertos_thread_yield(),
            else => return @ptrFromInt(bits),
        }
    }
}

fn default_internal_caps() u32 {
    return heap_binding.espz_heap_malloc_cap_internal() | heap_binding.espz_heap_malloc_cap_8bit();
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
