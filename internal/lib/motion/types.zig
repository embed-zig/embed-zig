const types = @This();
const testing_api = @import("testing");

pub const AccelData = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn magnitude(self: AccelData) f32 {
        return @sqrt(self.x * self.x + self.y * self.y + self.z * self.z);
    }
};

pub const GyroData = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn magnitude(self: GyroData) f32 {
        return @sqrt(self.x * self.x + self.y * self.y + self.z * self.z);
    }
};

pub const Sample = struct {
    accel: AccelData,
    timestamp_ms: u64,
};

pub const GyroSample = struct {
    gyro: GyroData,
    timestamp_ms: u64,
};

pub const ShakeData = struct {
    magnitude: f32,
    duration_ms: u32,
};

pub const TiltData = struct {
    roll: f32,
    pitch: f32,
};

pub const Face = enum {
    up,
    down,
};

pub const FlipData = struct {
    from: Face,
    to: Face,
};

pub const FreeFallData = struct {
    duration_ms: u32,
    min_magnitude: f32,
};

pub const Action = union(enum) {
    shake: ShakeData,
    tilt: TiltData,
    flip: FlipData,
    free_fall: FreeFallData,
};

pub const Thresholds = struct {
    shake_threshold_g: f32 = 1.5,
    shake_min_duration_ms: u32 = 100,
    shake_max_duration_ms: u32 = 1000,

    tilt_threshold_deg: f32 = 10.0,
    tilt_debounce_ms: u32 = 200,

    free_fall_threshold_g: f32 = 0.25,
    free_fall_min_duration_ms: u32 = 120,

    flip_gyro_threshold_dps: f32 = 120.0,
    flip_recent_turn_ms: u32 = 400,
    flip_debounce_ms: u32 = 300,

    pub const default = Thresholds{};

    pub const sensitive = Thresholds{
        .shake_threshold_g = 1.0,
        .tilt_threshold_deg = 5.0,
        .free_fall_threshold_g = 0.35,
        .free_fall_min_duration_ms = 80,
        .flip_gyro_threshold_dps = 90.0,
        .flip_recent_turn_ms = 500,
        .flip_debounce_ms = 200,
    };

    pub const insensitive = Thresholds{
        .shake_threshold_g = 2.5,
        .tilt_threshold_deg = 20.0,
        .free_fall_threshold_g = 0.15,
        .free_fall_min_duration_ms = 180,
        .flip_gyro_threshold_dps = 180.0,
        .flip_recent_turn_ms = 250,
        .flip_debounce_ms = 450,
    };
};

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn testAccelMagnitude() !void {
            const testing = lib.testing;

            const unit: AccelData = .{ .x = 0, .y = 0, .z = 1.0 };
            try testing.expectEqual(@as(f32, 1.0), unit.magnitude());

            const diagonal: AccelData = .{ .x = 1.0, .y = 1.0, .z = 1.0 };
            try expectApproxEqual(diagonal.magnitude(), 1.7320508, 0.0001);
        }

        fn testGyroMagnitude() !void {
            const testing = lib.testing;

            const stationary: GyroData = .{ .x = 0, .y = 0, .z = 0 };
            try testing.expectEqual(@as(f32, 0.0), stationary.magnitude());

            const turn: GyroData = .{ .x = 3.0, .y = 4.0, .z = 12.0 };
            try expectApproxEqual(turn.magnitude(), 13.0, 0.0001);
        }

        fn testThresholdPresets() !void {
            const testing = lib.testing;

            try testing.expect(Thresholds.sensitive.shake_threshold_g < Thresholds.default.shake_threshold_g);
            try testing.expect(Thresholds.insensitive.shake_threshold_g > Thresholds.default.shake_threshold_g);
            try testing.expect(Thresholds.sensitive.tilt_threshold_deg < Thresholds.default.tilt_threshold_deg);
            try testing.expect(Thresholds.insensitive.tilt_threshold_deg > Thresholds.default.tilt_threshold_deg);
            try testing.expect(Thresholds.sensitive.free_fall_threshold_g > Thresholds.default.free_fall_threshold_g);
            try testing.expect(Thresholds.insensitive.free_fall_threshold_g < Thresholds.default.free_fall_threshold_g);
            try testing.expect(Thresholds.sensitive.flip_gyro_threshold_dps < Thresholds.default.flip_gyro_threshold_dps);
            try testing.expect(Thresholds.insensitive.flip_gyro_threshold_dps > Thresholds.default.flip_gyro_threshold_dps);
        }

        fn expectApproxEqual(actual: f32, expected: f32, tolerance: f32) !void {
            const testing = lib.testing;
            try testing.expect(@abs(actual - expected) <= tolerance);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.testAccelMagnitude() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testGyroMagnitude() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testThresholdPresets() catch |err| {
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
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
