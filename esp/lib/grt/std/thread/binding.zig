const glib = @import("glib");

pub const Handle = ?*anyopaque;
pub const max_delay: u32 = glib.std.math.maxInt(u32);
pub const pd_true: i32 = 1;

pub extern fn espz_semaphore_create_mutex() Handle;
pub extern fn espz_semaphore_create_binary() Handle;
pub extern fn espz_semaphore_create_counting(max_count: u32, initial_count: u32) Handle;
pub extern fn espz_semaphore_take(handle: Handle, ticks: u32) i32;
pub extern fn espz_semaphore_give(handle: Handle) i32;
pub extern fn espz_semaphore_delete(handle: Handle) void;

pub extern fn espz_queue_create(length: u32, item_size: u32) Handle;
pub extern fn espz_queue_send(q: Handle, item: ?*const anyopaque, ticks: u32) i32;
pub extern fn espz_queue_receive(q: Handle, buffer: ?*anyopaque, ticks: u32) i32;
pub extern fn espz_queue_messages_waiting(q: Handle) u32;
pub extern fn espz_queue_delete(q: Handle) void;
pub extern fn espz_queue_create_set(length: u32) Handle;
pub extern fn espz_queue_add_to_set(member: Handle, set: Handle) i32;
pub extern fn espz_queue_remove_from_set(member: Handle, set: Handle) i32;
pub extern fn espz_queue_select_from_set(set: Handle, ticks: u32) Handle;

pub extern fn espz_freertos_align_stack_size_bytes(size: u32) u32;
pub extern fn espz_freertos_static_task_size_bytes() u32;
pub extern fn espz_freertos_static_task_align_bytes() u32;
pub extern fn espz_freertos_stack_type_align_bytes() u32;
pub extern fn espz_freertos_stack_align_bytes() u32;
pub extern fn espz_freertos_thread_spawn(
    task_fn: *const fn (?*anyopaque) callconv(.c) void,
    name: [*:0]const u8,
    stack_size_bytes: u32,
    ctx: ?*anyopaque,
    priority: u32,
    out_handle: *?*anyopaque,
    core_id: i32,
) i32;
pub extern fn espz_freertos_thread_spawn_static(
    task_fn: *const fn (?*anyopaque) callconv(.c) void,
    name: [*:0]const u8,
    stack_size_bytes: u32,
    ctx: ?*anyopaque,
    priority: u32,
    stack_buffer: ?*anyopaque,
    task_buffer: ?*anyopaque,
    out_handle: *?*anyopaque,
    core_id: i32,
) i32;
pub extern fn espz_freertos_thread_spawn_with_caps(
    task_fn: *const fn (?*anyopaque) callconv(.c) void,
    name: [*:0]const u8,
    stack_size_bytes: u32,
    ctx: ?*anyopaque,
    priority: u32,
    out_handle: *?*anyopaque,
    core_id: i32,
    memory_caps: u32,
) i32;
pub extern fn espz_freertos_task_delay(ticks: u32) void;
pub extern fn espz_freertos_task_delete(task: ?*anyopaque) void;
pub extern fn espz_freertos_task_delete_with_caps(task: ?*anyopaque) void;
pub extern fn espz_freertos_task_suspend(task: ?*anyopaque) void;
pub extern fn espz_freertos_global_critical_enter() void;
pub extern fn espz_freertos_global_critical_exit() void;
pub extern fn espz_freertos_thread_yield() void;
pub extern fn espz_freertos_tick_rate_hz() u32;
pub extern fn espz_freertos_cpu_count() u32;
pub extern fn espz_freertos_current_task_handle() ?*anyopaque;
pub extern fn espz_freertos_current_task_name() [*:0]const u8;
