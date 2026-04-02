//! portaudio test runner — host metadata and lifecycle smoke checks.

const embed = @import("embed");
const testing_api = @import("testing");
const PortAudioMod = @import("../src/PortAudio.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            runImpl(lib) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}

pub fn run(comptime lib: type) !void {
    try runImpl(lib);
}

fn runImpl(comptime lib: type) !void {
    const testing = lib.testing;
    var pa = try PortAudioMod.init();
    defer pa.deinit() catch @panic("portaudio terminate failed");

    try testing.expect(PortAudioMod.version() > 0);
    try testing.expect((try pa.hostApiCount()) > 0);
    try testing.expect((try pa.deviceCount()) >= 0);
    const host_api = try pa.defaultHostApi();
    try testing.expect(host_api.name()[0] != 0);
    _ = try pa.defaultInputDevice();
    _ = try pa.defaultOutputDevice();
}
