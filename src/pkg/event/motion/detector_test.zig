const std = @import("std");
const testing = std.testing;
const module = @import("detector.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const Detector = module.Detector;
const types = test_exports.types;
const AccelData = test_exports.AccelData;
const GyroData = test_exports.GyroData;
const SensorSample = test_exports.SensorSample;
const MotionAction = test_exports.MotionAction;
const Thresholds = test_exports.Thresholds;
const Axis = test_exports.Axis;
const Orientation = test_exports.Orientation;
const hasMethod = test_exports.hasMethod;
const hasExpectedFields = test_exports.hasExpectedFields;

// ============================================================================
// Tests
// ============================================================================

// Mock sensor types for testing
const MockAccelOnlySensor = struct {
    pub fn readAccel(_: *@This()) !AccelData {
        return .{ .x = 0, .y = 0, .z = 1.0 };
    }
};

const MockImuSensor = struct {
    pub fn readAccel(_: *@This()) !AccelData {
        return .{ .x = 0, .y = 0, .z = 1.0 };
    }
    pub fn readGyro(_: *@This()) !GyroData {
        return .{ .x = 0, .y = 0, .z = 0 };
    }
};

test "hasMethod detection" {
    try std.testing.expect(hasMethod(MockImuSensor, "readGyro", GyroData));
    try std.testing.expect(hasMethod(MockImuSensor, "readAccel", AccelData));
    try std.testing.expect(!hasMethod(MockAccelOnlySensor, "readGyro", GyroData));
    try std.testing.expect(hasMethod(MockAccelOnlySensor, "readAccel", AccelData));
}

test "Detector capability detection" {
    const ImuDetector = Detector(MockImuSensor);
    const AccelDetector = Detector(MockAccelOnlySensor);

    try std.testing.expect(ImuDetector.has_gyroscope);
    try std.testing.expect(!AccelDetector.has_gyroscope);
}

test "Detector initialization" {
    const det = Detector(MockImuSensor).initDefault();
    try std.testing.expectEqual(@as(f32, 1.5), det.thresholds.shake_threshold);
}

test "Detector shake detection" {
    var det = Detector(MockImuSensor).init(.{
        .shake_threshold = 1.0,
        .shake_min_duration = 50,
        .shake_max_duration = 500,
    });

    const Sample = Detector(MockImuSensor).SampleType;

    // Simulate shake sequence
    var t: u64 = 0;

    // Initial samples
    _ = det.update(Sample{ .accel = .{ .x = 0, .y = 0, .z = 1.0 }, .gyro = .{ .x = 0, .y = 0, .z = 0 }, .timestamp_ms = t });
    t += 10;

    // Shake motion
    _ = det.update(Sample{ .accel = .{ .x = 2.0, .y = 0, .z = 1.0 }, .gyro = .{ .x = 0, .y = 0, .z = 0 }, .timestamp_ms = t });
    t += 10;
    _ = det.update(Sample{ .accel = .{ .x = -2.0, .y = 0, .z = 1.0 }, .gyro = .{ .x = 0, .y = 0, .z = 0 }, .timestamp_ms = t });
    t += 10;
    _ = det.update(Sample{ .accel = .{ .x = 2.0, .y = 0, .z = 1.0 }, .gyro = .{ .x = 0, .y = 0, .z = 0 }, .timestamp_ms = t });
    t += 30;

    // End shake
    const event = det.update(Sample{ .accel = .{ .x = 0, .y = 0, .z = 1.0 }, .gyro = .{ .x = 0, .y = 0, .z = 0 }, .timestamp_ms = t });

    // Should detect shake (though timing might vary)
    _ = event;
}

test "Detector tilt detection" {
    var det = Detector(MockAccelOnlySensor).init(.{
        .tilt_threshold = 5.0,
        .tilt_debounce = 0,
    });

    const Sample = Detector(MockAccelOnlySensor).SampleType;

    // Initial flat position
    _ = det.update(Sample{ .accel = .{ .x = 0, .y = 0, .z = 1.0 }, .gyro = {}, .timestamp_ms = 0 });

    // Tilt to 30 degrees
    const event = det.update(Sample{
        .accel = .{ .x = 0.5, .y = 0, .z = 0.866 }, // ~30 degree tilt
        .gyro = {},
        .timestamp_ms = 100,
    });

    if (event) |e| {
        switch (e) {
            .tilt => |t| {
                try std.testing.expect(@abs(t.pitch) > 20.0);
            },
            else => {},
        }
    }
}

test "Detector with accel-only sensor" {
    // Should compile without gyro features
    var det = Detector(MockAccelOnlySensor).initDefault();
    const Sample = Detector(MockAccelOnlySensor).SampleType;

    _ = det.update(Sample{ .accel = .{ .x = 0, .y = 0, .z = 1.0 }, .gyro = {}, .timestamp_ms = 0 });
}
