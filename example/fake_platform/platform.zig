const std = @import("std");
const ch = @import("src/Channel.zig");

const impl = struct {
    pub const Thread = @import("src/Thread.zig");
    pub const Channel = ch.Channel;
    pub const log = @import("src/log.zig");
    pub const posix = @import("src/posix.zig");
    pub const time = @import("src/time.zig");
};

pub const embed = @import("embed").Make(impl);

const test_runner = @import("embed").test_runner;

test "fake_platform" {
    try test_runner.std_compat.run(embed);
    try test_runner.channel.run(embed, std.testing.allocator);
}

