const glib = @import("glib");
const binding = @import("thread/binding.zig");
const heap_binding = @import("heap/binding.zig");
const PacketMutex = @import("thread/PacketMutex.zig");

pub const Mutex = @import("thread/Mutex.zig");
pub const Condition = @import("thread/Condition.zig");
pub const RwLock = @import("thread/RwLock.zig");

const CoreId = i32;
const Handle = binding.Handle;
const pd_true = binding.pd_true;
const no_affinity: CoreId = 0x7fff_ffff;
const max_u32: usize = 0xffff_ffff;
const ns_per_s: u64 = 1_000_000_000;
const max_u64: u64 = ~@as(u64, 0);

pub const Id = usize;
pub const max_name_len: usize = 15;
pub const default_stack_size: usize = 8192;

shared: *Shared,

const Self = @This();

const StaticTaskAllocation = struct {
    allocator: glib.std.mem.Allocator,
    stack: []u8,
    stack_alignment: glib.std.mem.Alignment,
    task_buffer: []u8,

    fn free(self: @This()) void {
        self.allocator.rawFree(self.stack, self.stack_alignment, @returnAddress());
        heap_binding.espz_heap_caps_free(self.task_buffer.ptr);
    }
};

const Shared = struct {
    lock: PacketMutex,
    done: Handle,
    state: State = .running_joinable,
    handle: Handle = null,
    destroy_fn: *const fn (*Shared) void,
    static_task: ?StaticTaskAllocation = null,
    uses_caps_delete: bool = false,
};

const State = enum {
    running_joinable,
    running_detached,
    finished_pending_join,
    finished_detached,
};

pub fn spawn(config: glib.std.Thread.SpawnConfig, comptime f: anytype, args: anytype) glib.std.Thread.SpawnError!Self {
    const Packet = SpawnPacket(@TypeOf(args), f);
    const raw = heap_binding.espz_heap_caps_malloc(
        @sizeOf(Packet),
        defaultInternalCaps(),
    ) orelse return error.OutOfMemory;
    const packet: *Packet = @ptrCast(@alignCast(raw));
    errdefer heap_binding.espz_heap_caps_free(raw);

    const lock = PacketMutex.init() catch return error.SystemResources;
    errdefer {
        var cleanup = lock;
        cleanup.deinit();
    }

    const done = binding.espz_semaphore_create_binary() orelse return error.SystemResources;
    errdefer binding.espz_semaphore_delete(done);

    packet.* = .{
        .shared = .{
            .lock = lock,
            .done = done,
            .destroy_fn = &Packet.destroy,
        },
        .args = args,
    };

    const stack_size = stackSizeToU32(config.stack_size) catch return error.SystemResources;
    const core_id = if (config.core_id) |cpu| cpu else no_affinity;
    const static_task = if (config.allocator) |allocator|
        allocateStaticTask(allocator, stack_size) catch return error.SystemResources
    else
        null;
    errdefer if (static_task) |allocation| allocation.free();

    packet.shared.static_task = static_task;

    var handle: Handle = null;
    const created = if (static_task) |allocation|
        binding.espz_freertos_thread_spawn_static(
            &Packet.entry,
            config.name,
            stack_size,
            packet,
            config.priority,
            allocation.stack.ptr,
            allocation.task_buffer.ptr,
            &handle,
            core_id,
        )
    else
        binding.espz_freertos_thread_spawn_with_caps(
            &Packet.entry,
            config.name,
            stack_size,
            packet,
            config.priority,
            &handle,
            core_id,
            defaultExternalCaps(),
        );
    if (created != binding.pd_true) {
        return error.SystemResources;
    }

    packet.shared.handle = handle;
    packet.shared.uses_caps_delete = static_task == null;
    return .{ .shared = &packet.shared };
}

pub fn join(self: Self) void {
    while (binding.espz_semaphore_take(self.shared.done, binding.max_delay) != pd_true) {}

    self.shared.lock.lock();
    self.shared.state = .finished_detached;
    self.shared.lock.unlock();

    destroyShared(self.shared);
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
    binding.espz_freertos_thread_yield();
}

pub fn sleep(ns: u64) void {
    const ticks = nsToTicksCeil(ns);
    sleepTicks(ticks);
}

pub fn sleepTicks(ticks: u32) void {
    if (ticks == 0) return;
    binding.espz_freertos_task_delay(ticks);
}

pub fn getCpuCount() glib.std.Thread.CpuCountError!usize {
    const count = binding.espz_freertos_cpu_count();
    if (count == 0) return error.Unsupported;
    return count;
}

pub fn getCurrentId() Id {
    const handle = binding.espz_freertos_current_task_handle() orelse
        @panic("freertos.Thread.getCurrentId: current task handle unavailable");
    return @intFromPtr(handle);
}

pub fn setName(name: []const u8) glib.std.Thread.SetNameError!void {
    if (name.len > max_name_len) return error.NameTooLong;
    return error.Unsupported;
}

pub fn getName(buf: *[max_name_len:0]u8) glib.std.Thread.GetNameError!?[]const u8 {
    const current_name = glib.std.mem.sliceTo(binding.espz_freertos_current_task_name(), 0);
    if (current_name.len == 0) return null;

    const len = @min(current_name.len, max_name_len);
    @memcpy(buf[0..len], current_name[0..len]);
    buf[len] = 0;
    return buf[0..len];
}

fn defaultInternalCaps() u32 {
    return heap_binding.espz_heap_malloc_cap_internal() | heap_binding.espz_heap_malloc_cap_8bit();
}

