const std = @import("std");
const embed = @import("embed");
const Time = embed.runtime.std.Time;

const std_time: Time = .{};

test "std time nowMs returns positive value" {
    const now = std_time.nowMs();
    try std.testing.expect(now > 0);
}
