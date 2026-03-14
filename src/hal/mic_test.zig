const module = @import("mic.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const Error = module.Error;
const SampleFormat = module.SampleFormat;
const Config = module.Config;
const Frame = module.Frame;
const is = module.is;
const from = module.from;
const hal_marker = test_exports.hal_marker;

const std = @import("std");
const testing = std.testing;

test "mic wrapper" {
    const MockDriver = struct {
        sample_value: i16 = 1234,

        pub fn read(self: *@This(), buffer: []i16) Error!usize {
            for (buffer) |*s| s.* = self.sample_value;
            return buffer.len;
        }

        pub fn setGain(_: *@This(), _: i8) Error!void {}
        pub fn start(_: *@This()) Error!void {}
        pub fn stop(_: *@This()) Error!void {}
    };

    const Mic = from(struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "mic.test" };
        pub const config = Config{ .sample_rate = 16000 };
    });

    var d = MockDriver{};
    var mic = Mic.init(&d);

    var buffer: [16]i16 = undefined;
    const n = try mic.read(&buffer);
    try std.testing.expectEqual(@as(usize, 16), n);
    try std.testing.expectEqual(@as(i16, 1234), buffer[0]);
    try std.testing.expect(Mic.supportsGain());
    try std.testing.expectEqual(@as(u32, 160), Mic.samplesForMs(10));
}
