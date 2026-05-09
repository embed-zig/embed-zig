//! FT5x06 I2C capacitive touch controller driver.
//!
//! Platform-independent driver for FocalTech FT5x06-compatible touch
//! controllers.
//!
//! Local docs:
//! - `lib/drivers/touch/ft5x06.md`
//! - `lib/drivers/touch/ft5x06.pdf`

const glib = @import("glib");
const I2c = @import("../I2c.zig");
const Touch = @import("../Touch.zig");

const ft5x06 = @This();

pub const default_address: I2c.Address = 0x38;
pub const max_points = Touch.max_points;

pub const Register = enum(u8) {
    device_mode = 0x00,
    gesture_id = 0x01,
    touch_count = 0x02,

    touch1_xh = 0x03,
    touch1_xl = 0x04,
    touch1_yh = 0x05,
    touch1_yl = 0x06,
    touch2_xh = 0x09,
    touch2_xl = 0x0a,
    touch2_yh = 0x0b,
    touch2_yl = 0x0c,
    touch3_xh = 0x0f,
    touch3_xl = 0x10,
    touch3_yh = 0x11,
    touch3_yl = 0x12,
    touch4_xh = 0x15,
    touch4_xl = 0x16,
    touch4_yh = 0x17,
    touch4_yl = 0x18,
    touch5_xh = 0x1b,
    touch5_xl = 0x1c,
    touch5_yh = 0x1d,
    touch5_yl = 0x1e,

    valid_touch_threshold = 0x80,
    peak_detect_threshold = 0x81,
    focus_threshold = 0x82,
    water_threshold = 0x83,
    temperature_threshold = 0x84,
    touch_difference_threshold = 0x85,
    control = 0x86,
    monitor_enter_time = 0x87,
    active_period = 0x88,
    monitor_period = 0x89,

    auto_calibration_mode = 0xa0,
    library_version_high = 0xa1,
    library_version_low = 0xa2,
    chip_vendor_id = 0xa3,
    interrupt_mode = 0xa4,
    power_mode = 0xa5,
    firmware_id = 0xa6,
    running_state = 0xa7,
    ctpm_vendor_id = 0xa8,
    error_code = 0xa9,
    calibration = 0xaa,
    big_area_threshold = 0xae,
};

pub const Gesture = enum(u8) {
    none = 0x00,
    move_up = 0x10,
    move_left = 0x14,
    move_down = 0x18,
    move_right = 0x1c,
    zoom_in = 0x48,
    zoom_out = 0x49,
    unknown = 0xff,

    pub fn fromU8(value: u8) Gesture {
        return switch (value) {
            0x00 => .none,
            0x10 => .move_up,
            0x14 => .move_left,
            0x18 => .move_down,
            0x1c => .move_right,
            0x48 => .zoom_in,
            0x49 => .zoom_out,
            else => .unknown,
        };
    }
};

pub const EventFlag = enum(u2) {
    put_down = 0,
    put_up = 1,
    contact = 2,
    reserved = 3,
};

pub const InterruptMode = enum(u2) {
    polling = 0,
    trigger = 1,
    reserved2 = 2,
    reserved3 = 3,
};

pub const PowerMode = enum(u2) {
    active = 0,
    monitor = 1,
    reserved = 2,
    hibernate = 3,
};

pub const Transform = struct {
    width: u16 = 0,
    height: u16 = 0,
    swap_xy: bool = false,
    invert_x: bool = false,
    invert_y: bool = false,
};

pub const Parameters = struct {
    valid_touch_threshold: ?u8 = null,
    peak_detect_threshold: ?u8 = null,
    focus_threshold: ?u8 = null,
    water_threshold: ?u8 = null,
    temperature_threshold: ?u8 = null,
    touch_difference_threshold: ?u8 = null,
    monitor_enter_time: ?u8 = null,
    active_period: ?u8 = null,
    monitor_period: ?u8 = null,
};

pub const Config = struct {
    address: I2c.Address = default_address,
    parameters: ?Parameters = null,
    transform: Transform = .{},
};

i2c: I2c,
config: Config,
callback_ctx: ?*const anyopaque = null,
callback_fn: ?Touch.CallbackFn = null,

