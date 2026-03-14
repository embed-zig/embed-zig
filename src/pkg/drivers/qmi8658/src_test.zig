const std = @import("std");
const testing = std.testing;
const module = @import("src.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const Address = module.Address;
const WHO_AM_I_VALUE = module.WHO_AM_I_VALUE;
const Register = module.Register;
const AccelRange = module.AccelRange;
const GyroRange = module.GyroRange;
const AccelOdr = module.AccelOdr;
const GyroOdr = module.GyroOdr;
const RawData = module.RawData;
const ScaledData = module.ScaledData;
const Angles = module.Angles;
const Config = module.Config;
const Qmi8658 = module.Qmi8658;

// ============================================================================
// Tests
// ============================================================================

const MockTime = struct {
    pub fn sleepMs(_: u32) void {}
};

const MockI2c = struct {
    registers: [256]u8 = [_]u8{0} ** 256,

    pub fn init() MockI2c {
        var self = MockI2c{};
        self.registers[@intFromEnum(Register.who_am_i)] = WHO_AM_I_VALUE;
        return self;
    }

    pub fn writeRead(self: *MockI2c, _: u7, write_buf: []const u8, read_buf: []u8) !void {
        if (write_buf.len > 0) {
            const start_reg = write_buf[0];
            for (read_buf, 0..) |*byte, i| {
                byte.* = self.registers[start_reg + i];
            }
        }
    }

    pub fn write(self: *MockI2c, _: u7, buf: []const u8) !void {
        if (buf.len >= 2) {
            const reg = buf[0];
            self.registers[reg] = buf[1];
        }
    }
};

test "Qmi8658 initialization" {
    var mock = MockI2c.init();
    var imu = Qmi8658(*MockI2c, MockTime).init(&mock, .{ .address = @intFromEnum(Address.sa0_low) });

    try imu.open();
    try std.testing.expect(imu.is_open);

    try imu.close();
    try std.testing.expect(!imu.is_open);
}

test "Qmi8658 self test" {
    var mock = MockI2c.init();
    var imu = Qmi8658(*MockI2c, MockTime).init(&mock, .{ .address = @intFromEnum(Address.sa0_low) });

    const result = try imu.selfTest();
    try std.testing.expect(result);
}

test "AccelRange sensitivity" {
    try std.testing.expectEqual(@as(f32, 16384.0), AccelRange.@"2g".sensitivity());
    try std.testing.expectEqual(@as(f32, 8192.0), AccelRange.@"4g".sensitivity());
    try std.testing.expectEqual(@as(f32, 4096.0), AccelRange.@"8g".sensitivity());
    try std.testing.expectEqual(@as(f32, 2048.0), AccelRange.@"16g".sensitivity());
}

test "GyroRange sensitivity" {
    try std.testing.expectEqual(@as(f32, 64.0), GyroRange.@"512dps".sensitivity());
    try std.testing.expectEqual(@as(f32, 32.0), GyroRange.@"1024dps".sensitivity());
}
