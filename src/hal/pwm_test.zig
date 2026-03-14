const module = @import("pwm.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const Error = module.Error;
const Config = module.Config;
const is = module.is;
const from = module.from;
const hal_marker = test_exports.hal_marker;

const std = @import("std");
const testing = std.testing;

test "pwm wrapper" {
    const Mock = struct {
        duty: [4]u16 = [_]u16{0} ** 4,
        freq: [4]u32 = [_]u32{0} ** 4,

        pub fn setDuty(self: *@This(), channel: u8, duty: u16) Error!void {
            self.duty[channel] = duty;
        }
        pub fn getDuty(self: *@This(), channel: u8) Error!u16 {
            return self.duty[channel];
        }
        pub fn setFrequency(self: *@This(), channel: u8, hz: u32) Error!void {
            self.freq[channel] = hz;
        }
    };

    const Pwm = from(struct {
        pub const Driver = Mock;
        pub const meta = .{ .id = "pwm.test" };
        pub const config = Config{ .period_ticks = 1000, .frequency_hz = 1000 };
    });

    var d = Mock{};
    var pwm = Pwm.init(&d);
    try pwm.setPercent(0, 50);
    try std.testing.expectEqual(@as(u16, 500), try pwm.getDuty(0));
    try pwm.setFrequency(0, 2000);
    try std.testing.expectEqual(@as(u32, 2000), d.freq[0]);
}
