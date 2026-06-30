//! sync — thread coordination primitives.
//!
//! Usage:
//!   const sync = @import("sync");
//!   const U32Racer = sync.Racer(std, time, u32);
//!   const Channel = sync.Channel(std, platform.ChannelFactory);
//!   const IntChan = Channel(u32);
//!   const TimerImpl = sync.Timer.make(std, time);
//!   const BytesPool = sync.Pool.make(std, [256]u8);
//!
//!   var racer = try U32Racer.init(allocator);
//!   defer racer.deinit();
//!
//!   try racer.spawn(.{}, taskFn, .{});
//!   switch (racer.race()) {
//!       .winner => |value| _ = value,
//!       .exhausted => {},
//!   }

pub const channel = @import("sync/Channel.zig");
const racer_mod = @import("sync/Racer.zig");
pub const Arc = @import("sync/Arc.zig");
pub const Mutex = @import("sync/Mutex.zig");
pub const Condition = @import("sync/Condition.zig");
pub const Semaphore = @import("sync/Semaphore.zig");
pub const RwLock = @import("sync/RwLock.zig");
pub const Pool = @import("sync/Pool.zig");
pub const Timer = @import("sync/Timer.zig");
pub const WakeFd = @import("sync/WakeFd.zig");

pub fn Channel(comptime std: type, comptime factory: channel.FactoryType) channel.ChannelType {
    return channel.make(factory(std));
}

pub fn Racer(comptime std: type, comptime time: type, comptime T: type) type {
    _ = std;
    _ = time;
    _ = T;
    @compileError("sync.Racer requires explicit sync and task; use RacerWithTask");
}

pub fn RacerWithSync(comptime std: type, comptime time: type, comptime sync: type, comptime T: type) type {
    _ = std;
    _ = time;
    _ = sync;
    _ = T;
    @compileError("sync.RacerWithSync is removed; use RacerWithTask");
}

pub fn RacerWithTask(comptime std: type, comptime time: type, comptime sync: type, comptime task: type, comptime T: type) type {
    return racer_mod.Racer(std, time, sync, task, T);
}

pub const test_runner = struct {
    pub const unit = @import("sync/test_runner/unit.zig");
    pub const integration = @import("sync/test_runner/integration.zig");
};
