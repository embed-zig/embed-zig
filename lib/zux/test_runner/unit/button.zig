const testing_api = @import("testing");

const Button = @import("../../button/Button.zig");
const GroupedButton = @import("../../button/GroupedButton.zig");
const GestureDetector = @import("../../button/GestureDetector.zig");

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
            t.run("Button", Button.TestRunner(lib));
            t.run("GroupedButton", GroupedButton.TestRunner(lib));
            t.run("GestureDetector", GestureDetector.TestRunner(lib));
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
