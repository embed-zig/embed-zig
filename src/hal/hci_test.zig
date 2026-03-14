const module = @import("hci.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const is = module.is;
const PollFlags = module.PollFlags;
const PacketType = module.PacketType;
const Error = module.Error;
const from = module.from;
const hal_marker = test_exports.hal_marker;

const std = @import("std");
const testing = std.testing;

test "hci wrapper basic" {
    const MockDriver = struct {
        const Self = @This();

        rx_buf: [8]u8 = .{ 0x04, 0x0E, 0x01, 0x00, 0, 0, 0, 0 },
        rx_len: usize = 4,
        tx_buf: [8]u8 = .{0} ** 8,

        pub fn read(self: *Self, buf: []u8) Error!usize {
            if (self.rx_len == 0) return error.WouldBlock;
            const n = @min(self.rx_len, buf.len);
            @memcpy(buf[0..n], self.rx_buf[0..n]);
            self.rx_len = 0;
            return n;
        }

        pub fn write(self: *Self, buf: []const u8) Error!usize {
            const n = @min(buf.len, self.tx_buf.len);
            @memcpy(self.tx_buf[0..n], buf[0..n]);
            return n;
        }

        pub fn poll(self: *Self, flags: PollFlags, _: i32) PollFlags {
            return .{
                .readable = flags.readable and self.rx_len > 0,
                .writable = flags.writable,
            };
        }
    };

    const Hci = from(struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "hci.test" };
    });

    var d = MockDriver{};
    var hci = Hci.init(&d);

    try std.testing.expect(hci.poll(.{ .readable = true }, 0).readable);

    var buf: [8]u8 = undefined;
    const n = try hci.read(&buf);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(u8, @intFromEnum(PacketType.event)), buf[0]);

    const cmd = [_]u8{ @intFromEnum(PacketType.command), 0x03, 0x0C, 0x00 };
    _ = try hci.write(&cmd);
    try std.testing.expectEqualSlices(u8, &cmd, d.tx_buf[0..cmd.len]);
}
