const glib = @import("glib");

const component_wifi = @import("../../component/wifi.zig");

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
            t.run("component.wifi", component_wifi.TestRunner(grt));
            t.run("component.wifi.EventHook", component_wifi.EventHook.TestRunner(grt));
            t.run("component.wifi.StaReducer", component_wifi.StaReducer.TestRunner(grt));
            t.run("component.wifi.ApReducer", component_wifi.ApReducer.TestRunner(grt));
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
