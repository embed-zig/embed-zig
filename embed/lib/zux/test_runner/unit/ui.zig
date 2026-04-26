const glib = @import("glib");

const ui = @import("../../component/ui.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("ui.flow.Reducer", ui.flow.Reducer.TestRunner(grt));
            t.run("ui.overlay.Reducer", ui.overlay.Reducer.TestRunner(grt));
            t.run("ui.selection.Reducer", ui.selection.Reducer.TestRunner(grt));
            t.run("ui.route.Reducer", ui.route.Reducer.TestRunner(grt));
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
