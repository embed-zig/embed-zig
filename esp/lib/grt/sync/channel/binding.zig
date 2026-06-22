const glib = @import("glib");

pub const Handle = ?*anyopaque;
pub const max_delay: u32 = glib.std.math.maxInt(u32);
pub const pd_true: i32 = 1;

pub extern fn espz_channel_semaphore_create_mutex() Handle;
pub extern fn espz_channel_semaphore_create_mutex_static(storage: ?*anyopaque) Handle;
pub extern fn espz_channel_semaphore_create_binary() Handle;
pub extern fn espz_channel_semaphore_create_binary_static(storage: ?*anyopaque) Handle;
pub extern fn espz_channel_semaphore_take(handle: Handle, ticks: u32) i32;
pub extern fn espz_channel_semaphore_give(handle: Handle) i32;
pub extern fn espz_channel_semaphore_delete(handle: Handle) void;

pub extern fn espz_channel_queue_create(length: u32, item_size: u32) Handle;
pub extern fn espz_channel_queue_create_static(length: u32, item_size: u32, queue_storage: ?*anyopaque, queue_control: ?*anyopaque) Handle;
pub extern fn espz_channel_queue_send(q: Handle, item: ?*const anyopaque, ticks: u32) i32;
pub extern fn espz_channel_queue_receive(q: Handle, buffer: ?*anyopaque, ticks: u32) i32;
pub extern fn espz_channel_queue_messages_waiting(q: Handle) u32;
pub extern fn espz_channel_queue_delete(q: Handle) void;

pub extern fn espz_channel_task_yield() void;
pub extern fn espz_channel_task_delay(ticks: u32) void;
pub extern fn espz_channel_tick_rate_hz() u32;
pub extern fn espz_channel_static_queue_size() u32;
pub extern fn espz_channel_static_queue_align() u32;
pub extern fn espz_channel_static_semaphore_size() u32;
pub extern fn espz_channel_static_semaphore_align() u32;
