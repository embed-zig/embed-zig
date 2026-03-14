const std = @import("std");
const testing = std.testing;
const module = @import("i2s.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const Error = module.Error;
const Role = module.Role;
const Mode = module.Mode;
const SlotMode = module.SlotMode;
const BitsPerSample = module.BitsPerSample;
const Direction = module.Direction;
const BusConfig = module.BusConfig;
const EndpointConfig = module.EndpointConfig;
const from = module.from;

test "i2s bus + endpoint wrapper" {
    const Mock = struct {
        pub const EndpointHandle = u8;

        pub fn initBus(_: BusConfig) Error!@This() {
            return .{};
        }
        pub fn deinitBus(_: *@This()) void {}
        pub fn registerEndpoint(_: *@This(), cfg: EndpointConfig) Error!EndpointHandle {
            return switch (cfg.direction) {
                .rx => 1,
                .tx => 2,
            };
        }
        pub fn unregisterEndpoint(_: *@This(), _: EndpointHandle) Error!void {}
        pub fn read(_: *@This(), _: EndpointHandle, out: []u8) Error!usize {
            if (out.len > 0) out[0] = 0x2A;
            return if (out.len > 0) 1 else 0;
        }
        pub fn write(_: *@This(), _: EndpointHandle, input: []const u8) Error!usize {
            return input.len;
        }
    };

    const I2s = from(struct {
        pub const Driver = Mock;
        pub const EndpointHandle = Mock.EndpointHandle;
        pub const meta = .{ .id = "i2s.test" };
    });

    var bus = try I2s.initBus(.{
        .bclk = 1,
        .ws = 2,
    });
    defer bus.deinitBus();

    var rx = try bus.openRx(3, 20);
    defer rx.deinit();
    var tx = try bus.openTx(4, 20);
    defer tx.deinit();

    var in: [1]u8 = .{0};
    const rn = try rx.read(&in);
    try @import("std").testing.expectEqual(@as(usize, 1), rn);
    try @import("std").testing.expectEqual(@as(u8, 0x2A), in[0]);

    const wn = try tx.write(&[_]u8{ 1, 2, 3 });
    try @import("std").testing.expectEqual(@as(usize, 3), wn);
}
