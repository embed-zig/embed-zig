const std = @import("std");
const ch = @import("src/Channel.zig");

const impl = struct {
    pub const Thread = @import("src/Thread.zig");
    pub const Channel = ch.Channel;
    pub const log = @import("src/log.zig");
    pub const posix = @import("src/posix.zig");
    pub const time = @import("src/time.zig");
    pub const crypto = @import("src/crypto.zig");
};

pub const embed = @import("embed").Make(impl);

const test_runner = @import("embed").test_runner;
const sync_test_runner = @import("sync").test_runner;
const net_test_runner = @import("net").test_runner;

test "fake_platform" {
    try test_runner.std_compat.run(embed);
    try sync_test_runner.channel.run(embed, impl.Channel, std.testing.allocator);
    try sync_test_runner.racer.run(embed);
    try net_test_runner.resolver_fake.run(embed);
    try net_test_runner.tls.run(embed);
    try net_test_runner.resolver_ali_dns.run(embed);
}
