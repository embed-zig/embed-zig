const Context = @import("../Context.zig");

pub const CardType = enum {
    unknown,
    ntag,
    ndef,
};

source_id: u32,
uid: []const u8,
card_type: CardType = .unknown,
payload: []const u8 = "",
ctx: Context.Type = null,

test "zux/event/nfc/NfcRead/unit_tests/default_optional_fields" {
    const std = @import("std");

    const event: @This() = .{
        .source_id = 2,
        .uid = "04aabbcc",
    };

    try std.testing.expectEqual(@as(u32, 2), event.source_id);
    try std.testing.expectEqualStrings("04aabbcc", event.uid);
    try std.testing.expectEqual(CardType.unknown, event.card_type);
    try std.testing.expectEqualStrings("", event.payload);
    try std.testing.expect(event.ctx == null);
}
