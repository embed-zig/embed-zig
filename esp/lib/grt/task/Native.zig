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

const Shared = struct {
    done: RawHandle,
    handle: RawHandle = null,
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

pub const StackMemory = enum {
    external,
    internal,
};

pub const SpawnConfig = struct {
    stack_size: usize = 0,
    priority: u8 = 5,
    name: [*:0]const u8 = "task",
    core_id: ?i32 = null,
    stack_memory: StackMemory = .external,
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

    var handle: RawHandle = null;
    const stack_size = stackSizeToU32(config.stack_size) catch return error.SystemResources;
    const core_id = if (config.core_id) |cpu| cpu else no_affinity;
    const created = binding.espz_freertos_thread_spawn_with_caps(
        TaskCommand.entry,
        config.name,
        stack_size,
        command,
        config.priority,
        &handle,
        core_id,
        stackMemoryCaps(config.stack_memory),
    );
    if (created != pd_true) return error.SystemResources;

    command.shared.handle = handle;
    return .{ .shared = &command.shared };
}

pub fn join(self: Handle) void {
    while (binding.espz_semaphore_take(self.shared.done, binding.max_delay) != pd_true) {}
    self.shared.state.store(finished_detached, .release);
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

pub fn currentStackHighWaterMarkBytes() usize {
    return binding.espz_freertos_current_stack_high_water_mark_bytes();
}

fn destroyShared(shared: *Shared) void {
    shared.destroy_fn(shared);
}

const TaskCommand = struct {
    shared: Shared,
    routine: glib.task.Routine,

    fn entry(ctx: ?*anyopaque) callconv(.c) void {
        const command: *TaskCommand = @ptrCast(@alignCast(ctx.?));

        command.routine.run();
        const should_destroy = command.finish();

        if (should_destroy) {
            destroyShared(&command.shared);
        }

        binding.espz_freertos_task_delete_with_caps(null);
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
                        return true;
                    }
                },
                finished_detached => return false,
                finished_pending_join => return false,
                else => return false,
            }
        }
    }

    fn destroy(shared: *Shared) void {
        const command: *TaskCommand = @alignCast(@fieldParentPtr("shared", shared));
        binding.espz_semaphore_delete(command.shared.done);
        heap_binding.espz_heap_caps_free(command);
    }
};

fn stackSizeToU32(value: usize) error{SystemResources}!u32 {
    const stack_size = if (value == 0) default_stack_size else value;
    if (stack_size == 0 or stack_size > max_u32) return error.SystemResources;
    return @intCast(stack_size);
}

fn stackMemoryCaps(memory: StackMemory) u32 {
    return switch (memory) {
        .external => defaultExternalCaps(),
        .internal => defaultInternalCaps(),
    };
}

fn defaultInternalCaps() u32 {
    return heap_binding.espz_heap_malloc_cap_internal() | heap_binding.espz_heap_malloc_cap_8bit();
}

fn defaultExternalCaps() u32 {
    return heap_binding.espz_heap_malloc_cap_spiram() | heap_binding.espz_heap_malloc_cap_8bit();
}
