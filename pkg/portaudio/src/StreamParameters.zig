const binding = @import("binding.zig");
const types = @import("types.zig");

const Self = @This();

device: types.DeviceIndex,
channel_count: u16,
sample_format: types.SampleFormat,
suggested_latency: f64,
host_api_specific_stream_info: ?*anyopaque = null,

pub fn toC(self: Self) binding.PaStreamParameters {
    return .{
        .device = self.device,
        .channelCount = self.channel_count,
        .sampleFormat = types.toPaSampleFormat(self.sample_format),
        .suggestedLatency = self.suggested_latency,
        .hostApiSpecificStreamInfo = self.host_api_specific_stream_info,
    };
}

pub fn frameSampleCount(self: Self, frames: usize) usize {
    return frames * self.channel_count;
}

pub fn TestRunner(comptime lib: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            convertsToPortaudioStruct(lib) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            frameSampleCountTracksChannels(lib) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }

        fn convertsToPortaudioStruct(comptime L: type) !void {
            const testing = L.testing;

            const params: Self = .{
                .device = 3,
                .channel_count = 2,
                .sample_format = .int16,
                .suggested_latency = 0.05,
            };
            const c_params = params.toC();

            try testing.expectEqual(@as(types.DeviceIndex, 3), c_params.device);
            try testing.expectEqual(@as(c_int, 2), c_params.channelCount);
            try testing.expectEqual(binding.paInt16, c_params.sampleFormat);
            try testing.expectEqual(@as(f64, 0.05), c_params.suggestedLatency);
            try testing.expectEqual(@as(?*anyopaque, null), c_params.hostApiSpecificStreamInfo);
        }

        fn frameSampleCountTracksChannels(comptime L: type) !void {
            const testing = L.testing;

            const params: Self = .{
                .device = 1,
                .channel_count = 2,
                .sample_format = .int16,
                .suggested_latency = 0.01,
            };

            try testing.expectEqual(@as(usize, 8), params.frameSampleCount(4));
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
