const std = @import("std");
const testing = std.testing;
const module = @import("src.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const Address = module.Address;
const DEFAULT_ADDRESS = module.DEFAULT_ADDRESS;
const Register = module.Register;
const ResetReg = module.ResetReg;
const ClockOff = module.ClockOff;
const ModeConfig = module.ModeConfig;
const SdpInterface1 = module.SdpInterface1;
const SdpInterface2 = module.SdpInterface2;
const TimeControl0 = module.TimeControl0;
const AnalogReg = module.AnalogReg;
const MicBias = module.MicBias;
const MicPower = module.MicPower;
const GainReg = module.GainReg;
const HpfReg = module.HpfReg;
const PowerDown = module.PowerDown;
const MicSelect = module.MicSelect;
const Gain = module.Gain;
const I2sFormat = module.I2sFormat;
const BitsPerSample = module.BitsPerSample;
const MclkSource = module.MclkSource;
const Config = module.Config;
const Es7210 = module.Es7210;

// ============================================================================
// Tests
// ============================================================================

const MockI2c = struct {
    registers: [256]u8 = [_]u8{0} ** 256,

    pub fn writeRead(self: *MockI2c, _: u7, write_buf: []const u8, read_buf: []u8) !void {
        if (write_buf.len > 0 and read_buf.len > 0) {
            const reg = write_buf[0];
            read_buf[0] = self.registers[reg];
        }
    }

    pub fn write(self: *MockI2c, _: u7, buf: []const u8) !void {
        if (buf.len >= 2) {
            const reg = buf[0];
            self.registers[reg] = buf[1];
        }
    }
};

const MockI2cSpec = struct {
    pub const Driver = MockI2c;
    pub const meta = .{ .id = "test.i2c" };
};

test "Es7210 basic operations" {
    var mock = MockI2c{};
    var adc = Es7210(MockI2cSpec).init(&mock, .{
        .mic_select = .{ .mic1 = true, .mic2 = true, .mic3 = true },
    });

    // Test open
    try adc.open();
    try std.testing.expect(adc.is_open);

    // Test TDM mode (3 mics)
    try std.testing.expect(adc.isTdmMode());

    // Test set gain
    try adc.setGainAll(.@"24dB");
    try std.testing.expectEqual(Gain.@"24dB", adc.gain);
}

test "MicSelect operations" {
    const mics = MicSelect{ .mic1 = true, .mic2 = true, .mic3 = false, .mic4 = false };
    try std.testing.expectEqual(@as(u8, 2), mics.count());
    try std.testing.expectEqual(@as(u8, 0b0011), mics.toU8());
}

test "Gain fromDb" {
    try std.testing.expectEqual(Gain.@"0dB", Gain.fromDb(0));
    try std.testing.expectEqual(Gain.@"30dB", Gain.fromDb(30));
    try std.testing.expectEqual(Gain.@"37.5dB", Gain.fromDb(40));
}
