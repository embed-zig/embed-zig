const testing_api = @import("testing");

const core_wlan = @import("../../core_wlan.zig");
const CWApUnsupported = @import("../src/CWApUnsupported.zig");
const CWSta = @import("../src/CWSta.zig");

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("core_wlan", core_wlan.TestRunner(lib));
            t.run("src/CWSta", CWSta.TestRunner(lib));
            t.run("src/CWApUnsupported", CWApUnsupported.TestRunner(lib));
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
