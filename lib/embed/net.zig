//! Network utilities — Ip4Address, matching std.net.Ip4Address shape.

const mem = @import("mem.zig");

pub fn Ip4Address(comptime posix: type) type {
    return extern struct {
        sa: posix.sockaddr.in,

        const Self = @This();

        pub fn init(addr: [4]u8, port: u16) Self {
            return .{
                .sa = .{
                    .port = mem.nativeToBig(u16, port),
                    .addr = @as(*align(1) const u32, @ptrCast(&addr)).*,
                },
            };
        }

        pub fn getPort(self: Self) u16 {
            return mem.bigToNative(u16, self.sa.port);
        }

        pub fn setPort(self: *Self, port: u16) void {
            self.sa.port = mem.nativeToBig(u16, port);
        }
    };
}
