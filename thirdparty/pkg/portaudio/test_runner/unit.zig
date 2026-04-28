const glib = @import("glib");
const binding = @import("../src/binding.zig");
const device = @import("../src/Device.zig");
const error_mod = @import("../src/error.zig");
const host_api = @import("../src/HostApi.zig");
const port_audio = @import("../src/PortAudio.zig");
const stream = @import("../src/Stream.zig");
const stream_parameters = @import("../src/StreamParameters.zig");
const types = @import("../src/types.zig");

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
            t.run("device", device.TestRunner(grt));
            t.run("error", error_mod.TestRunner(grt));
            t.run("host_api", host_api.TestRunner(grt));
            t.run("port_audio", port_audio.TestRunner(grt));
            t.run("stream", stream.TestRunner(grt));
            t.run("stream_parameters", stream_parameters.TestRunner(grt));
            t.run("types", types.TestRunner(grt));
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