pub fn init(i2c: I2c, config: Config) ft5x06 {
    return .{
        .i2c = i2c,
        .config = config,
    };
}

pub fn open(self: *ft5x06) !void {
    if (self.config.parameters) |parameters| {
        try self.configureParameters(parameters);
    }
}

pub fn readRegister(self: *ft5x06, reg: Register) !u8 {
    var buf: [1]u8 = undefined;
    try self.i2c.writeRead(self.config.address, &.{@intFromEnum(reg)}, &buf);
    return buf[0];
}

pub fn writeRegister(self: *ft5x06, reg: Register, value: u8) !void {
    try self.i2c.write(self.config.address, &.{ @intFromEnum(reg), value });
}

pub fn configureParameters(self: *ft5x06, parameters: Parameters) !void {
    if (parameters.valid_touch_threshold) |value| try self.writeRegister(.valid_touch_threshold, value);
    if (parameters.peak_detect_threshold) |value| try self.writeRegister(.peak_detect_threshold, value);
    if (parameters.focus_threshold) |value| try self.writeRegister(.focus_threshold, value);
    if (parameters.water_threshold) |value| try self.writeRegister(.water_threshold, value);
    if (parameters.temperature_threshold) |value| try self.writeRegister(.temperature_threshold, value);
    if (parameters.touch_difference_threshold) |value| try self.writeRegister(.touch_difference_threshold, value);
    if (parameters.monitor_enter_time) |value| try self.writeRegister(.monitor_enter_time, value);
    if (parameters.active_period) |value| try self.writeRegister(.active_period, value);
    if (parameters.monitor_period) |value| try self.writeRegister(.monitor_period, value);
}

pub fn setInterruptMode(self: *ft5x06, mode: InterruptMode) !void {
    try self.writeRegister(.interrupt_mode, @as(u8, @intFromEnum(mode)));
}

pub fn setPowerMode(self: *ft5x06, mode: PowerMode) !void {
    try self.writeRegister(.power_mode, @as(u8, @intFromEnum(mode)));
}

pub fn readGesture(self: *ft5x06) !Gesture {
    return Gesture.fromU8(try self.readRegister(.gesture_id));
}

pub fn read(self: *ft5x06, points: []Touch.Point) !usize {
    const count = (try self.readRegister(.touch_count)) & 0x0f;
    if (count == 0) return 0;
    if (count > max_points or count > points.len) return error.TooManyPoints;

    var index: usize = 0;
    while (index < count) : (index += 1) {
        points[index] = try self.readPoint(index);
    }
    return count;
}

pub fn pollAndEmit(self: *ft5x06) !void {
    const callback = self.callback_fn orelse return;
    const ctx = self.callback_ctx orelse return;

    var points: [max_points]Touch.Point = undefined;
    const count = try self.read(points[0..]);
    callback(ctx, .{
        .pressed = count != 0,
        .point_count = count,
        .primary = if (count == 0) null else points[0],
    });
}

pub fn setEventCallback(self: *ft5x06, ctx: *const anyopaque, emit_fn: Touch.CallbackFn) void {
    self.callback_ctx = ctx;
    self.callback_fn = emit_fn;
}

pub fn clearEventCallback(self: *ft5x06) void {
    self.callback_ctx = null;
    self.callback_fn = null;
}

pub fn asTouch(self: *ft5x06) Touch {
    return Touch.init(self);
}

fn readPoint(self: *ft5x06, index: usize) !Touch.Point {
    var data: [4]u8 = undefined;
    try self.i2c.writeRead(self.config.address, &.{pointRegister(index)}, &data);

    const raw_x = (@as(u16, data[0] & 0x0f) << 8) | data[1];
    const raw_y = (@as(u16, data[2] & 0x0f) << 8) | data[3];
    const id = data[2] >> 4;
    return transformPoint(.{
        .id = id,
        .x = raw_x,
        .y = raw_y,
    }, self.config.transform);
}

fn pointRegister(index: usize) u8 {
    return @intFromEnum(Register.touch1_xh) + @as(u8, @intCast(index * 6));
}

