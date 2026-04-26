const binding = @import("binding.zig");

pub const Sample = binding.spx_int16_t;
pub const SampleRate = u32;
pub const ChannelCount = u32;
pub const Quality = c_int;

pub const resampler_quality_min: Quality = binding.SPEEX_RESAMPLER_QUALITY_MIN;
pub const resampler_quality_max: Quality = binding.SPEEX_RESAMPLER_QUALITY_MAX;
pub const resampler_quality_default: Quality = binding.SPEEX_RESAMPLER_QUALITY_DEFAULT;
pub const resampler_quality_voip: Quality = binding.SPEEX_RESAMPLER_QUALITY_VOIP;
pub const resampler_quality_desktop: Quality = binding.SPEEX_RESAMPLER_QUALITY_DESKTOP;

pub const ProcessResult = struct {
    input_consumed: usize,
    output_produced: usize,
};

pub const InterleavedProcessResult = struct {
    input_frames_consumed: usize,
    output_frames_produced: usize,
};

pub fn TestRunner(comptime lib: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const TestCase = struct {
        fn exposesExpectedAudioPrimitives() !void {
            try lib.testing.expectEqual(@as(usize, 2), @sizeOf(Sample));
            try lib.testing.expect(resampler_quality_min <= resampler_quality_default);
            try lib.testing.expect(resampler_quality_default <= resampler_quality_max);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.exposesExpectedAudioPrimitives() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
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
