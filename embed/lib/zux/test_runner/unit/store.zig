const glib = @import("glib");

const Builder = @import("../../store/Builder.zig");
const Object = @import("../../store/Object.zig");
const Reducer = @import("../../store/Reducer.zig");
const runtime_tests = @import("../../store/runtime_tests.zig");
const State = @import("../../store/State.zig");
const Stores = @import("../../store/Stores.zig");
const Subscriber = @import("../../store/Subscriber.zig");

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
            t.run("Builder", Builder.TestRunner(grt));
            t.run("Reducer", Reducer.TestRunner(grt));
            t.run("runtime_tests", runtime_tests.TestRunner(grt));
            t.run("State", State.TestRunner(grt));
            t.run("Stores", Stores.TestRunner(grt));
            t.run("Object", Object.TestRunner(grt));
            t.run("Subscriber", Subscriber.TestRunner(grt));
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