fn defaultExternalCaps() u32 {
    return heap_binding.espz_heap_malloc_cap_spiram() | heap_binding.espz_heap_malloc_cap_8bit();
}

fn allocateStaticTask(
    allocator: glib.std.mem.Allocator,
    stack_size: u32,
) (glib.std.Thread.SpawnError || error{InvalidAlignment})!StaticTaskAllocation {
    const stack_len = binding.espz_freertos_align_stack_size_bytes(stack_size);
    if (stack_len == 0) return error.SystemResources;

    const task_buffer_len = binding.espz_freertos_static_task_size_bytes();
    if (task_buffer_len == 0) return error.SystemResources;

    const stack_alignment = try alignmentFromBytes(@max(
        binding.espz_freertos_stack_type_align_bytes(),
        binding.espz_freertos_stack_align_bytes(),
    ));
    const task_buffer_alignment = try alignmentFromBytes(binding.espz_freertos_static_task_align_bytes());

    const stack_ptr = allocator.rawAlloc(stack_len, stack_alignment, @returnAddress()) orelse
        return error.OutOfMemory;
    errdefer allocator.rawFree(stack_ptr[0..stack_len], stack_alignment, @returnAddress());

    const task_buffer_raw = if (task_buffer_alignment.toByteUnits() <= 1)
        heap_binding.espz_heap_caps_malloc(task_buffer_len, defaultInternalCaps())
    else
        heap_binding.espz_heap_caps_aligned_alloc(
            task_buffer_alignment.toByteUnits(),
            task_buffer_len,
            defaultInternalCaps(),
        );
    const task_buffer_ptr = task_buffer_raw orelse return error.OutOfMemory;
    errdefer heap_binding.espz_heap_caps_free(task_buffer_ptr);

    const task_buffer_bytes: [*]u8 = @ptrCast(task_buffer_ptr);

    return .{
        .allocator = allocator,
        .stack = stack_ptr[0..stack_len],
        .stack_alignment = stack_alignment,
        .task_buffer = task_buffer_bytes[0..task_buffer_len],
    };
}

fn alignmentFromBytes(bytes: u32) error{InvalidAlignment}!glib.std.mem.Alignment {
    if (bytes == 0) return error.InvalidAlignment;
    if ((bytes & (bytes - 1)) != 0) return error.InvalidAlignment;
    return glib.std.mem.Alignment.fromByteUnits(bytes);
}

fn nsToTicksCeil(timeout_ns: u64) u32 {
    if (timeout_ns == 0) return 0;

    const tick_rate_hz = binding.espz_freertos_tick_rate_hz();
    if (tick_rate_hz == 0) return binding.max_delay;

    const tick_ns = ns_per_s / tick_rate_hz;
    if (tick_ns == 0) return binding.max_delay;

    const extra = tick_ns - 1;
    if (timeout_ns > max_u64 - extra) return binding.max_delay;
    const adjusted = timeout_ns + extra;
    const ticks = adjusted / tick_ns;
    if (ticks > binding.max_delay) return binding.max_delay;
    return @intCast(ticks);
}

fn stackSizeToU32(size: usize) error{InvalidStackSize}!u32 {
    if (size == 0 or size > max_u32) return error.InvalidStackSize;
    return @intCast(size);
}

fn destroyShared(shared: *Shared) void {
    if (shared.static_task != null) {
        if (shared.handle) |handle| {
            binding.espz_freertos_task_delete(handle);
            shared.handle = null;
        }
    } else if (shared.uses_caps_delete) {
        // WithCaps tasks self-delete in finishAndExit(); external delete here would race.
        shared.handle = null;
    }
    shared.destroy_fn(shared);
}

fn SpawnPacket(comptime Args: type, comptime f: anytype) type {
    return struct {
        shared: Shared,
        args: Args,

        const Packet = @This();

        fn entry(ctx: ?*anyopaque) callconv(.c) void {
            const packet: *Packet = @ptrCast(@alignCast(ctx.?));
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
            const is_static_task = packet.shared.static_task != null;

            packet.shared.lock.lock();
            switch (packet.shared.state) {
                .running_joinable => packet.shared.state = .finished_pending_join,
                .running_detached => {
                    packet.shared.state = .finished_detached;
                    destroy_now = true;
                },
                .finished_pending_join, .finished_detached => {},
            }
            packet.shared.lock.unlock();

            if (destroy_now) {
                if (is_static_task) {
                    // Detached static tasks cannot safely free their own stack/TCB.
                    packet.shared.static_task = null;
                }
                Packet.destroy(&packet.shared);
                if (packet.shared.uses_caps_delete) {
                    binding.espz_freertos_task_delete_with_caps(null);
                } else {
                    binding.espz_freertos_task_delete(null);
                }
                unreachable;
            }

            _ = binding.espz_semaphore_give(packet.shared.done);

            if (is_static_task) {
                // Let join()/detach() delete the task before reclaiming its stack/TCB.
                binding.espz_freertos_task_suspend(null);
                unreachable;
            }

            if (packet.shared.uses_caps_delete) {
                binding.espz_freertos_task_delete_with_caps(null);
            } else {
                binding.espz_freertos_task_delete(null);
            }
            unreachable;
        }

        fn destroy(shared: *Shared) void {
            const packet: *Packet = @fieldParentPtr("shared", shared);
            binding.espz_semaphore_delete(packet.shared.done);
            packet.shared.lock.deinit();
            if (packet.shared.static_task) |allocation| {
                allocation.free();
            }
            heap_binding.espz_heap_caps_free(packet);
        }
    };
}
