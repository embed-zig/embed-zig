const builtin = @import("builtin");
const testing_api = @import("testing");

const Channel = @import("../Channel.zig");
const Pool = @import("../Pool.zig");
const Racer = @import("../Racer.zig");
const Timer = @import("../Timer.zig");
const WakeFd = @import("../WakeFd.zig");

pub fn make(comptime std: type, comptime time: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("Channel", Channel.TestRunner(std));
            t.run("Pool", Pool.TestRunner(std));
            t.run("Racer", Racer.TestRunner(std, time));
            t.run("Timer", Timer.TestRunner(std, time));
            if (builtin.target.os.tag != .windows) {
                t.run("WakeFd", WakeFd.TestRunner(std, time));
            }
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
