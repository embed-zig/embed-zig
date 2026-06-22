const common = @import("../../../grt/std/ThreadCommon.zig");
const glib = @import("glib");

extern fn rtos_smp_create_thread(thread: *common.RawThread, priority: u8, name: [*:0]const u8, function: common.ThreadFn, stack_size: u32, arg: ?*anyopaque) c_int;
extern fn rtos_core0_create_thread(thread: *common.RawThread, priority: u8, name: [*:0]const u8, function: common.ThreadFn, stack_size: u32, arg: ?*anyopaque) c_int;
extern fn rtos_core1_create_thread(thread: *common.RawThread, priority: u8, name: [*:0]const u8, function: common.ThreadFn, stack_size: u32, arg: ?*anyopaque) c_int;

const Impl = common.make(.{
    .createThread = createThread,
    .cpu_count = 2,
});

pub const Id = Impl.Id;
pub const max_name_len = Impl.max_name_len;
pub const default_stack_size = Impl.default_stack_size;
pub const Mutex = Impl.Mutex;
pub const Condition = Impl.Condition;
pub const RwLock = Impl.RwLock;

impl: Impl,

const Self = @This();

pub fn spawn(config: glib.std.Thread.SpawnConfig, comptime f: anytype, args: anytype) glib.std.Thread.SpawnError!Self {
    return .{ .impl = try Impl.spawn(config, f, args) };
}

pub fn join(self: Self) void {
    self.impl.join();
}

pub fn detach(self: Self) void {
    self.impl.detach();
}

pub fn yield() glib.std.Thread.YieldError!void {
    return Impl.yield();
}

pub fn sleep(ns: u64) void {
    Impl.sleep(ns);
}

pub fn getCpuCount() glib.std.Thread.CpuCountError!usize {
    return Impl.getCpuCount();
}

pub fn getCurrentId() Id {
    return Impl.getCurrentId();
}

pub fn setName(name: []const u8) glib.std.Thread.SetNameError!void {
    return Impl.setName(name);
}

pub fn getName(buf: *[max_name_len:0]u8) glib.std.Thread.GetNameError!?[]const u8 {
    return Impl.getName(buf);
}

fn createThread(
    handle: *common.RawThread,
    priority: u8,
    name: [*:0]const u8,
    entry: common.ThreadFn,
    stack_size: u32,
    arg: ?*anyopaque,
    core_id: ?i32,
) c_int {
    if (core_id) |core| {
        return switch (core) {
            0 => rtos_core0_create_thread(handle, priority, name, entry, stack_size, arg),
            1 => rtos_core1_create_thread(handle, priority, name, entry, stack_size, arg),
            else => -1,
        };
    }
    return rtos_smp_create_thread(handle, priority, name, entry, stack_size, arg);
}
