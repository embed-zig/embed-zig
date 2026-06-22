const BK_OK = 0;

const RawMutex = ?*anyopaque;

extern fn rtos_init_mutex(mutex: *RawMutex) c_int;
extern fn rtos_trylock_mutex(mutex: *RawMutex) c_int;
extern fn rtos_lock_mutex(mutex: *RawMutex) c_int;
extern fn rtos_unlock_mutex(mutex: *RawMutex) c_int;
extern fn rtos_deinit_mutex(mutex: *RawMutex) c_int;

pub const Impl = struct {
    handle: RawMutex = null,

    pub fn lock(self: *Impl) void {
        self.ensureInit();
        _ = rtos_lock_mutex(&self.handle);
    }

    pub fn unlock(self: *Impl) void {
        if (self.handle != null) {
            _ = rtos_unlock_mutex(&self.handle);
        }
    }

    pub fn tryLock(self: *Impl) bool {
        self.ensureInit();
        return rtos_trylock_mutex(&self.handle) == BK_OK;
    }

    pub fn deinit(self: *Impl) void {
        if (self.handle != null) {
            _ = rtos_deinit_mutex(&self.handle);
            self.handle = null;
        }
    }

    fn ensureInit(self: *Impl) void {
        if (self.handle == null) {
            _ = rtos_init_mutex(&self.handle);
        }
    }
};
