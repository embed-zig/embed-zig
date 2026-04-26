const build_options = @import("build_options");
const testing_api = @import("testing");
const PortAudioMod = @import("../../src/PortAudio.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            runLive(lib) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }

        fn runLive(comptime L: type) !void {
            if (!build_options.portaudio_live) return;

            const testing = L.testing;

            var pa = try PortAudioMod.init();
            defer pa.deinit() catch @panic("portaudio terminate failed");

            try testing.expect(PortAudioMod.version() > 0);
            try testing.expect((try pa.hostApiCount()) > 0);
            try testing.expect((try pa.deviceCount()) >= 0);

            const host_api = try pa.defaultHostApi();
            try testing.expect(host_api.name()[0] != 0);

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
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
