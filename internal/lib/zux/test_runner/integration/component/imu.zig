const testing_api = @import("testing");

const flip = @import("imu/flip.zig");
const flip_then_shake = @import("imu/flip_then_shake.zig");
const free_fall = @import("imu/free_fall.zig");
const shake = @import("imu/shake.zig");
const tilt = @import("imu/tilt.zig");

pub fn make(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("shake", shake.make(lib, Channel));
            t.run("tilt", tilt.make(lib, Channel));
            t.run("flip", flip.make(lib, Channel));
            t.run("free_fall", free_fall.make(lib, Channel));
            t.run("flip_then_shake", flip_then_shake.make(lib, Channel));
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
