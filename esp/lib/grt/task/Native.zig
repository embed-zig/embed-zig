const glib = @import("glib");
const binding = @import("../std/thread/binding.zig");
const heap_binding = @import("../std/heap/binding.zig");

const CoreId = i32;
const Handle = @This();
const RawHandle = binding.Handle;
const no_affinity: CoreId = 0x7fff_ffff;
const max_u32: usize = 0xffff_ffff;
const pd_true = binding.pd_true;
const running_joinable: u8 = 0;
const running_detached: u8 = 1;
const finished_pending_join: u8 = 2;
const finished_detached: u8 = 3;

shared: *Shared,

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
    done: RawHandle,
    handle: RawHandle = null,
    static_task: ?StaticTaskAllocation = null,
    uses_caps_delete: bool = false,
    state: glib.std.atomic.Value(u8) = glib.std.atomic.Value(u8).init(running_joinable),
    destroy_fn: *const fn (*Shared) void,
};

pub const SpawnError = error{
    ThreadQuotaExceeded,
    SystemResources,
    OutOfMemory,
    LockedMemoryLimitExceeded,
    Unexpected,
};
pub const SpawnConfig = struct {
    stack_size: usize = 0,
    allocator: ?glib.std.mem.Allocator = null,
    priority: u8 = 5,
    name: [*:0]const u8 = "task",
    core_id: ?i32 = null,
};
pub const max_name_len: usize = 15;
pub const default_stack_size: usize = 8192;

pub fn spawn(config: SpawnConfig, routine: glib.task.Routine) SpawnError!Handle {
    const raw = heap_binding.espz_heap_caps_aligned_alloc(
        @alignOf(TaskCommand),
        @sizeOf(TaskCommand),
        defaultInternalCaps(),
    ) orelse return error.OutOfMemory;
    const command: *TaskCommand = @ptrCast(@alignCast(raw));
    errdefer heap_binding.espz_heap_caps_free(raw);

    const done = binding.espz_semaphore_create_binary() orelse return error.SystemResources;
    errdefer binding.espz_semaphore_delete(done);

    command.* = .{
        .shared = .{
            .done = done,
            .destroy_fn = TaskCommand.destroy,
        },
        .routine = routine,
    };

    const stack_size = stackSizeToU32(config.stack_size) catch return error.SystemResources;
    const static_task = if (config.allocator) |allocator|
        allocateStaticTask(allocator, stack_size) catch return error.SystemResources
    else
        null;
    errdefer if (static_task) |allocation| allocation.free();

    command.shared.static_task = static_task;

    var handle: RawHandle = null;
    const core_id = if (config.core_id) |cpu| cpu else no_affinity;
    const created = if (static_task) |allocation|
        binding.espz_freertos_thread_spawn_static(
            TaskCommand.entry,
            config.name,
            stack_size,
            command,
            config.priority,
            allocation.stack.ptr,
            allocation.task_buffer.ptr,
            &handle,
            core_id,
        )
    else
        binding.espz_freertos_thread_spawn_with_caps(
            TaskCommand.entry,
            config.name,
            stack_size,
            command,
            config.priority,
            &handle,
            core_id,
            defaultExternalCaps(),
        );
    if (created != pd_true) return error.SystemResources;

    command.shared.handle = handle;
    command.shared.uses_caps_delete = static_task == null;
    return .{ .shared = &command.shared };
}

pub fn join(self: Handle) void {
    while (binding.espz_semaphore_take(self.shared.done, binding.max_delay) != pd_true) {}
    self.shared.state.store(finished_detached, .release);

    if (self.shared.static_task != null) {
        binding.espz_freertos_task_delete(self.shared.handle);
    }
    destroyShared(self.shared);
}

pub fn detach(self: Handle) void {
    while (true) {
        const state = self.shared.state.load(.acquire);
        switch (state) {
            running_joinable => {
                if (self.shared.state.cmpxchgWeak(running_joinable, running_detached, .acq_rel, .acquire) == null) {
                    return;
                }
            },
            finished_pending_join => {
                if (self.shared.state.cmpxchgWeak(finished_pending_join, finished_detached, .acq_rel, .acquire) == null) {
                    destroyShared(self.shared);
                    return;
                }
            },
            running_detached, finished_detached => return,
            else => return,
        }
    }
}

pub fn currentToken() usize {
    if (binding.espz_freertos_current_task_handle()) |handle| {
        const value = @intFromPtr(handle);
        if (value != 0) return value;
    }
    return 1;
}

fn destroyShared(shared: *Shared) void {
    shared.destroy_fn(shared);
}

const TaskCommand = struct {
    shared: Shared,
    routine: glib.task.Routine,

    fn entry(ctx: ?*anyopaque) callconv(.c) void {
        const command: *TaskCommand = @ptrCast(@alignCast(ctx.?));
        const is_static_task = command.shared.static_task != null;
        const uses_caps_delete = command.shared.uses_caps_delete;

        command.routine.run();
        const should_destroy = command.finish();

        if (is_static_task) {
            binding.espz_freertos_task_suspend(null);
            unreachable;
        }

        if (should_destroy) {
            destroyShared(&command.shared);
        }

        if (uses_caps_delete) {
            binding.espz_freertos_task_delete_with_caps(null);
        } else {
            binding.espz_freertos_task_delete(null);
        }
        unreachable;
    }

    fn finish(command: *TaskCommand) bool {
        while (true) {
            const state = command.shared.state.load(.acquire);
            switch (state) {
                running_joinable => {
                    if (command.shared.state.cmpxchgWeak(running_joinable, finished_pending_join, .acq_rel, .acquire) == null) {
                        _ = binding.espz_semaphore_give(command.shared.done);
                        return false;
                    }
                },
                running_detached => {
                    if (command.shared.state.cmpxchgWeak(running_detached, finished_detached, .acq_rel, .acquire) == null) {
                        return !isStaticTask(command);
                    }
                },
                finished_detached => return false,
                finished_pending_join => return false,
                else => return false,
            }
        }
    }

    fn isStaticTask(command: *TaskCommand) bool {
        return command.shared.static_task != null;
    }

    fn destroy(shared: *Shared) void {
        const command: *TaskCommand = @alignCast(@fieldParentPtr("shared", shared));
        binding.espz_semaphore_delete(command.shared.done);
        if (command.shared.static_task) |allocation| {
            allocation.free();
        }
        heap_binding.espz_heap_caps_free(command);
    }
};

fn allocateStaticTask(
    allocator: glib.std.mem.Allocator,
    stack_size: u32,
) (SpawnError || error{InvalidAlignment})!StaticTaskAllocation {
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

fn stackSizeToU32(value: usize) error{SystemResources}!u32 {
    const stack_size = if (value == 0) default_stack_size else value;
    if (stack_size == 0 or stack_size > max_u32) return error.SystemResources;
    return @intCast(stack_size);
}

fn alignmentFromBytes(bytes: usize) error{InvalidAlignment}!glib.std.mem.Alignment {
    return switch (bytes) {
        1 => .@"1",
        2 => .@"2",
        4 => .@"4",
        8 => .@"8",
        16 => .@"16",
        32 => .@"32",
        64 => .@"64",
        else => error.InvalidAlignment,
    };
}

fn defaultInternalCaps() u32 {
    return heap_binding.espz_heap_malloc_cap_internal() | heap_binding.espz_heap_malloc_cap_8bit();
}

fn defaultExternalCaps() u32 {
    return heap_binding.espz_heap_malloc_cap_spiram() | heap_binding.espz_heap_malloc_cap_8bit();
}
