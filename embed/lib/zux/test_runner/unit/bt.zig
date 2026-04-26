const glib = @import("glib");

const component_bt = @import("../../component/bt.zig");

pub fn make(comptime lib: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: lib.mem.Allocator) bool {
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
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
