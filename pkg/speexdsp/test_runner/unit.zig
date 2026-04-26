const glib = @import("glib");
const binding = @import("../src/binding.zig");
const types = @import("../src/types.zig");
const error_mod = @import("../src/error.zig");
const echo_state = @import("../src/EchoState.zig");
const preprocess_state = @import("../src/PreprocessState.zig");
const resampler = @import("../src/Resampler.zig");

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
            t.run("binding", binding.TestRunner(grt));
            t.run("types", types.TestRunner(grt));
            t.run("error", error_mod.TestRunner(grt));
            t.run("EchoState", echo_state.TestRunner(grt));
            t.run("PreprocessState", preprocess_state.TestRunner(grt));
            t.run("Resampler", resampler.TestRunner(grt));
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
