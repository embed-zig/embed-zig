pub const PageOutResult = enum {
    page_ready,
    need_more_data,
    sync_lost,
};

pub const PacketOutResult = enum {
    packet_ready,
    need_more_data,
    error_or_hole,
};

test "ogg/unit_tests/types/result_enums_stay_stable" {
    const std = @import("std");
    const testing = std.testing;

    try testing.expectEqual(@as(u2, 0), @intFromEnum(PageOutResult.page_ready));
    try testing.expectEqual(@as(u2, 1), @intFromEnum(PageOutResult.need_more_data));
    try testing.expectEqual(@as(u2, 2), @intFromEnum(PageOutResult.sync_lost));

    try testing.expectEqual(@as(u2, 0), @intFromEnum(PacketOutResult.packet_ready));
    try testing.expectEqual(@as(u2, 1), @intFromEnum(PacketOutResult.need_more_data));
    try testing.expectEqual(@as(u2, 2), @intFromEnum(PacketOutResult.error_or_hole));
}
