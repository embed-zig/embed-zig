const std = @import("std");
const testing = std.testing;
const module = @import("types.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const Axis = module.Axis;
const Orientation = module.Orientation;
const ShakeData = module.ShakeData;
const TapData = module.TapData;
const TiltData = module.TiltData;
const FlipData = module.FlipData;
const FreefallData = module.FreefallData;
const MotionAction = module.MotionAction;
const MotionEvent = module.MotionEvent;
const AccelData = module.AccelData;
const GyroData = module.GyroData;
const SensorSample = module.SensorSample;
const Thresholds = module.Thresholds;
const accelFrom = module.accelFrom;
const gyroFrom = module.gyroFrom;

// ============================================================================
// Tests
// ============================================================================

test "AccelData magnitude" {
    const data = AccelData{ .x = 0, .y = 0, .z = 1.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), data.magnitude(), 0.001);

    const data2 = AccelData{ .x = 1.0, .y = 1.0, .z = 1.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 1.732), data2.magnitude(), 0.01);
}

test "MotionAction with gyro" {
    const Action = MotionAction(true);
    const shake = Action{ .shake = .{ .magnitude = 2.5, .duration_ms = 100 } };
    try std.testing.expectEqual(@as(f32, 2.5), shake.shake.magnitude);

    // Flip should be available with gyro
    const flip = Action{ .flip = .{ .from = .face_up, .to = .face_down } };
    try std.testing.expectEqual(Orientation.face_up, flip.flip.from);
}

test "MotionAction without gyro" {
    const Action = MotionAction(false);
    const shake = Action{ .shake = .{ .magnitude = 2.5, .duration_ms = 100 } };
    try std.testing.expectEqual(@as(f32, 2.5), shake.shake.magnitude);

    // Flip field exists but is void type
    _ = Action{ .flip = {} };
}

test "SensorSample with gyro" {
    const Sample = SensorSample(true);
    const s = Sample{
        .accel = .{ .x = 0, .y = 0, .z = 1.0 },
        .gyro = .{ .x = 0, .y = 0, .z = 0 },
        .timestamp_ms = 100,
    };
    try std.testing.expectEqual(@as(f32, 1.0), s.accel.z);
}

test "SensorSample without gyro" {
    const Sample = SensorSample(false);
    const s = Sample{
        .accel = .{ .x = 0, .y = 0, .z = 1.0 },
        .gyro = {},
        .timestamp_ms = 100,
    };
    try std.testing.expectEqual(@as(f32, 1.0), s.accel.z);
}
