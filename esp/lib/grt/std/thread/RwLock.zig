const binding = @import("binding.zig");
const heap_binding = @import("../heap/binding.zig");
const Mutex = @import("Mutex.zig");

const Handle = binding.Handle;
const pd_true = binding.pd_true;
extern fn printf(fmt: [*:0]const u8, ...) c_int;

const uninitialized: usize = 0;
const initializing: usize = 1;

state_bits: usize = uninitialized,

const RwLock = @This();

const State = struct {
    lock: Mutex = .{},
    writer_gate: Handle,
    readers: usize = 0,
};

pub fn lockShared(self: *RwLock) void {
    const state = self.ensureState();
    state.lock.lock();
    defer state.lock.unlock();

    if (state.readers == 0) {
        lockWriterGate(state);
    }
    state.readers += 1;
}

pub fn unlockShared(self: *RwLock) void {
    const state = self.ensureState();
    state.lock.lock();
    defer state.lock.unlock();
    if (state.readers == 0) {
        _ = printf(
            "[rwlock] unlockShared underflow self=0x%08x state=0x%08x gate=0x%08x readers=%u\n",
            @as(c_uint, @intCast(@intFromPtr(self))),
            @as(c_uint, @intCast(@intFromPtr(state))),
            @as(c_uint, @intCast(@intFromPtr(state.writer_gate.?))),
            @as(c_uint, @intCast(state.readers)),
        );
        @panic("freertos.thread.RwLock: unlockShared underflow");
    }
    state.readers -= 1;
    if (state.readers == 0) {
        unlockWriterGate(state);
    }
}

pub fn lock(self: *RwLock) void {
    lockWriterGate(self.ensureState());
}

pub fn unlock(self: *RwLock) void {
    unlockWriterGate(self.ensureState());
}

pub fn tryLockShared(self: *RwLock) bool {
    const state = self.ensureState();
    if (!state.lock.tryLock()) return false;
    defer state.lock.unlock();

    if (state.readers == 0 and !tryLockWriterGate(state)) {
        return false;
    }
    state.readers += 1;
    return true;
}

pub fn tryLock(self: *RwLock) bool {
    return tryLockWriterGate(self.ensureState());
}

fn lockWriterGate(state: *State) void {
    while (binding.espz_semaphore_take(state.writer_gate, binding.max_delay) != pd_true) {}
}

fn unlockWriterGate(state: *State) void {
    _ = binding.espz_semaphore_give(state.writer_gate);
}

fn tryLockWriterGate(state: *State) bool {
    return binding.espz_semaphore_take(state.writer_gate, 0) == pd_true;
}

fn ensureState(self: *RwLock) *State {
    while (true) {
        binding.espz_freertos_global_critical_enter();
        const bits = self.state_bits;
        switch (bits) {
            uninitialized => {
                self.state_bits = initializing;
                binding.espz_freertos_global_critical_exit();
                break;
            },
            initializing => {
                binding.espz_freertos_global_critical_exit();
                binding.espz_freertos_thread_yield();
            },
            else => {
                binding.espz_freertos_global_critical_exit();
                return @ptrFromInt(bits);
            },
        }
    }

    const raw = heap_binding.espz_heap_caps_malloc(
        @sizeOf(State),
        defaultInternalCaps(),
    ) orelse @panic("freertos.thread.RwLock: heap_caps_malloc failed");
    errdefer heap_binding.espz_heap_caps_free(raw);

    const state: *State = @ptrCast(@alignCast(raw));
    const handle = binding.espz_semaphore_create_binary() orelse
        @panic("freertos.thread.RwLock: xSemaphoreCreateBinary failed");
    if (binding.espz_semaphore_give(handle) != pd_true) {
        @panic("freertos.thread.RwLock: initial give failed");
    }

    state.* = .{
        .writer_gate = handle,
    };
    binding.espz_freertos_global_critical_enter();
    self.state_bits = @intFromPtr(state);
    binding.espz_freertos_global_critical_exit();
    return state;
}

fn defaultInternalCaps() u32 {
    return heap_binding.espz_heap_malloc_cap_internal() | heap_binding.espz_heap_malloc_cap_8bit();
}
