const std = @import("std");
const ch = @import("src/Channel.zig");

const impl = struct {
    pub const Thread = @import("src/Thread.zig");
    pub const Channel = ch.Channel;
    pub const log = @import("src/log.zig");
    pub const testing = @import("src/testing.zig");
    pub const posix = @import("src/posix.zig");
    pub const time = @import("src/time.zig");
    pub const crypto = @import("src/crypto.zig");
};

const embed = @import("embed").Make(impl);
const net = @import("net").Make(impl);
const sync = struct {
    pub const Channel = @import("sync").Channel(impl.Channel);
};

const test_runner = struct {
    pub const embed = @import("embed").test_runner;
    pub const sync = @import("sync").test_runner;
    pub const net = @import("net").test_runner;
};

test "fake_platform" {
    try test_runner.embed.std_compat.run(embed);
    try test_runner.sync.channel.run(embed, sync.Channel);
    try test_runner.sync.racer.run(embed);
    try test_runner.net.tcp.run(embed);
    try test_runner.net.udp.run(embed);
    try test_runner.net.tls.run(embed);
    try test_runner.net.resolver_fake.run(embed);
    try test_runner.net.resolver_ali_dns.run(embed);
}
