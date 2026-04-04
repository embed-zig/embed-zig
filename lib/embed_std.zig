const embed_mod = @import("embed");
const sync_mod = @import("sync");
const channel_mod = @import("embed_std/sync/Channel.zig");

pub const embed = @import("embed_std/embed.zig");
pub const std = embed_mod.make(embed);
pub const sync = struct {
    pub const ChannelFactory = channel_mod.ChannelFactory;
    pub const Channel = sync_mod.Channel(channel_mod.ChannelFactory(std));

    pub fn Racer(comptime T: type) type {
        return sync_mod.Racer(std, T);
    }
};

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
