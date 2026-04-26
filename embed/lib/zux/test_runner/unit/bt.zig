const glib = @import("glib");

const component_bt = @import("../../component/bt.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("component.bt", component_bt.TestRunner(grt));
            t.run("component.bt.EventHook", component_bt.EventHook.TestRunner(grt));
            t.run("component.bt.CentralReducer", component_bt.CentralReducer.TestRunner(grt));
            t.run("component.bt.PeriphReducer", component_bt.PeriphReducer.TestRunner(grt));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