fn transformPoint(point: Touch.Point, transform: Transform) Touch.Point {
    var x = point.x;
    var y = point.y;

    if (transform.swap_xy) {
        const old_x = x;
        x = y;
        y = old_x;
    }

    x = clampAxis(x, transform.width);
    y = clampAxis(y, transform.height);

    if (transform.invert_x and transform.width != 0) {
        x = transform.width - 1 - x;
    }
    if (transform.invert_y and transform.height != 0) {
        y = transform.height - 1 - y;
    }

    return .{
        .id = point.id,
        .x = x,
        .y = y,
        .pressure = point.pressure,
    };
}

fn clampAxis(value: u16, size: u16) u16 {
    if (size == 0) return value;
    const max = size - 1;
    return if (value > max) max else value;
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const FakeI2c = struct {
        writes: [16][2]u8 = [_][2]u8{[_]u8{ 0, 0 }} ** 16,
        write_count: usize = 0,
        touch_count: u8 = 0,
        point_data: [max_points][4]u8 = [_][4]u8{[_]u8{ 0, 0, 0, 0 }} ** max_points,

        pub fn write(self: *@This(), _: I2c.Address, data: []const u8) I2c.Error!void {
            self.writes[self.write_count] = .{ data[0], data[1] };
            self.write_count += 1;
        }

        pub fn read(_: *@This(), _: I2c.Address, _: []u8) I2c.Error!void {
            return error.Unexpected;
        }

        pub fn writeRead(self: *@This(), _: I2c.Address, tx: []const u8, rx: []u8) I2c.Error!void {
            const reg = tx[0];
            if (reg == @intFromEnum(Register.touch_count)) {
                rx[0] = self.touch_count;
                return;
            }

            const touch1_xh = @intFromEnum(Register.touch1_xh);
            if (reg >= touch1_xh and (reg - touch1_xh) % 6 == 0) {
                const index = (reg - touch1_xh) / 6;
                @memcpy(rx[0..4], self.point_data[index][0..4]);
                return;
            }

            return error.Unexpected;
        }
    };

    const TestCase = struct {
        fn openWritesConfiguredParameters() !void {
            var fake = FakeI2c{};
            var driver = ft5x06.init(I2c.init(&fake), .{
                .parameters = .{
                    .valid_touch_threshold = 70,
                    .peak_detect_threshold = 60,
                    .focus_threshold = 16,
                    .water_threshold = 60,
                    .temperature_threshold = 10,
                    .touch_difference_threshold = 20,
                    .monitor_enter_time = 2,
                    .active_period = 12,
                    .monitor_period = 40,
                },
            });

            try driver.open();

            try grt.std.testing.expectEqual(@as(usize, 9), fake.write_count);
            try grt.std.testing.expectEqual([2]u8{ @intFromEnum(Register.valid_touch_threshold), 70 }, fake.writes[0]);
            try grt.std.testing.expectEqual([2]u8{ @intFromEnum(Register.touch_difference_threshold), 20 }, fake.writes[5]);
            try grt.std.testing.expectEqual([2]u8{ @intFromEnum(Register.monitor_period), 40 }, fake.writes[8]);
        }

        fn readDecodesTouchPointsAndAppliesTransform() !void {
            var fake = FakeI2c{};
            fake.touch_count = 1;
            fake.point_data[0] = .{
                0x00,
                10,
                0x30,
                20,
            };
            var driver = ft5x06.init(I2c.init(&fake), .{
                .transform = .{
                    .width = 320,
                    .height = 240,
                    .swap_xy = true,
                    .invert_y = true,
                },
            });

            var points: [max_points]Touch.Point = undefined;
            const count = try driver.read(points[0..]);

            try grt.std.testing.expectEqual(@as(usize, 1), count);
            try grt.std.testing.expectEqual(@as(u8, 3), points[0].id);
            try grt.std.testing.expectEqual(@as(u16, 20), points[0].x);
            try grt.std.testing.expectEqual(@as(u16, 229), points[0].y);
        }

        fn readRejectsTooManyPointsForBuffer() !void {
            var fake = FakeI2c{};
            fake.touch_count = 2;
            var driver = ft5x06.init(I2c.init(&fake), .{});
            var points: [1]Touch.Point = undefined;

            try grt.std.testing.expectError(error.TooManyPoints, driver.read(points[0..]));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.openWritesConfiguredParameters() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.readDecodesTouchPointsAndAppliesTransform() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.readRejectsTooManyPointsForBuffer() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
