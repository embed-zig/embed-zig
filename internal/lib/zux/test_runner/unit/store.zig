const testing_api = @import("testing");

const Builder = @import("../../store/Builder.zig");
const Object = @import("../../store/Object.zig");
const Reducer = @import("../../store/Reducer.zig");
const runtime_tests = @import("../../store/runtime_tests.zig");
const State = @import("../../store/State.zig");
const Stores = @import("../../store/Stores.zig");
const Subscriber = @import("../../store/Subscriber.zig");

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
            t.run("Builder", Builder.TestRunner(lib));
            t.run("Reducer", Reducer.TestRunner(lib));
            t.run("runtime_tests", runtime_tests.TestRunner(lib));
            t.run("State", State.TestRunner(lib));
            t.run("Stores", Stores.TestRunner(lib));
            t.run("Object", Object.TestRunner(lib));
            t.run("Subscriber", Subscriber.TestRunner(lib));
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
