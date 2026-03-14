const module = @import("gpio.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const Error = module.Error;
const Level = module.Level;
const Mode = module.Mode;
const Pull = module.Pull;
const PinConfig = module.PinConfig;
const is = module.is;
const from = module.from;
const hal_marker = test_exports.hal_marker;

const std = @import("std");
const testing = std.testing;

test "gpio wrapper" {
    const Mock = struct {
        pins: [8]Level = [_]Level{.low} ** 8,

        pub fn setMode(_: *@This(), _: u8, _: Mode) Error!void {}
        pub fn setLevel(self: *@This(), pin: u8, level: Level) Error!void {
            self.pins[pin] = level;
        }
        pub fn getLevel(self: *@This(), pin: u8) Error!Level {
            return self.pins[pin];
        }
        pub fn setPull(_: *@This(), _: u8, _: Pull) Error!void {}
    };

    const Gpio = from(struct {
        pub const Driver = Mock;
        pub const meta = .{ .id = "gpio.test" };
    });

    var d = Mock{};
    var gpio = Gpio.init(&d);
    try gpio.configure(1, .{ .mode = .output, .pull = .none });
    try gpio.setHigh(1);
    try std.testing.expectEqual(Level.high, try gpio.getLevel(1));
    try gpio.toggle(1);
    try std.testing.expectEqual(Level.low, try gpio.getLevel(1));
}
