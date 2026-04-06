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

pub const Sample = struct {
    accel: AccelData,
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

pub const Action = union(enum) {
    shake: ShakeData,
    tilt: TiltData,
};

pub const Thresholds = struct {
    shake_threshold_g: f32 = 1.5,
    shake_min_duration_ms: u32 = 100,
    shake_max_duration_ms: u32 = 1000,

    tilt_threshold_deg: f32 = 10.0,
    tilt_debounce_ms: u32 = 200,

    pub const default = Thresholds{};

    pub const sensitive = Thresholds{
        .shake_threshold_g = 1.0,
        .tilt_threshold_deg = 5.0,
    };

    pub const insensitive = Thresholds{
        .shake_threshold_g = 2.5,
        .tilt_threshold_deg = 20.0,
    };
};

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn testAccelMagnitude() !void {
            const std = @import("std");

            const unit: AccelData = .{ .x = 0, .y = 0, .z = 1.0 };
            try std.testing.expectEqual(@as(f32, 1.0), unit.magnitude());

            const diagonal: AccelData = .{ .x = 1.0, .y = 1.0, .z = 1.0 };
            try std.testing.expectApproxEqAbs(@as(f32, 1.7320508), diagonal.magnitude(), 0.0001);
        }

        fn testThresholdPresets() !void {
            const std = @import("std");

            try std.testing.expect(Thresholds.sensitive.shake_threshold_g < Thresholds.default.shake_threshold_g);
            try std.testing.expect(Thresholds.insensitive.shake_threshold_g > Thresholds.default.shake_threshold_g);
            try std.testing.expect(Thresholds.sensitive.tilt_threshold_deg < Thresholds.default.tilt_threshold_deg);
            try std.testing.expect(Thresholds.insensitive.tilt_threshold_deg > Thresholds.default.tilt_threshold_deg);
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
