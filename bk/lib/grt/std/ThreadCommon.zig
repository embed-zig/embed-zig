const glib = @import("glib");
const this = @import("ThreadCommon.zig");

const BK_OK = 0;
const wait_forever: u32 = 0xffff_ffff;
const ns_per_ms: u64 = 1_000_000;

pub const Id = usize;
pub const max_name_len: usize = 15;
pub const default_stack_size: usize = 4096;

pub const RawThread = ?*anyopaque;
const RawMutex = ?*anyopaque;
const RawSemaphore = ?*anyopaque;
pub const ThreadFn = *const fn (?*anyopaque) callconv(.c) void;
pub const CreateThreadFn = *const fn (
    thread: *RawThread,
    priority: u8,
    name: [*:0]const u8,
    function: ThreadFn,
    stack_size: u32,
    arg: ?*anyopaque,
    core_id: ?i32,
) c_int;

extern fn malloc(size: usize) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) void;
extern fn rtos_delete_thread(thread: ?*RawThread) c_int;
extern fn rtos_get_current_thread() RawThread;
extern fn rtos_delay_milliseconds(num_ms: u32) c_int;
extern fn rtos_init_mutex(mutex: *RawMutex) c_int;
extern fn rtos_trylock_mutex(mutex: *RawMutex) c_int;
extern fn rtos_lock_mutex(mutex: *RawMutex) c_int;
extern fn rtos_unlock_mutex(mutex: *RawMutex) c_int;
extern fn rtos_deinit_mutex(mutex: *RawMutex) c_int;
extern fn rtos_init_semaphore_ex(semaphore: *RawSemaphore, max_count: c_int, init_count: c_int) c_int;
extern fn rtos_get_semaphore(semaphore: *RawSemaphore, timeout_ms: u32) c_int;
extern fn rtos_set_semaphore(semaphore: *RawSemaphore) c_int;
extern fn rtos_deinit_semaphore(semaphore: *RawSemaphore) c_int;

pub const Options = struct {
    createThread: CreateThreadFn,
    cpu_count: usize,
};

pub fn make(comptime options: Options) type {
    return struct {
        shared: *Shared,

        pub const Id = this.Id;
        pub const max_name_len = this.max_name_len;
        pub const default_stack_size = this.default_stack_size;
        pub const Mutex = this.Mutex;
        pub const Condition = this.Condition;
        pub const RwLock = this.RwLock;

        const Self = @This();

        const Lifecycle = enum {
            running_joinable,
            running_detached,
            finished_pending_join,
            finished_detached,
        };

        const Shared = struct {
            lock: this.Mutex = .{},
            done: RawSemaphore = null,
            state: Lifecycle = .running_joinable,
            handle: RawThread = null,
            destroy_fn: *const fn (*Shared) void,
        };

        pub fn spawn(config: glib.std.Thread.SpawnConfig, comptime f: anytype, args: anytype) glib.std.Thread.SpawnError!Self {
            const Packet = SpawnPacket(@TypeOf(args), f);
            const raw = malloc(@sizeOf(Packet)) orelse return error.OutOfMemory;
            const packet: *Packet = @ptrCast(@alignCast(raw));
            errdefer free(raw);

            packet.* = .{
                .shared = .{
                    .destroy_fn = Packet.destroy,
                },
                .args = args,
            };
            errdefer deinitSemaphore(&packet.shared.done);

            if (rtos_init_semaphore_ex(&packet.shared.done, 1, 0) != BK_OK) {
                return error.SystemResources;
            }

            var handle: RawThread = null;
            const rc = options.createThread(
                &handle,
                config.priority,
                config.name,
                Packet.entry,
                stackSize(config.stack_size),
                packet,
                config.core_id,
            );
            if (rc != BK_OK) return error.SystemResources;

            packet.shared.handle = handle;
            return .{ .shared = &packet.shared };
        }

        pub fn join(self: Self) void {
            _ = rtos_get_semaphore(&self.shared.done, wait_forever);

            var destroy_now = false;
            self.shared.lock.lock();
            switch (self.shared.state) {
                .finished_pending_join => {
                    self.shared.state = .finished_detached;
                    destroy_now = true;
                },
                .running_joinable => {
                    self.shared.state = .finished_detached;
                    destroy_now = true;
                },
                .running_detached, .finished_detached => {},
            }
            self.shared.lock.unlock();

            if (destroy_now) {
                destroyShared(self.shared);
            }
        }

        pub fn detach(self: Self) void {
            var destroy_now = false;

            self.shared.lock.lock();
            switch (self.shared.state) {
                .running_joinable => self.shared.state = .running_detached,
                .finished_pending_join => {
                    self.shared.state = .finished_detached;
                    destroy_now = true;
                },
                .running_detached, .finished_detached => {},
            }
            self.shared.lock.unlock();

            if (destroy_now) {
                destroyShared(self.shared);
            }
        }

        pub fn yield() glib.std.Thread.YieldError!void {
            _ = rtos_delay_milliseconds(1);
        }

        pub fn sleep(ns: u64) void {
            _ = rtos_delay_milliseconds(nsToMsCeil(ns));
        }

        pub fn getCpuCount() glib.std.Thread.CpuCountError!usize {
            return options.cpu_count;
        }

        pub fn getCurrentId() this.Id {
            const current = rtos_get_current_thread() orelse return 0;
            return @intFromPtr(current);
        }

        pub fn setName(name: []const u8) glib.std.Thread.SetNameError!void {
            if (name.len > this.max_name_len) return error.NameTooLong;
            return error.Unsupported;
        }

        pub fn getName(buf: *[this.max_name_len:0]u8) glib.std.Thread.GetNameError!?[]const u8 {
            _ = buf;
            return null;
        }

        fn destroyShared(shared: *Shared) void {
            shared.destroy_fn(shared);
        }

        fn SpawnPacket(comptime Args: type, comptime f: anytype) type {
            return struct {
                shared: Shared,
                args: Args,

                const Packet = @This();

                fn entry(arg: ?*anyopaque) callconv(.c) void {
                    const packet: *Packet = @ptrCast(@alignCast(arg.?));
                    invokeTask(packet.args);
                    packet.finishAndExit();
                }

                fn invokeTask(args: Args) void {
                    const ReturnType = @typeInfo(@TypeOf(f)).@"fn".return_type orelse void;
                    if (comptime @typeInfo(ReturnType) == .error_union) {
                        if (@call(.auto, f, args)) |_| {} else |_| {}
                    } else {
                        _ = @call(.auto, f, args);
                    }
                }

                fn finishAndExit(packet: *Packet) noreturn {
                    var destroy_now = false;

                    packet.shared.lock.lock();
                    switch (packet.shared.state) {
                        .running_joinable => {
                            packet.shared.state = .finished_pending_join;
                            _ = rtos_set_semaphore(&packet.shared.done);
                        },
                        .running_detached => {
                            packet.shared.state = .finished_detached;
                            destroy_now = true;
                        },
                        .finished_pending_join, .finished_detached => {},
                    }
                    packet.shared.lock.unlock();

                    if (destroy_now) {
                        Packet.destroy(&packet.shared);
                    }

                    _ = rtos_delete_thread(null);
                    unreachable;
                }

                fn destroy(shared: *Shared) void {
                    const packet: *Packet = @fieldParentPtr("shared", shared);
                    deinitSemaphore(&packet.shared.done);
                    packet.shared.lock.deinit();
                    free(packet);
                }
            };
        }
    };
}

