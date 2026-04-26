const testing_api = @import("testing");
const binding = @import("../src/binding.zig");
const types = @import("../src/types.zig");
const error_mod = @import("../src/error.zig");
const echo_state = @import("../src/EchoState.zig");
const preprocess_state = @import("../src/PreprocessState.zig");
const resampler = @import("../src/Resampler.zig");

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
            t.run("binding", binding.TestRunner(lib));
            t.run("types", types.TestRunner(lib));
            t.run("error", error_mod.TestRunner(lib));
            t.run("EchoState", echo_state.TestRunner(lib));
            t.run("PreprocessState", preprocess_state.TestRunner(lib));
            t.run("Resampler", resampler.TestRunner(lib));
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
