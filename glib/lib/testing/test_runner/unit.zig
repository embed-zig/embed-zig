const testing_api = @import("../TestRunner.zig");

const TMod = @import("../T.zig");
const TestingAllocatorMod = @import("../TestingAllocator.zig");
const TestRunnerMod = @import("../TestRunner.zig");

pub fn make(comptime std: type, comptime time: type) testing_api {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *TMod, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("T", TMod.TestRunner(std, time));
            t.run("TestingAllocator", TestingAllocatorMod.TestRunner(std));
            t.run("TestRunner", TestRunnerMod.TestRunner(std, time));
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
    return testing_api.make(Runner).new(&Holder.runner);
}
