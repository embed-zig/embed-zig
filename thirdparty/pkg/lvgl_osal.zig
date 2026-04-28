//! lvgl_osal — LVGL custom OSAL adapter.
//!
//! Usage:
//!   const lvgl_osal = @import("lvgl_osal");
//!   _ = lvgl_osal.make;

const glib = @import("glib");

const c = @cImport({
    @cInclude("lv_os_custom.h");
    @cInclude("src/osal/lv_os.h");
});

pub fn make(comptime grt: type, comptime allocator: glib.std.mem.Allocator) type {
    comptime {
        if (!glib.runtime.is(grt)) @compileError("lvgl_osal.make requires a glib runtime namespace");
    }

    return struct {
        const Thread = grt.std.Thread;
        const ThreadCallback = *const fn (?*anyopaque) callconv(.c) void;

        const MutexImpl = struct {
            guard: Thread.Mutex = .{},
            cond: Thread.Condition = .{},
            owner: ?Thread.Id = null,
            depth: usize = 0,

            fn lock(self: *@This()) void {
                const current = Thread.getCurrentId();

                self.guard.lock();
                defer self.guard.unlock();

                while (self.owner) |owner| {
                    if (owner == current) break;
                    self.cond.wait(&self.guard);
                }

                if (self.owner == null) self.owner = current;
                self.depth += 1;
            }

            fn tryLock(self: *@This()) bool {
                const current = Thread.getCurrentId();

                self.guard.lock();
                defer self.guard.unlock();

                if (self.owner == null) {
                    self.owner = current;
                    self.depth = 1;
                    return true;
                }
                if (self.owner.? == current) {
                    self.depth += 1;
                    return true;
                }

                return false;
            }

            fn unlock(self: *@This()) bool {
                const current = Thread.getCurrentId();

                self.guard.lock();
                defer self.guard.unlock();

                if (self.owner == null or self.owner.? != current or self.depth == 0) return false;

                self.depth -= 1;
                if (self.depth == 0) {
                    self.owner = null;
                    self.cond.signal();
                }

                return true;
            }
        };

        const ThreadSyncImpl = struct {
            mutex: Thread.Mutex = .{},
            cond: Thread.Condition = .{},
            signaled: bool = false,

            fn wait(self: *@This()) void {
                self.mutex.lock();
                defer self.mutex.unlock();

                while (!self.signaled) {
                    self.cond.wait(&self.mutex);
                }
                self.signaled = false;
            }

            fn signal(self: *@This()) void {
                self.mutex.lock();
                defer self.mutex.unlock();

                self.signaled = true;
                self.cond.signal();
            }
        };

        const ThreadImpl = struct {
            handle: Thread,
            callback: ThreadCallback,
            user_data: ?*anyopaque,
        };

        fn ok() c.lv_result_t {
            return c.LV_RESULT_OK;
        }

        fn invalid() c.lv_result_t {
            return c.LV_RESULT_INVALID;
        }

        // The generic embed thread primitives used here do not expose
        // interrupt-safe mutex or sync operations, so the ISR variants must
        // fail explicitly instead of reusing the blocking thread path.
        fn unsupportedFromIsr() c.lv_result_t {
            return invalid();
        }

        fn requireMutex(handle: ?*c.lv_mutex_t) ?*c.lv_mutex_t {
            return handle;
        }

        fn requireThread(handle: ?*c.lv_thread_t) ?*c.lv_thread_t {
            return handle;
        }

        fn requireSync(handle: ?*c.lv_thread_sync_t) ?*c.lv_thread_sync_t {
            return handle;
        }

        fn mutexImpl(handle: *c.lv_mutex_t) ?*MutexImpl {
            const ptr = handle.impl orelse return null;
            return @ptrCast(@alignCast(ptr));
        }

        fn threadImpl(handle: *c.lv_thread_t) ?*ThreadImpl {
            const ptr = handle.impl orelse return null;
            return @ptrCast(@alignCast(ptr));
        }

        fn syncImpl(handle: *c.lv_thread_sync_t) ?*ThreadSyncImpl {
            const ptr = handle.impl orelse return null;
            return @ptrCast(@alignCast(ptr));
        }

        fn threadMain(impl: *ThreadImpl) void {
            impl.callback(impl.user_data);
        }

        fn spawnConfig(name: ?[*:0]const u8, prio: c_int, stack_size: usize) Thread.SpawnConfig {
            const defaults = Thread.SpawnConfig{};
            return .{
                .stack_size = normalizeStackSize(stack_size),
                .allocator = allocator,
                .priority = clampPriority(prio, defaults.priority),
                .name = name orelse defaults.name,
                .core_id = defaults.core_id,
            };
        }

        fn normalizeStackSize(stack_size: usize) usize {
            if (stack_size == 0) return 0;
            if (stack_size < grt.std.heap.pageSize()) return 0;
            return stack_size;
        }

        fn clampPriority(prio: c_int, fallback: u8) u8 {
            if (prio < 0) return fallback;
            if (prio > @as(c_int, grt.std.math.maxInt(u8))) return grt.std.math.maxInt(u8);
            return @intCast(prio);
        }

        fn createImpl(comptime T: type) ?*T {
            return allocator.create(T) catch return null;
        }

        fn destroyImpl(comptime T: type, impl: *T) void {
            allocator.destroy(impl);
        }

        pub export fn lv_mutex_init(handle: ?*c.lv_mutex_t) c.lv_result_t {
            const mutex = requireMutex(handle) orelse return invalid();

            const impl = createImpl(MutexImpl) orelse return invalid();
            impl.* = .{};
            mutex.impl = @ptrCast(impl);
            return ok();
        }

        pub export fn lv_mutex_lock(handle: ?*c.lv_mutex_t) c.lv_result_t {
            const mutex = requireMutex(handle) orelse return invalid();
            const impl = mutexImpl(mutex) orelse return invalid();
            impl.lock();
            return ok();
        }

        pub export fn lv_mutex_lock_isr(handle: ?*c.lv_mutex_t) c.lv_result_t {
            _ = handle;
            return unsupportedFromIsr();
        }

        pub export fn lv_mutex_unlock(handle: ?*c.lv_mutex_t) c.lv_result_t {
            const mutex = requireMutex(handle) orelse return invalid();
            const impl = mutexImpl(mutex) orelse return invalid();
            return if (impl.unlock()) ok() else invalid();
        }

        pub export fn lv_mutex_delete(handle: ?*c.lv_mutex_t) c.lv_result_t {
            const mutex = requireMutex(handle) orelse return invalid();
            const impl = mutexImpl(mutex) orelse return invalid();

            mutex.impl = null;
            destroyImpl(MutexImpl, impl);
            return ok();
        }

        pub export fn lv_thread_sync_init(handle: ?*c.lv_thread_sync_t) c.lv_result_t {
            const sync = requireSync(handle) orelse return invalid();

            const impl = createImpl(ThreadSyncImpl) orelse return invalid();
            impl.* = .{};
            sync.impl = @ptrCast(impl);
            return ok();
        }

        pub export fn lv_thread_sync_wait(handle: ?*c.lv_thread_sync_t) c.lv_result_t {
            const sync = requireSync(handle) orelse return invalid();
            const impl = syncImpl(sync) orelse return invalid();
            impl.wait();
            return ok();
        }

        pub export fn lv_thread_sync_signal(handle: ?*c.lv_thread_sync_t) c.lv_result_t {
            const sync = requireSync(handle) orelse return invalid();
            const impl = syncImpl(sync) orelse return invalid();
            impl.signal();
            return ok();
        }

        pub export fn lv_thread_sync_signal_isr(handle: ?*c.lv_thread_sync_t) c.lv_result_t {
            _ = handle;
            return unsupportedFromIsr();
        }

        pub export fn lv_thread_sync_delete(handle: ?*c.lv_thread_sync_t) c.lv_result_t {
            const sync = requireSync(handle) orelse return invalid();
            const impl = syncImpl(sync) orelse return invalid();

            sync.impl = null;
            destroyImpl(ThreadSyncImpl, impl);
            return ok();
        }

        pub export fn lv_thread_init(
            handle: ?*c.lv_thread_t,
            name: ?[*:0]const u8,
            prio: c_int,
            callback: ?ThreadCallback,
            stack_size: usize,
            user_data: ?*anyopaque,
        ) c.lv_result_t {
            const thread = requireThread(handle) orelse return invalid();
            const cb = callback orelse return invalid();
            const impl = createImpl(ThreadImpl) orelse return invalid();

            impl.* = .{
                .handle = undefined,
                .callback = cb,
                .user_data = user_data,
            };
            impl.handle = Thread.spawn(spawnConfig(name, prio, stack_size), threadMain, .{impl}) catch {
                destroyImpl(ThreadImpl, impl);
                return invalid();
            };

            thread.impl = @ptrCast(impl);
            return ok();
        }

        pub export fn lv_thread_delete(handle: ?*c.lv_thread_t) c.lv_result_t {
            const thread = requireThread(handle) orelse return invalid();
            const impl = threadImpl(thread) orelse return invalid();

            thread.impl = null;
            impl.handle.join();
            destroyImpl(ThreadImpl, impl);
            return ok();
        }
    };
}
