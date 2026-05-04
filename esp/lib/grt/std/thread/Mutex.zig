const glib = @import("glib");
const binding = @import("binding.zig");

const Handle = binding.Handle;
const pd_true = binding.pd_true;

const uninitialized: usize = 0;
const initializing: usize = 1;

handle_bits: glib.std.atomic.Value(usize) = glib.std.atomic.Value(usize).init(uninitialized),

const Mutex = @This();

pub fn lock(self: *Mutex) void {
    const handle = self.ensureHandle();
    while (binding.espz_semaphore_take(handle, binding.max_delay) != pd_true) {}
}

pub fn unlock(self: *Mutex) void {
    if (self.currentHandle()) |handle| {
        _ = binding.espz_semaphore_give(handle);
    }
}

pub fn tryLock(self: *Mutex) bool {
    const handle = self.ensureHandle();
    return binding.espz_semaphore_take(handle, 0) == pd_true;
}

pub fn rawHandle(self: *Mutex) Handle {
    return self.currentHandle();
}

fn ensureHandle(self: *Mutex) Handle {
    while (true) {
        const bits = self.handle_bits.load(.acquire);
        switch (bits) {
            uninitialized => {
                if (self.handle_bits.cmpxchgWeak(uninitialized, initializing, .acq_rel, .acquire) == null) {
                    const handle = binding.espz_semaphore_create_mutex() orelse
                        @panic("freertos.thread.Mutex: xSemaphoreCreateMutex failed");
                    const handle_bits = @intFromPtr(handle);
                    self.handle_bits.store(handle_bits, .release);
                    return handle;
                }
            },
            initializing => binding.espz_freertos_thread_yield(),
            else => return @ptrFromInt(bits),
        }
    }
}

fn currentHandle(self: *Mutex) Handle {
    const bits = self.handle_bits.load(.acquire);
    return switch (bits) {
        uninitialized, initializing => null,
        else => @ptrFromInt(bits),
    };
}
