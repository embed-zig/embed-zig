const glib = @import("glib");
const build_options = @import("build_options");
const PortAudioMod = @import("../../src/PortAudio.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            runLive() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }

        fn runLive() !void {
            if (!build_options.portaudio_live) return;

            var pa = try PortAudioMod.init();
            defer pa.deinit() catch @panic("portaudio terminate failed");

            try grt.std.testing.expect(PortAudioMod.version() > 0);
            try grt.std.testing.expect((try pa.hostApiCount()) > 0);
            try grt.std.testing.expect((try pa.deviceCount()) >= 0);

            const host_api = try pa.defaultHostApi();
            try grt.std.testing.expect(host_api.name()[0] != 0);

            _ = try pa.defaultInputDevice();
            _ = try pa.defaultOutputDevice();

            var pa2 = try PortAudioMod.init();
            try pa2.terminate();
            try pa2.deinit();
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
