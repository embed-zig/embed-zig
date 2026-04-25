const testing_api = @import("../TestRunner.zig");

const TMod = @import("../T.zig");
const TestingAllocatorMod = @import("../TestingAllocator.zig");
const TestRunnerMod = @import("../TestRunner.zig");

pub fn make(comptime lib: type) testing_api {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *TMod, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("T", TMod.TestRunner(lib));
            t.run("TestingAllocator", TestingAllocatorMod.TestRunner(lib));
            t.run("TestRunner", TestRunnerMod.TestRunner(lib));
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
    return testing_api.make(Runner).new(&Holder.runner);
}
