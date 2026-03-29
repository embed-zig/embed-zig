//! sync — thread coordination primitives.
//!
//! Usage:
//!   const sync = @import("sync");
//!   const U32Racer = sync.Racer(lib, u32);
//!   const Channel = sync.Channel(platform.Channel);
//!   const IntChan = Channel(u32);
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

pub fn Channel(comptime impl: fn (type) type) fn (type) type {
    return channel.make(impl);
}

pub fn Racer(comptime lib: type, comptime T: type) type {
    return racer_mod.Racer(lib, T);
}

pub const test_runner = struct {
    pub const channel = @import("sync/test_runner/channel.zig");
    pub const racer = @import("sync/test_runner/racer.zig");
};

test "sync/unit_tests" {
    _ = @import("sync/Channel.zig");
    _ = @import("sync/Racer.zig");
}
