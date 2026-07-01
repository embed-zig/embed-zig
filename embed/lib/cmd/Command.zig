const Output = @import("Output.zig");

const Command = @This();

name: []const u8,
desc: []const u8 = "",
handler: Handler,
ctx: ?*anyopaque = null,

pub const Handler = *const fn (
    ctx: ?*anyopaque,
    args: []const u8,
    out: Output,
) anyerror!void;
