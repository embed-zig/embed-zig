const std = @import("std");
const esp = @import("esp");
const runtime = @import("runtime");

const default_name: [*:0]const u8 = "runtime.thread";
const default_priority: u32 = 5;

const ThreadState = struct {
    task: runtime.thread.types.TaskFn,
    ctx: ?*anyopaque,
    done: std.atomic.Value(bool),
    detached: std.atomic.Value(bool),
    freed: std.atomic.Value(bool),
};

pub const Thread = struct {
    handle: esp.freertos.TaskHandle = null,
    state: ?*ThreadState = null,

    pub fn spawn(
        config: runtime.thread.types.SpawnConfig,
        task: runtime.thread.types.TaskFn,
        ctx: ?*anyopaque,
    ) anyerror!Thread {
        _ = config.name;

        const state = try std.heap.c_allocator.create(ThreadState);
        errdefer std.heap.c_allocator.destroy(state);
        const stack = try std.heap.c_allocator.alloc(u8, config.stack_size);
        errdefer std.heap.c_allocator.free(stack);

        state.* = .{
            .task = task,
            .ctx = ctx,
            .done = std.atomic.Value(bool).init(false),
            .detached = std.atomic.Value(bool).init(false),
            .freed = std.atomic.Value(bool).init(false),
        };

        const handle = try esp.freertos.create(taskEntry, state, .{
            .stack = .{ .ptr = stack.ptr, .len = stack.len },
            .priority = default_priority,
            .name = default_name,
        });

        return .{
            .handle = handle,
            .state = state,
        };
    }

    pub fn join(self: *Thread) void {
        const state = self.state orelse return;
        while (!state.done.load(.acquire)) {
            esp.freertos.delay(1);
        }
        maybeFreeState(state);
        self.state = null;
        self.handle = null;
    }

    pub fn detach(self: *Thread) void {
        const state = self.state orelse return;
        state.detached.store(true, .release);
        if (state.done.load(.acquire)) {
            maybeFreeState(state);
        }
        self.state = null;
        self.handle = null;
    }
};

fn maybeFreeState(state: *ThreadState) void {
    if (state.freed.swap(true, .acq_rel)) return;
    std.heap.c_allocator.destroy(state);
}

fn taskEntry(raw: ?*anyopaque) callconv(.c) void {
    const state_ptr = raw orelse {
        esp.freertos.delete(null);
        return;
    };
    const state: *ThreadState = @ptrCast(@alignCast(state_ptr));

    state.task(state.ctx);
    state.done.store(true, .release);

    if (state.detached.load(.acquire)) {
        maybeFreeState(state);
    }

    esp.freertos.delete(null);
}
