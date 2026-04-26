const glib = @import("glib");
const binding = @import("binding.zig");

pub const Error = error{
    BadArg,
    BufferTooSmall,
    InternalError,
    InvalidPacket,
    Unimplemented,
    InvalidState,
    AllocFail,
    Unknown,
};

pub const Application = enum(c_int) {
    voip = binding.OPUS_APPLICATION_VOIP,
    audio = binding.OPUS_APPLICATION_AUDIO,
    restricted_lowdelay = binding.OPUS_APPLICATION_RESTRICTED_LOWDELAY,
};

pub const Signal = enum(c_int) {
    auto = binding.OPUS_AUTO,
    voice = binding.OPUS_SIGNAL_VOICE,
    music = binding.OPUS_SIGNAL_MUSIC,
};

pub const Bandwidth = enum(c_int) {
    auto = binding.OPUS_AUTO,
    narrowband = binding.OPUS_BANDWIDTH_NARROWBAND,
    mediumband = binding.OPUS_BANDWIDTH_MEDIUMBAND,
    wideband = binding.OPUS_BANDWIDTH_WIDEBAND,
    superwideband = binding.OPUS_BANDWIDTH_SUPERWIDEBAND,
    fullband = binding.OPUS_BANDWIDTH_FULLBAND,
};

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            grt.std.testing.expectEqual(@as(c_int, binding.OPUS_APPLICATION_VOIP), @intFromEnum(Application.voip)) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            grt.std.testing.expectEqual(@as(c_int, binding.OPUS_APPLICATION_AUDIO), @intFromEnum(Application.audio)) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            grt.std.testing.expectEqual(@as(c_int, binding.OPUS_APPLICATION_RESTRICTED_LOWDELAY), @intFromEnum(Application.restricted_lowdelay)) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            grt.std.testing.expectEqual(@as(c_int, binding.OPUS_AUTO), @intFromEnum(Signal.auto)) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            grt.std.testing.expectEqual(@as(c_int, binding.OPUS_SIGNAL_VOICE), @intFromEnum(Signal.voice)) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            grt.std.testing.expectEqual(@as(c_int, binding.OPUS_SIGNAL_MUSIC), @intFromEnum(Signal.music)) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            grt.std.testing.expectEqual(@as(c_int, binding.OPUS_AUTO), @intFromEnum(Bandwidth.auto)) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            grt.std.testing.expectEqual(@as(c_int, binding.OPUS_BANDWIDTH_NARROWBAND), @intFromEnum(Bandwidth.narrowband)) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            grt.std.testing.expectEqual(@as(c_int, binding.OPUS_BANDWIDTH_MEDIUMBAND), @intFromEnum(Bandwidth.mediumband)) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            grt.std.testing.expectEqual(@as(c_int, binding.OPUS_BANDWIDTH_WIDEBAND), @intFromEnum(Bandwidth.wideband)) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            grt.std.testing.expectEqual(@as(c_int, binding.OPUS_BANDWIDTH_SUPERWIDEBAND), @intFromEnum(Bandwidth.superwideband)) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            grt.std.testing.expectEqual(@as(c_int, binding.OPUS_BANDWIDTH_FULLBAND), @intFromEnum(Bandwidth.fullband)) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
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
