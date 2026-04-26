//! QMI8658 6-Axis IMU Driver
//!
//! Platform-independent driver for QST QMI8658 6-axis inertial measurement unit.
//! Integrates 3-axis accelerometer and 3-axis gyroscope.
//!
//! Features:
//! - Accelerometer: ±2g, ±4g, ±8g, ±16g full scale
//! - Gyroscope: ±16 to ±2048 dps full scale
//! - Configurable output data rate (ODR)
//! - Temperature sensor
//! - FIFO support
//!
//! Local docs:
//! - `lib/drivers/imu/qmi8658.md`
//! - `lib/drivers/imu/qmi8658.pdf`
//!
//! Usage:
//!   var imu = drivers.imu.Qmi8658.init(
//!       drivers.I2c.init(&my_i2c),
//!       drivers.Delay.init(&my_delay),
//!       .{ .address = 0x6A },
//!   );
//!   try imu.open();
//!   const data = try imu.readRaw();

const glib = @import("glib");
const Delay = @import("../Delay.zig");
const I2c = @import("../I2c.zig");

const qmi8658 = @This();
const degrees_per_radian: f32 = 57.29577951308232;
const pi: f32 = 3.141592653589793;
const half_pi: f32 = pi / 2.0;

fn absf(x: f32) f32 {
    return if (x < 0) -x else x;
}

fn atanApproxUnit(x: f32) f32 {
    const ax = absf(x);
    return (pi / 4.0) * x - x * (ax - 1.0) * (0.2447 + 0.0663 * ax);
}

fn atanApprox(x: f32) f32 {
    if (x > 1.0) return half_pi - atanApproxUnit(1.0 / x);
    if (x < -1.0) return -half_pi - atanApproxUnit(1.0 / x);
    return atanApproxUnit(x);
}

// Avoid a direct std dependency in library code. This keeps the approximation
// bounded for steep ratios while remaining precise enough for tilt estimation.
fn atan2Approx(y: f32, x: f32) f32 {
    if (x > 0) return atanApprox(y / x);
    if (x < 0 and y >= 0) return atanApprox(y / x) + pi;
    if (x < 0 and y < 0) return atanApprox(y / x) - pi;
    if (x == 0 and y > 0) return half_pi;
    if (x == 0 and y < 0) return -half_pi;
    return 0.0;
}

/// QMI8658 I2C addresses (depends on SA0 pin)
pub const Address = enum(u7) {
    sa0_low = 0x6A,
    sa0_high = 0x6B,
};

/// Expected WHO_AM_I value
pub const WHO_AM_I_VALUE: u8 = 0x05;

/// QMI8658 register addresses
pub const Register = enum(u8) {
    who_am_i = 0x00,
    revision_id = 0x01,
    ctrl1 = 0x02,
    ctrl2 = 0x03,
    ctrl3 = 0x04,
    ctrl4 = 0x05,
    ctrl5 = 0x06,
    ctrl6 = 0x07,
    ctrl7 = 0x08,
    ctrl8 = 0x09,
    ctrl9 = 0x0A,
    fifo_wtm_th = 0x13,
    fifo_ctrl = 0x14,
    fifo_smpl_cnt = 0x15,
    fifo_status = 0x16,
    fifo_data = 0x17,
    statusint = 0x2D,
    status0 = 0x2E,
    status1 = 0x2F,
    timestamp_low = 0x30,
    timestamp_mid = 0x31,
    timestamp_high = 0x32,
    temp_l = 0x33,
    temp_h = 0x34,
    ax_l = 0x35,
    ax_h = 0x36,
    ay_l = 0x37,
    ay_h = 0x38,
    az_l = 0x39,
    az_h = 0x3A,
    gx_l = 0x3B,
    gx_h = 0x3C,
    gy_l = 0x3D,
    gy_h = 0x3E,
    gz_l = 0x3F,
    gz_h = 0x40,
    cod_status = 0x46,
    dqw_l = 0x49,
    dqw_h = 0x4A,
    dqx_l = 0x4B,
    dqx_h = 0x4C,
    dqy_l = 0x4D,
    dqy_h = 0x4E,
    dqz_l = 0x4F,
    dqz_h = 0x50,
    dvx_l = 0x51,
    dvx_h = 0x52,
    dvy_l = 0x53,
    dvy_h = 0x54,
    dvz_l = 0x55,
    dvz_h = 0x56,
    tap_status = 0x59,
    step_cnt_low = 0x5A,
    step_cnt_mid = 0x5B,
    step_cnt_high = 0x5C,
    reset = 0x60,
};

