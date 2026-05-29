//! GT911 I2C capacitive touch controller driver.
//!
//! Platform-independent driver for Goodix GT911-compatible touch controllers.

const glib = @import("glib");
const I2c = @import("../I2c.zig");
const Touch = @import("../Touch.zig");

const gt911 = @This();

pub const default_address: I2c.Address = 0x5d;
pub const backup_address: I2c.Address = 0x14;
pub const max_points = Touch.max_points;

pub const Register = enum(u16) {
    command = 0x8040,
    config = 0x8047,
    product_id = 0x8140,
    status = 0x814e,
    point1 = 0x814f,
};

pub const Transform = struct {
    width: u16 = 0,
    height: u16 = 0,
    swap_xy: bool = false,
    invert_x: bool = false,
    invert_y: bool = false,
};

pub const Config = struct {
    address: I2c.Address = default_address,
    transform: Transform = .{},
};

i2c: I2c,
config: Config,

pub fn init(i2c: I2c, config: Config) gt911 {
    return .{
        .i2c = i2c,
        .config = config,
    };
}

pub fn open(self: *gt911) !void {
    _ = try self.readProductId();
}

pub fn readProductId(self: *gt911) ![4]u8 {
    var buf: [4]u8 = undefined;
    try self.readRegisterBytes(.product_id, &buf);
    return buf;
}

pub fn read(self: *gt911, points: []Touch.Point) !usize {
    const status = try self.readRegisterByte(.status);
    if ((status & 0x80) == 0) {
        try self.clearStatus();
        return 0;
    }

    const count = status & 0x0f;
    if (count == 0 or count > max_points) {
        try self.clearStatus();
        return 0;
    }
    if (count > points.len) {
        try self.clearStatus();
        return error.TooManyPoints;
    }

    var data: [max_points * point_stride]u8 = undefined;
    const data_len = @as(usize, count) * point_stride;
    try self.readRegisterBytes(.point1, data[0..data_len]);
    try self.clearStatus();

    var index: usize = 0;
    while (index < count) : (index += 1) {
        points[index] = decodePoint(data[index * point_stride ..][0..point_stride], self.config.transform);
    }
    return count;
}

pub fn asTouch(self: *gt911) Touch {
    return Touch.init(self);
}

const point_stride: usize = 8;

fn readRegisterByte(self: *gt911, reg: Register) !u8 {
    var buf: [1]u8 = undefined;
    try self.readRegisterBytes(reg, &buf);
    return buf[0];
}

fn readRegisterBytes(self: *gt911, reg: Register, buf: []u8) !void {
    const address = @intFromEnum(reg);
    const tx = [_]u8{
        @as(u8, @intCast(address >> 8)),
        @as(u8, @intCast(address & 0xff)),
    };
    try self.i2c.writeRead(self.config.address, &tx, buf);
}

fn writeRegisterByte(self: *gt911, reg: Register, value: u8) !void {
    const address = @intFromEnum(reg);
    try self.i2c.write(self.config.address, &.{
        @as(u8, @intCast(address >> 8)),
        @as(u8, @intCast(address & 0xff)),
        value,
    });
}

fn clearStatus(self: *gt911) !void {
    try self.writeRegisterByte(.status, 0);
}

fn decodePoint(data: *const [point_stride]u8, transform: Transform) Touch.Point {
    return transformPoint(.{
        .id = data[0],
        .x = (@as(u16, data[2]) << 8) | data[1],
        .y = (@as(u16, data[4]) << 8) | data[3],
        .pressure = (@as(u16, data[6]) << 8) | data[5],
    }, transform);
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
        writes: [8][3]u8 = [_][3]u8{[_]u8{ 0, 0, 0 }} ** 8,
        write_count: usize = 0,
        product_id: [4]u8 = .{ '9', '1', '1', 0 },
        status: u8 = 0,
        point_data: [max_points][point_stride]u8 = [_][point_stride]u8{[_]u8{0} ** point_stride} ** max_points,

        pub fn write(self: *@This(), _: I2c.Address, data: []const u8) I2c.Error!void {
            self.writes[self.write_count] = .{ data[0], data[1], data[2] };
            self.write_count += 1;
        }

        pub fn read(_: *@This(), _: I2c.Address, _: []u8) I2c.Error!void {
            return error.Unexpected;
        }

        pub fn writeRead(self: *@This(), _: I2c.Address, tx: []const u8, rx: []u8) I2c.Error!void {
            const reg = (@as(u16, tx[0]) << 8) | tx[1];
            if (reg == @intFromEnum(Register.product_id)) {
                @memcpy(rx, self.product_id[0..rx.len]);
                return;
            }
            if (reg == @intFromEnum(Register.status)) {
                rx[0] = self.status;
                return;
            }
            if (reg == @intFromEnum(Register.point1)) {
                const count = rx.len / point_stride;
                var index: usize = 0;
                while (index < count) : (index += 1) {
                    @memcpy(rx[index * point_stride ..][0..point_stride], &self.point_data[index]);
                }
                return;
            }
            return error.Unexpected;
        }
    };

    const TestCase = struct {
        fn openReadsProductId() !void {
            var fake = FakeI2c{};
            var driver = gt911.init(I2c.init(&fake), .{});

            try driver.open();
        }

        fn readDecodesReadyTouchPointsAndClearsStatus() !void {
            var fake = FakeI2c{};
            fake.status = 0x81;
            fake.point_data[0] = .{
                7,
                0x34,
                0x12,
                0x78,
                0x56,
                0x9a,
                0xbc,
                0,
            };
            var driver = gt911.init(I2c.init(&fake), .{});

            var points: [max_points]Touch.Point = undefined;
            const count = try driver.read(points[0..]);

            try grt.std.testing.expectEqual(@as(usize, 1), count);
            try grt.std.testing.expectEqual(@as(u8, 7), points[0].id);
            try grt.std.testing.expectEqual(@as(u16, 0x1234), points[0].x);
            try grt.std.testing.expectEqual(@as(u16, 0x5678), points[0].y);
            try grt.std.testing.expectEqual(@as(?u16, 0xbc9a), points[0].pressure);
            try grt.std.testing.expectEqual(@as(usize, 1), fake.write_count);
            try grt.std.testing.expectEqual([3]u8{ 0x81, 0x4e, 0 }, fake.writes[0]);
        }

        fn readAppliesTransform() !void {
            var fake = FakeI2c{};
            fake.status = 0x81;
            fake.point_data[0] = .{
                3,
                10,
                0,
                20,
                0,
                0,
                0,
                0,
            };
            var driver = gt911.init(I2c.init(&fake), .{
                .transform = .{
                    .width = 480,
                    .height = 800,
                    .swap_xy = true,
                    .invert_x = true,
                },
            });

            var points: [max_points]Touch.Point = undefined;
            const count = try driver.read(points[0..]);

            try grt.std.testing.expectEqual(@as(usize, 1), count);
            try grt.std.testing.expectEqual(@as(u16, 459), points[0].x);
            try grt.std.testing.expectEqual(@as(u16, 10), points[0].y);
        }

        fn readRejectsTooManyPointsForBuffer() !void {
            var fake = FakeI2c{};
            fake.status = 0x82;
            var driver = gt911.init(I2c.init(&fake), .{});
            var points: [1]Touch.Point = undefined;

            try grt.std.testing.expectError(error.TooManyPoints, driver.read(points[0..]));
            try grt.std.testing.expectEqual(@as(usize, 1), fake.write_count);
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

            TestCase.openReadsProductId() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.readDecodesReadyTouchPointsAndClearsStatus() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.readAppliesTransform() catch |err| {
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
