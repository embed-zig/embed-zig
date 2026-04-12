const testing_api = @import("testing");

const ui = @import("../../component/ui.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("ui.flow.Reducer", ui.flow.Reducer.TestRunner(lib));
            t.run("ui.overlay.Reducer", ui.overlay.Reducer.TestRunner(lib));
            t.run("ui.selection.Reducer", ui.selection.Reducer.TestRunner(lib));
            t.run("ui.route.Reducer", ui.route.Reducer.TestRunner(lib));
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