// ============================================================================
// Configuration Enums
// ============================================================================

/// Accelerometer full scale range
pub const AccelRange = enum(u3) {
    @"2g" = 0b000,
    @"4g" = 0b001,
    @"8g" = 0b010,
    @"16g" = 0b011,

    pub fn sensitivity(self: AccelRange) f32 {
        return switch (self) {
            .@"2g" => 16384.0,
            .@"4g" => 8192.0,
            .@"8g" => 4096.0,
            .@"16g" => 2048.0,
        };
    }
};

/// Gyroscope full scale range
pub const GyroRange = enum(u3) {
    @"16dps" = 0b000,
    @"32dps" = 0b001,
    @"64dps" = 0b010,
    @"128dps" = 0b011,
    @"256dps" = 0b100,
    @"512dps" = 0b101,
    @"1024dps" = 0b110,
    @"2048dps" = 0b111,

    pub fn sensitivity(self: GyroRange) f32 {
        return switch (self) {
            .@"16dps" => 2048.0,
            .@"32dps" => 1024.0,
            .@"64dps" => 512.0,
            .@"128dps" => 256.0,
            .@"256dps" => 128.0,
            .@"512dps" => 64.0,
            .@"1024dps" => 32.0,
            .@"2048dps" => 16.0,
        };
    }
};

/// Output data rate for accelerometer
pub const AccelOdr = enum(u4) {
    @"8000Hz" = 0b0000,
    @"4000Hz" = 0b0001,
    @"2000Hz" = 0b0010,
    @"1000Hz" = 0b0011,
    @"500Hz" = 0b0100,
    @"250Hz" = 0b0101,
    @"125Hz" = 0b0110,
    @"62.5Hz" = 0b0111,
    @"31.25Hz" = 0b1000,
    low_power_128Hz = 0b1100,
    low_power_21Hz = 0b1101,
    low_power_11Hz = 0b1110,
    low_power_3Hz = 0b1111,
};

/// Output data rate for gyroscope
pub const GyroOdr = enum(u4) {
    @"8000Hz" = 0b0000,
    @"4000Hz" = 0b0001,
    @"2000Hz" = 0b0010,
    @"1000Hz" = 0b0011,
    @"500Hz" = 0b0100,
    @"250Hz" = 0b0101,
    @"125Hz" = 0b0110,
    @"62.5Hz" = 0b0111,
    @"31.25Hz" = 0b1000,
};

// ============================================================================
// Data Structures
// ============================================================================

/// Raw IMU data (16-bit signed values)
pub const RawData = struct {
    acc_x: i16 = 0,
    acc_y: i16 = 0,
    acc_z: i16 = 0,
    gyr_x: i16 = 0,
    gyr_y: i16 = 0,
    gyr_z: i16 = 0,
};

/// Scaled IMU data (physical units)
pub const ScaledData = struct {
    acc_x: f32 = 0,
    acc_y: f32 = 0,
    acc_z: f32 = 0,
    gyr_x: f32 = 0,
    gyr_y: f32 = 0,
    gyr_z: f32 = 0,
};

/// Euler angles calculated from accelerometer.
/// Yaw cannot be determined from accelerometer alone.
pub const Angles = struct {
    roll: f32 = 0,
    pitch: f32 = 0,
};

/// Configuration for QMI8658
pub const Config = struct {
    address: u7,
    accel_range: AccelRange = .@"4g",
    gyro_range: GyroRange = .@"512dps",
    accel_odr: AccelOdr = .@"250Hz",
    gyro_odr: GyroOdr = .@"250Hz",
};

// ============================================================================
// Driver Implementation
// ============================================================================

/// QMI8658 6-Axis IMU Driver using `drivers.I2c` and `drivers.Delay`.
const Self = @This();

pub const capabilities = struct {
    pub const has_gyro = true;
    pub const has_temp = true;
    pub const axis_count = 6;
};

i2c: I2c,
delay: Delay,
config: Config,
is_open: bool = false,

pub fn init(i2c: I2c, delay: Delay, config: Config) Self {
    return .{
        .i2c = i2c,
        .delay = delay,
        .config = config,
    };
}

pub fn readRegister(self: *Self, reg: Register) !u8 {
    var buf: [1]u8 = undefined;
    try self.i2c.writeRead(self.config.address, &.{@intFromEnum(reg)}, &buf);
    return buf[0];
}

