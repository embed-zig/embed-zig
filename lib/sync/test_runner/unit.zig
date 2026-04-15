const testing_api = @import("testing");

const Channel = @import("../Channel.zig");
const Pool = @import("../Pool.zig");
const Racer = @import("../Racer.zig");
const Timer = @import("../Timer.zig");

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
            t.run("Channel", Channel.TestRunner(lib));
            t.run("Pool", Pool.TestRunner(lib));
            t.run("Racer", Racer.TestRunner(lib));
            t.run("Timer", Timer.TestRunner(lib));
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
