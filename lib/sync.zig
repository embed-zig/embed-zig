//! sync — thread coordination primitives.
//!
//! Usage:
//!   const sync = @import("sync");
//!   const U32Racer = sync.Racer(lib, u32);
//!   const Channel = sync.Channel(lib, platform.ChannelFactory);
//!   const IntChan = Channel(u32);
//!   const TimerImpl = sync.Timer.make(lib);
//!   const BytesPool = sync.Pool.make(lib, [256]u8);
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
pub const Pool = @import("sync/Pool.zig");
pub const Timer = @import("sync/Timer.zig");
pub const WakeFd = @import("sync/WakeFd.zig");

pub fn Channel(comptime lib: type, comptime factory: channel.FactoryType) channel.ChannelType {
    return channel.make(factory(lib));
}

pub fn Racer(comptime lib: type, comptime T: type) type {
    return racer_mod.Racer(lib, T);
}

pub const test_runner = struct {
    pub const unit = @import("sync/test_runner/unit.zig");
    pub const integration = @import("sync/test_runner/integration.zig");
};