pub fn writeRegister(self: *Self, reg: Register, value: u8) !void {
    try self.i2c.write(self.config.address, &.{ @intFromEnum(reg), value });
}

pub fn readRegisters(self: *Self, start_reg: Register, buf: []u8) !void {
    try self.i2c.writeRead(self.config.address, &.{@intFromEnum(start_reg)}, buf);
}

// ====================================================================
// High-level API
// ====================================================================

pub fn open(self: *Self) !void {
    const id = try self.readRegister(.who_am_i);
    if (id != WHO_AM_I_VALUE) {
        return error.InvalidChipId;
    }

    try self.writeRegister(.reset, 0xB0);

    self.delay.sleepMs(10);

    try self.writeRegister(.ctrl1, 0x40);
    try self.writeRegister(.ctrl7, 0x03);

    const ctrl2 = (@as(u8, @intFromEnum(self.config.accel_range)) << 4) |
        @as(u8, @intFromEnum(self.config.accel_odr));
    try self.writeRegister(.ctrl2, ctrl2);

    const ctrl3 = (@as(u8, @intFromEnum(self.config.gyro_range)) << 4) |
        @as(u8, @intFromEnum(self.config.gyro_odr));
    try self.writeRegister(.ctrl3, ctrl3);

    self.is_open = true;
}

pub fn close(self: *Self) !void {
    if (self.is_open) {
        try self.writeRegister(.ctrl7, 0x00);
        self.is_open = false;
    }
}

pub fn isDataReady(self: *Self) !bool {
    const status = try self.readRegister(.status0);
    return (status & 0x03) == 0x03;
}

pub fn readRaw(self: *Self) !qmi8658.RawData {
    if (!self.is_open) return error.NotOpen;

    var buf: [12]u8 = undefined;
    try self.readRegisters(.ax_l, &buf);

    return qmi8658.RawData{
        .acc_x = @bitCast([2]u8{ buf[0], buf[1] }),
        .acc_y = @bitCast([2]u8{ buf[2], buf[3] }),
        .acc_z = @bitCast([2]u8{ buf[4], buf[5] }),
        .gyr_x = @bitCast([2]u8{ buf[6], buf[7] }),
        .gyr_y = @bitCast([2]u8{ buf[8], buf[9] }),
        .gyr_z = @bitCast([2]u8{ buf[10], buf[11] }),
    };
}

pub fn readScaled(self: *Self) !qmi8658.ScaledData {
    const raw = try self.readRaw();
    const acc_sens = self.config.accel_range.sensitivity();
    const gyr_sens = self.config.gyro_range.sensitivity();

    return qmi8658.ScaledData{
        .acc_x = @as(f32, @floatFromInt(raw.acc_x)) / acc_sens,
        .acc_y = @as(f32, @floatFromInt(raw.acc_y)) / acc_sens,
        .acc_z = @as(f32, @floatFromInt(raw.acc_z)) / acc_sens,
        .gyr_x = @as(f32, @floatFromInt(raw.gyr_x)) / gyr_sens,
        .gyr_y = @as(f32, @floatFromInt(raw.gyr_y)) / gyr_sens,
        .gyr_z = @as(f32, @floatFromInt(raw.gyr_z)) / gyr_sens,
    };
}

/// Calculate approximate tilt angles from accelerometer data.
/// Only accurate when the device is stationary or moving slowly.
pub fn readAngles(self: *Self) !qmi8658.Angles {
    const raw = try self.readRaw();
    const ax: f32 = @floatFromInt(raw.acc_x);
    const ay: f32 = @floatFromInt(raw.acc_y);
    const az: f32 = @floatFromInt(raw.acc_z);

    const roll = atan2Approx(ay, az) * degrees_per_radian;
    const pitch = atan2Approx(-ax, @sqrt(ay * ay + az * az)) * degrees_per_radian;

    return qmi8658.Angles{
        .roll = roll,
        .pitch = pitch,
    };
}

pub fn readTemperature(self: *Self) !f32 {
    if (!self.is_open) return error.NotOpen;

    var buf: [2]u8 = undefined;
    try self.readRegisters(.temp_l, &buf);
    const raw: i16 = @bitCast([2]u8{ buf[0], buf[1] });

    return @as(f32, @floatFromInt(raw)) / 256.0 + 25.0;
}

pub fn setAccelRange(self: *Self, range: qmi8658.AccelRange) !void {
    self.config.accel_range = range;
    if (self.is_open) {
        const ctrl2 = (@as(u8, @intFromEnum(range)) << 4) |
            @as(u8, @intFromEnum(self.config.accel_odr));
        try self.writeRegister(.ctrl2, ctrl2);
    }
}

