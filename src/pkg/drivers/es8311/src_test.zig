const std = @import("std");
const testing = std.testing;
const module = @import("src.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const i2c = @import("../../../hal/i2c.zig");
const Address = module.Address;
const Register = module.Register;
const ResetReg = module.ResetReg;
const ClkManager01 = module.ClkManager01;
const ClkManager06 = module.ClkManager06;
const SdpReg = module.SdpReg;
const Gpio44 = module.Gpio44;
const DacReg = module.DacReg;
const SystemDefaults = module.SystemDefaults;
const AdcDefaults = module.AdcDefaults;
const DacDefaults = module.DacDefaults;
const MicGain = module.MicGain;
const I2sFormat = module.I2sFormat;
const BitsPerSample = module.BitsPerSample;
const CodecMode = module.CodecMode;
const Config = module.Config;
const Es8311 = module.Es8311;

// ============================================================================
// Tests
// ============================================================================

const MockI2c = struct {
    registers: [256]u8 = [_]u8{0} ** 256,

    pub fn writeRead(self: *MockI2c, _: u7, write_buf: []const u8, read_buf: []u8) i2c.Error!void {
        if (write_buf.len > 0 and read_buf.len > 0) {
            const reg = write_buf[0];
            read_buf[0] = self.registers[reg];
        }
    }

    pub fn write(self: *MockI2c, _: u7, buf: []const u8) i2c.Error!void {
        if (buf.len >= 2) {
            const reg = buf[0];
            self.registers[reg] = buf[1];
        }
    }
};

const MockI2cSpec = struct {
    pub const Driver = MockI2c;
    pub const meta = .{ .id = "i2c.mock-es8311" };
};

test "Es8311 basic operations" {
    var mock = MockI2c{};
    var codec = Es8311(MockI2cSpec).init(&mock, .{ .address = @intFromEnum(Address.ad0_low) });

    try codec.open();
    try std.testing.expect(codec.is_open);

    try codec.setMicGain(.@"24dB");
    try std.testing.expectEqual(@as(u8, 4), mock.registers[@intFromEnum(Register.adc_16)]);

    try codec.setVolume(128);
    try std.testing.expectEqual(@as(u8, 128), mock.registers[@intFromEnum(Register.dac_32)]);
}

test "MicGain fromDb" {
    try std.testing.expectEqual(MicGain.@"0dB", MicGain.fromDb(0));
    try std.testing.expectEqual(MicGain.@"6dB", MicGain.fromDb(6));
    try std.testing.expectEqual(MicGain.@"24dB", MicGain.fromDb(24));
    try std.testing.expectEqual(MicGain.@"42dB", MicGain.fromDb(50));
}
