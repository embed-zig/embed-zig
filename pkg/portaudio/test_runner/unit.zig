const testing_api = @import("testing");
const binding = @import("../src/binding.zig");
const device = @import("../src/Device.zig");
const error_mod = @import("../src/error.zig");
const host_api = @import("../src/HostApi.zig");
const port_audio = @import("../src/PortAudio.zig");
const stream = @import("../src/Stream.zig");
const stream_parameters = @import("../src/StreamParameters.zig");
const types = @import("../src/types.zig");

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
            t.run("device", device.TestRunner(lib));
            t.run("error", error_mod.TestRunner(lib));
            t.run("host_api", host_api.TestRunner(lib));
            t.run("port_audio", port_audio.TestRunner(lib));
            t.run("stream", stream.TestRunner(lib));
            t.run("stream_parameters", stream_parameters.TestRunner(lib));
            t.run("types", types.TestRunner(lib));
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