pub fn currentThreadToken() usize {
    const current = rtos_get_current_thread() orelse return 1;
    const value = @intFromPtr(current);
    return if (value == 0) 1 else value;
}

pub const Mutex = struct {
    handle: RawMutex = null,

    pub fn lock(self: *Mutex) void {
        self.ensureInit();
        _ = rtos_lock_mutex(&self.handle);
    }

    pub fn unlock(self: *Mutex) void {
        if (self.handle != null) {
            _ = rtos_unlock_mutex(&self.handle);
        }
    }

    pub fn tryLock(self: *Mutex) bool {
        self.ensureInit();
        return rtos_trylock_mutex(&self.handle) == BK_OK;
    }

    pub fn deinit(self: *Mutex) void {
        if (self.handle != null) {
            _ = rtos_deinit_mutex(&self.handle);
        }
    }

    fn ensureInit(self: *Mutex) void {
        if (self.handle == null) {
            _ = rtos_init_mutex(&self.handle);
        }
    }
};

pub const Condition = struct {
    semaphore: RawSemaphore = null,
    lock: Mutex = .{},
    waiters: u32 = 0,

    pub fn wait(self: *Condition, mutex: *Mutex) void {
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

    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
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

    pub fn signal(self: *Condition) void {
        self.ensureInit();
        self.lock.lock();
        const should_signal = self.waiters != 0;
        self.lock.unlock();
        if (should_signal) {
            _ = rtos_set_semaphore(&self.semaphore);
        }
    }

    pub fn broadcast(self: *Condition) void {
        self.ensureInit();
        self.lock.lock();
        const count = self.waiters;
        self.lock.unlock();

        var i: u32 = 0;
        while (i < count) : (i += 1) {
            _ = rtos_set_semaphore(&self.semaphore);
        }
    }

    pub fn deinit(self: *Condition) void {
        deinitSemaphore(&self.semaphore);
        self.lock.deinit();
    }

    fn ensureInit(self: *Condition) void {
        if (self.semaphore == null) {
            _ = rtos_init_semaphore_ex(&self.semaphore, 1024, 0);
        }
    }
};

pub const RwLock = struct {
    mutex: Mutex = .{},

    pub fn lockShared(self: *RwLock) void {
        self.mutex.lock();
    }

    pub fn unlockShared(self: *RwLock) void {
        self.mutex.unlock();
    }

    pub fn lock(self: *RwLock) void {
        self.mutex.lock();
    }

    pub fn unlock(self: *RwLock) void {
        self.mutex.unlock();
    }

    pub fn tryLockShared(self: *RwLock) bool {
        return self.mutex.tryLock();
    }

    pub fn tryLock(self: *RwLock) bool {
        return self.mutex.tryLock();
    }

    pub fn deinit(self: *RwLock) void {
        self.mutex.deinit();
    }
};

fn deinitSemaphore(semaphore: *RawSemaphore) void {
    if (semaphore.* != null) {
        _ = rtos_deinit_semaphore(semaphore);
    }
}

fn stackSize(value: usize) u32 {
    const stack_size = if (value == 0) default_stack_size else value;
    return @intCast(@min(stack_size, glib.std.math.maxInt(u32)));
}

fn nsToMsCeil(ns: u64) u32 {
    if (ns == 0) return 0;
    const ms = (ns + ns_per_ms - 1) / ns_per_ms;
    return @intCast(@min(ms, glib.std.math.maxInt(u32)));
}
