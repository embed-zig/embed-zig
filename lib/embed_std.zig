const zig_std = @import("std");
const embed_mod = @import("embed");
const sync_mod = @import("sync");
const channel_impl = @import("embed_std/sync/Channel.zig");

pub const embed = @import("embed_std/embed.zig");
pub const std = embed_mod.make(embed);
pub const sync = struct {
    pub const Channel = sync_mod.Channel(channel_impl.ChannelFactory(std));

    pub fn Racer(comptime T: type) type {
        return sync_mod.Racer(std, T);
    }
};

test "embed_std/compat_tests/embed/sync_channel" {
    try sync_mod.test_runner.channel.run(std, sync.Channel);
}

test "embed_std/compat_tests/embed/sync_racer" {
    try sync_mod.test_runner.racer.run(std);
}

test "embed_std/compat_tests/std/sync_channel" {
    const StdChannel = sync_mod.Channel(channel_impl.ChannelFactory(zig_std));
    try sync_mod.test_runner.channel.run(zig_std, StdChannel);
}

test "embed_std/compat_tests/std/sync_racer" {
    try sync_mod.test_runner.racer.run(zig_std);
}

test "embed_std/unit_tests/sync_channel_smoke" {
    const Channel = sync.Channel(u32);

    var ch = try Channel.make(std.testing.allocator, 1);
    defer ch.deinit();

    const send_result = try ch.send(42);
    try std.testing.expect(send_result.ok);

    const recv_result = try ch.recv();
    try std.testing.expect(recv_result.ok);
    try std.testing.expectEqual(@as(u32, 42), recv_result.value);

    ch.close();
}
