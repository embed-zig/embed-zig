const glib = @import("glib");
const ledstrip = @import("../ledstrip.zig");
const single_button = @import("../single_button.zig");

pub fn make(comptime std: type) glib.testing.TestRunner {
    const testing_api = glib.testing;

    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("ledstrip", ledstrip.TestRunner(std));
            t.run("single_button", single_button.TestRunner(std));
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
