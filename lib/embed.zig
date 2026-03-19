//! embed — cross-platform runtime library.
//!
//! Usage:
//!   const embed = @import("embed").Make(platform);
//!
//!   var t = try embed.Thread.spawn(.{}, myFunc, .{ &state });
//!   t.join();
//!
//!   const IntChan = embed.Channel(u32);
//!   var ch = try IntChan.make(allocator, 16);

const root = @This();

pub const channel = @import("embed/Channel.zig");
pub const thread = @import("embed/Thread.zig");
pub const log = @import("embed/log.zig");
pub const posix = @import("embed/posix.zig");
const net = @import("embed/net.zig");
const time = @import("embed/time.zig");
const mem = @import("embed/mem.zig");
const atomic = @import("embed/atomic.zig");
const testing = @import("embed/testing.zig");
pub const test_runner = struct {
    pub const std_compat = @import("embed/test_runner/std.zig");
    pub const channel = @import("embed/test_runner/channel.zig");
};

pub fn Make(comptime Impl: type) type {
    return struct {
        const Self = @This();
        pub const Thread = thread.make(Impl.Thread);
        pub const log = root.log.make(Impl.log);
        pub const posix = root.posix.make(Impl.posix);
        pub const time = root.time.make(Impl.time);
        pub const mem = root.mem;
        pub const atomic = root.atomic;
        pub const testing = root.testing;
        pub const net = struct {
            pub const Ip4Address = root.net.Ip4Address(Self.posix);
        };

        pub fn Channel(comptime T: type) type {
            const channel_factory = root.channel.makeFactory(Impl.Channel);
            return channel_factory.Channel(T);
        }
    };
}
