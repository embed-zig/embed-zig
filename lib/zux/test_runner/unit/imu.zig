const testing_api = @import("testing");

const Accel = @import("../../imu/Accel.zig");
const Gyro = @import("../../imu/Gyro.zig");
const MotionDetector = @import("../../imu/MotionDetector.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("Accel", Accel.TestRunner(lib));
            t.run("Gyro", Gyro.TestRunner(lib));
            t.run("MotionDetector", MotionDetector.TestRunner(lib));
            return t.wait();
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
