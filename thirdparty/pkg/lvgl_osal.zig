//! lvgl_osal — LVGL custom OSAL adapter.
//!
//! Usage:
//!   const lvgl_osal = @import("lvgl_osal");
//!   _ = lvgl_osal.make;

const glib = @import("glib");

const c = @cImport({
    @cInclude("lv_os_custom.h");
    @cInclude("src/osal/lv_os.h");
    @cInclude("src/stdlib/lv_mem.h");
});

pub fn make(comptime grt: type, comptime allocator: glib.std.mem.Allocator) type {
    return makeWithAllocators(grt, allocator, allocator);
}

pub fn makeWithAllocators(
    comptime grt: type,
    comptime os_allocator: glib.std.mem.Allocator,
    comptime memory_allocator: glib.std.mem.Allocator,
) type {
    comptime {
        if (!glib.runtime.is(grt)) @compileError("lvgl_osal.make requires a glib runtime namespace");
    }

    return struct {
        const Task = grt.task;
        const ThreadCallback = *const fn (?*anyopaque) callconv(.c) void;
        const allocation_alignment: glib.std.mem.Alignment = .@"16";
        const allocation_header_len: usize = 16;

        const AllocationHeader = extern struct {
            total_len: usize,
            payload_len: usize,
        };

        comptime {
            if (@sizeOf(AllocationHeader) > allocation_header_len) {
                @compileError("LVGL allocation header does not fit reserved prefix");
            }
        }

        const MutexImpl = struct {
            guard: grt.sync.Mutex = .{},
            cond: grt.sync.Condition = .{},
            owner: usize = 0,
            depth: usize = 0,

            fn lock(self: *@This()) void {
                const current = currentOwnerToken();

                self.guard.lock();
                defer self.guard.unlock();

                while (self.owner != 0) {
                    if (self.owner == current) break;
                    self.cond.wait(&self.guard);
                }

                if (self.owner == 0) self.owner = current;
                self.depth += 1;
            }

            fn tryLock(self: *@This()) bool {
                const current = currentOwnerToken();

                self.guard.lock();
                defer self.guard.unlock();

                if (self.owner == 0) {
                    self.owner = current;
                    self.depth = 1;
                    return true;
                }
                if (self.owner == current) {
                    self.depth += 1;
                    return true;
                }

                return false;
            }

            fn unlock(self: *@This()) bool {
                const current = currentOwnerToken();

                self.guard.lock();
                defer self.guard.unlock();

                if (self.owner == 0 or self.owner != current or self.depth == 0) return false;

                self.depth -= 1;
                if (self.depth == 0) {
                    self.owner = 0;
                    self.cond.signal();
                }

                return true;
            }
        };

        const ThreadSyncImpl = struct {
            mutex: grt.sync.Mutex = .{},
            cond: grt.sync.Condition = .{},
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
            handle: Task.Handle,
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

        fn currentOwnerToken() usize {
            const value = Task.currentToken();
            return if (value == 0) 1 else value;
        }

        fn taskOptions(stack_size: usize) glib.task.Options {
            return .{ .min_stack_size = normalizeStackSize(stack_size) };
        }

        fn taskName(name: ?[*:0]const u8) []const u8 {
            const ptr = name orelse return "lvgl/thread";
            const raw = glib.std.mem.sliceTo(ptr, 0);
            if (glib.std.mem.eql(u8, raw, "swdraw")) return "lvgl/swdraw";
            if (glib.std.mem.eql(u8, raw, "pxpdraw")) return "lvgl/pxpdraw";
            if (glib.std.mem.eql(u8, raw, "vglitedraw")) return "lvgl/vglitedraw";
            if (glib.std.mem.eql(u8, raw, "g2draw")) return "lvgl/g2draw";
            return "lvgl/thread";
        }

        fn normalizeStackSize(stack_size: usize) usize {
            if (stack_size == 0) return 0;
            if (stack_size < grt.std.heap.pageSize()) return 0;
            return stack_size;
        }

        fn createImpl(comptime T: type) ?*T {
            return os_allocator.create(T) catch return null;
        }

        fn destroyImpl(comptime T: type, impl: *T) void {
            os_allocator.destroy(impl);
        }

        fn allocationTotalLen(payload_len: usize) ?usize {
            const total_len, const overflow = @addWithOverflow(allocation_header_len, payload_len);
            if (overflow != 0) return null;
            return total_len;
        }

        fn allocationHeader(payload_ptr: *anyopaque) *AllocationHeader {
            const payload_addr = @intFromPtr(payload_ptr);
            const raw_addr = payload_addr - allocation_header_len;
            return @ptrCast(@alignCast(@as([*]u8, @ptrFromInt(raw_addr))));
        }

        fn payloadSlice(payload_ptr: *anyopaque) []u8 {
            const header = allocationHeader(payload_ptr);
            const payload_bytes: [*]u8 = @ptrCast(payload_ptr);
            return payload_bytes[0..header.payload_len];
        }

        fn rawSlice(payload_ptr: *anyopaque) []u8 {
            const header = allocationHeader(payload_ptr);
            const raw_bytes: [*]u8 = @ptrCast(header);
            return raw_bytes[0..header.total_len];
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
            const task_name = taskName(name);

            impl.* = .{
                .handle = undefined,
                .callback = cb,
                .user_data = user_data,
            };
            _ = prio;
            impl.handle = Task.go(task_name, taskOptions(stack_size), glib.task.Routine.init(impl, threadMain)) catch {
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

        pub export fn lv_mem_init() void {}

        pub export fn lv_mem_deinit() void {}

        pub export fn lv_mem_add_pool(mem: ?*anyopaque, bytes: usize) c.lv_mem_pool_t {
            _ = mem;
            _ = bytes;
            return null;
        }

        pub export fn lv_mem_remove_pool(pool: c.lv_mem_pool_t) void {
            _ = pool;
        }

        pub export fn lv_malloc_core(size: usize) ?*anyopaque {
            if (size == 0) return null;
            const total_len = allocationTotalLen(size) orelse return null;
            const raw = memory_allocator.rawAlloc(total_len, allocation_alignment, @returnAddress()) orelse return null;
            const header: *AllocationHeader = @ptrCast(@alignCast(raw));
            header.* = .{
                .total_len = total_len,
                .payload_len = size,
            };
            return @ptrCast(raw + allocation_header_len);
        }

        pub export fn lv_realloc_core(ptr: ?*anyopaque, new_size: usize) ?*anyopaque {
            const payload_ptr = ptr orelse return lv_malloc_core(new_size);
            if (new_size == 0) {
                lv_free_core(payload_ptr);
                return null;
            }

            const old_payload = payloadSlice(payload_ptr);
            const new_payload = lv_malloc_core(new_size) orelse return null;
            const new_bytes: [*]u8 = @ptrCast(new_payload);
            const copy_len = @min(old_payload.len, new_size);
            @memcpy(new_bytes[0..copy_len], old_payload[0..copy_len]);
            lv_free_core(payload_ptr);
            return new_payload;
        }

        pub export fn lv_free_core(ptr: ?*anyopaque) void {
            const payload_ptr = ptr orelse return;
            memory_allocator.rawFree(rawSlice(payload_ptr), allocation_alignment, @returnAddress());
        }

        pub export fn lv_mem_monitor_core(mon_p: ?*c.lv_mem_monitor_t) void {
            _ = mon_p;
        }

        pub export fn lv_mem_test_core() c.lv_result_t {
            return ok();
        }
    };
}
