const binding = @import("binding.zig");

const Handle = binding.Handle;
const pd_true = binding.pd_true;
const Mutex = @This();
pub const Error = error{CreateFailed};

handle: Handle = null,

pub fn init() Error!Mutex {
    return .{
        .handle = binding.espz_semaphore_create_mutex() orelse return error.CreateFailed,
    };
}

pub fn deinit(self: *Mutex) void {
    if (self.handle) |handle| {
        binding.espz_semaphore_delete(handle);
        self.handle = null;
    }
}

pub fn lock(self: *Mutex) void {
    while (binding.espz_semaphore_take(self.handle, binding.max_delay) != pd_true) {}
}

pub fn unlock(self: *Mutex) void {
    _ = binding.espz_semaphore_give(self.handle);
}

pub fn tryLock(self: *Mutex) bool {
    return binding.espz_semaphore_take(self.handle, 0) == pd_true;
}

pub fn rawHandle(self: *const Mutex) Handle {
    return self.handle;
}
