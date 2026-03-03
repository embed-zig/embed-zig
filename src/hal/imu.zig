//! IMU HAL wrapper.

const std = @import("std");
const hal_marker = @import("marker.zig");

pub const Error = error{
    NotReady,
    Timeout,
    InvalidData,
    BusError,
    SensorError,
};

pub const AccelData = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

pub const GyroData = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

pub const MagData = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .imu;
}

pub fn from(comptime spec: type) type {
    const BaseDriver = comptime switch (@typeInfo(spec.Driver)) {
        .pointer => |p| p.child,
        else => spec.Driver,
    };

    comptime {
        _ = @as(*const fn (*BaseDriver) Error!AccelData, &BaseDriver.readAccel);
        _ = @as(*const fn (*BaseDriver) Error!GyroData, &BaseDriver.readGyro);
        _ = @as(*const fn (*BaseDriver) Error!MagData, &BaseDriver.readMag);
        _ = @as(*const fn (*BaseDriver) Error!bool, &BaseDriver.isDataReady);

        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .imu,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const meta = spec.meta;

        pub const has_accel = true;
        pub const has_gyro = true;
        pub const has_mag = true;

        driver: *Driver,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn readAccel(self: *Self) Error!AccelData {
            return self.driver.readAccel();
        }

        pub fn readGyro(self: *Self) Error!GyroData {
            return self.driver.readGyro();
        }

        pub fn readMag(self: *Self) Error!MagData {
            return self.driver.readMag();
        }

        pub fn isDataReady(self: *Self) Error!bool {
            return self.driver.isDataReady();
        }
    };
}

test "imu 6-axis wrapper" {
    const Mock = struct {
        pub fn readAccel(_: *@This()) Error!AccelData {
            return .{ .x = 0.1, .y = 0.2, .z = 1.0 };
        }
        pub fn readGyro(_: *@This()) Error!GyroData {
            return .{ .x = 10, .y = 20, .z = 30 };
        }
        pub fn readMag(_: *@This()) Error!MagData {
            return .{ .x = 1, .y = 2, .z = 3 };
        }
        pub fn isDataReady(_: *@This()) Error!bool {
            return true;
        }
    };

    const Imu = from(struct {
        pub const Driver = Mock;
        pub const meta = .{ .id = "imu.test" };
    });

    var d = Mock{};
    var imu = Imu.init(&d);
    const acc = try imu.readAccel();
    const gyr = try imu.readGyro();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), acc.z, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), gyr.x, 0.001);
}
