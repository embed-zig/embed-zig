const testing_api = @import("testing");

const component_wifi = @import("../../component/wifi.zig");

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
            t.run("component.wifi", component_wifi.TestRunner(lib));
            t.run("component.wifi.EventHook", component_wifi.EventHook.TestRunner(lib));
            t.run("component.wifi.StaReducer", component_wifi.StaReducer.TestRunner(lib));
            t.run("component.wifi.ApReducer", component_wifi.ApReducer.TestRunner(lib));
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
