const module = @import("imu.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const Error = module.Error;
const AccelData = module.AccelData;
const GyroData = module.GyroData;
const MagData = module.MagData;
const is = module.is;
const from = module.from;
const hal_marker = test_exports.hal_marker;

const std = @import("std");
const testing = std.testing;

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