pub fn setGyroRange(self: *Self, range: qmi8658.GyroRange) !void {
    self.config.gyro_range = range;
    if (self.is_open) {
        const ctrl3 = (@as(u8, @intFromEnum(range)) << 4) |
            @as(u8, @intFromEnum(self.config.gyro_odr));
        try self.writeRegister(.ctrl3, ctrl3);
    }
}

pub fn selfTest(self: *Self) !bool {
    const id = try self.readRegister(.who_am_i);
    return id == WHO_AM_I_VALUE;
}

pub fn getRevisionId(self: *Self) !u8 {
    return self.readRegister(.revision_id);
}
pub fn TestRunner(comptime lib: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn openConfiguresChipAndUsesDelay() !void {
            const FakeI2c = struct {
                writes: [8][2]u8 = [_][2]u8{[_]u8{ 0, 0 }} ** 8,
                write_count: usize = 0,
                last_addr: I2c.Address = 0,

                pub fn write(self: *@This(), addr: I2c.Address, data: []const u8) I2c.Error!void {
                    self.last_addr = addr;
                    self.writes[self.write_count] = .{ data[0], data[1] };
                    self.write_count += 1;
                }

                pub fn read(self: *@This(), _: I2c.Address, _: []u8) I2c.Error!void {
                    _ = self;
                    return error.Unexpected;
                }

                pub fn writeRead(self: *@This(), addr: I2c.Address, tx: []const u8, rx: []u8) I2c.Error!void {
                    self.last_addr = addr;
                    if (tx.len == 1 and tx[0] == @intFromEnum(Register.who_am_i)) {
                        rx[0] = WHO_AM_I_VALUE;
                        return;
                    }
                    return error.Unexpected;
                }
            };

            const FakeDelay = struct {
                calls: usize = 0,
                last_ms: u32 = 0,

                pub fn sleepMs(self: *@This(), ms: u32) void {
                    self.calls += 1;
                    self.last_ms = ms;
                }
            };

            var fake_i2c = FakeI2c{};
            var fake_delay = FakeDelay{};
            var imu = qmi8658.init(I2c.init(&fake_i2c), Delay.init(&fake_delay), .{
                .address = @intFromEnum(Address.sa0_low),
            });

            try imu.open();

            try lib.testing.expect(imu.is_open);
            try lib.testing.expectEqual(@as(usize, 5), fake_i2c.write_count);
            try lib.testing.expectEqual(@as(I2c.Address, 0x6A), fake_i2c.last_addr);
            try lib.testing.expectEqual(@as(u32, 10), fake_delay.last_ms);
            try lib.testing.expectEqual(@as(usize, 1), fake_delay.calls);
            try lib.testing.expectEqual([2]u8{ @intFromEnum(Register.reset), 0xB0 }, fake_i2c.writes[0]);
            try lib.testing.expectEqual([2]u8{ @intFromEnum(Register.ctrl1), 0x40 }, fake_i2c.writes[1]);
            try lib.testing.expectEqual([2]u8{ @intFromEnum(Register.ctrl7), 0x03 }, fake_i2c.writes[2]);
            try lib.testing.expectEqual([2]u8{ @intFromEnum(Register.ctrl2), 0x15 }, fake_i2c.writes[3]);
            try lib.testing.expectEqual([2]u8{ @intFromEnum(Register.ctrl3), 0x55 }, fake_i2c.writes[4]);
        }

        fn atan2ApproxStaysCloseToStdMath() !void {
            var max_error_deg: f32 = 0.0;
            var yi: i16 = -128;
            while (yi <= 128) : (yi += 1) {
                var xi: i16 = -128;
                while (xi <= 128) : (xi += 1) {
                    if (xi == 0 and yi == 0) continue;

                    const y: f32 = @as(f32, @floatFromInt(yi)) / 8.0;
                    const x: f32 = @as(f32, @floatFromInt(xi)) / 8.0;
                    const approx = atan2Approx(y, x);
                    const exact = lib.math.atan2(y, x);
                    const error_deg = absf(approx - exact) * degrees_per_radian;

                    if (error_deg > max_error_deg) max_error_deg = error_deg;
                }
            }

            try lib.testing.expect(max_error_deg <= 0.1);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.openConfiguresChipAndUsesDelay() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.atan2ApproxStaysCloseToStdMath() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
