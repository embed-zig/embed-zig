const testing_api = @import("testing");

const component_bt = @import("../../component/bt.zig");

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
            t.run("component.bt", component_bt.TestRunner(lib));
            t.run("component.bt.EventHook", component_bt.EventHook.TestRunner(lib));
            t.run("component.bt.CentralReducer", component_bt.CentralReducer.TestRunner(lib));
            t.run("component.bt.PeriphReducer", component_bt.PeriphReducer.TestRunner(lib));
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
