pub const Accel = @import("imu/Accel.zig");
pub const Gyro = @import("imu/Gyro.zig");
pub const MotionDetector = @import("imu/MotionDetector.zig");

test {
    _ = @import("imu/Accel.zig");
    _ = @import("imu/Gyro.zig");
    _ = @import("imu/MotionDetector.zig");
}
