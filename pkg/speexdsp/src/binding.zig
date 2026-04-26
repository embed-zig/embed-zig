const c = @cImport({
    @cInclude("config.h");
    @cInclude("speex/speex_echo.h");
    @cInclude("speex/speex_preprocess.h");
    @cInclude("speex/speex_resampler.h");
});

pub const spx_int16_t = c.spx_int16_t;
pub const spx_uint16_t = c.spx_uint16_t;
pub const spx_int32_t = c.spx_int32_t;
pub const spx_uint32_t = c.spx_uint32_t;

pub const SpeexEchoState = c.SpeexEchoState;
pub const SpeexPreprocessState = c.SpeexPreprocessState;
pub const SpeexResamplerState = c.SpeexResamplerState;

pub const SPEEX_ECHO_SET_SAMPLING_RATE = c.SPEEX_ECHO_SET_SAMPLING_RATE;
pub const SPEEX_ECHO_GET_SAMPLING_RATE = c.SPEEX_ECHO_GET_SAMPLING_RATE;

pub const SPEEX_PREPROCESS_SET_DENOISE = c.SPEEX_PREPROCESS_SET_DENOISE;
pub const SPEEX_PREPROCESS_SET_AGC = c.SPEEX_PREPROCESS_SET_AGC;
pub const SPEEX_PREPROCESS_SET_VAD = c.SPEEX_PREPROCESS_SET_VAD;
pub const SPEEX_PREPROCESS_SET_NOISE_SUPPRESS = c.SPEEX_PREPROCESS_SET_NOISE_SUPPRESS;
pub const SPEEX_PREPROCESS_SET_ECHO_SUPPRESS = c.SPEEX_PREPROCESS_SET_ECHO_SUPPRESS;
pub const SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE = c.SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE;
pub const SPEEX_PREPROCESS_SET_ECHO_STATE = c.SPEEX_PREPROCESS_SET_ECHO_STATE;

pub const SPEEX_RESAMPLER_QUALITY_MIN = c.SPEEX_RESAMPLER_QUALITY_MIN;
pub const SPEEX_RESAMPLER_QUALITY_MAX = c.SPEEX_RESAMPLER_QUALITY_MAX;
pub const SPEEX_RESAMPLER_QUALITY_DEFAULT = c.SPEEX_RESAMPLER_QUALITY_DEFAULT;
pub const SPEEX_RESAMPLER_QUALITY_VOIP = c.SPEEX_RESAMPLER_QUALITY_VOIP;
pub const SPEEX_RESAMPLER_QUALITY_DESKTOP = c.SPEEX_RESAMPLER_QUALITY_DESKTOP;

pub const RESAMPLER_ERR_SUCCESS = c.RESAMPLER_ERR_SUCCESS;
pub const RESAMPLER_ERR_ALLOC_FAILED = c.RESAMPLER_ERR_ALLOC_FAILED;
pub const RESAMPLER_ERR_BAD_STATE = c.RESAMPLER_ERR_BAD_STATE;
pub const RESAMPLER_ERR_INVALID_ARG = c.RESAMPLER_ERR_INVALID_ARG;
pub const RESAMPLER_ERR_PTR_OVERLAP = c.RESAMPLER_ERR_PTR_OVERLAP;
pub const RESAMPLER_ERR_OVERFLOW = c.RESAMPLER_ERR_OVERFLOW;
pub const RESAMPLER_ERR_MAX_ERROR = c.RESAMPLER_ERR_MAX_ERROR;

pub const speex_echo_state_init = c.speex_echo_state_init;
pub const speex_echo_state_destroy = c.speex_echo_state_destroy;
pub const speex_echo_cancellation = c.speex_echo_cancellation;
pub const speex_echo_capture = c.speex_echo_capture;
pub const speex_echo_playback = c.speex_echo_playback;
pub const speex_echo_state_reset = c.speex_echo_state_reset;
pub const speex_echo_ctl = c.speex_echo_ctl;

pub const speex_preprocess_state_init = c.speex_preprocess_state_init;
pub const speex_preprocess_state_destroy = c.speex_preprocess_state_destroy;
pub const speex_preprocess_run = c.speex_preprocess_run;
pub const speex_preprocess_estimate_update = c.speex_preprocess_estimate_update;
pub const speex_preprocess_ctl = c.speex_preprocess_ctl;

pub const speex_resampler_init = c.speex_resampler_init;
pub const speex_resampler_destroy = c.speex_resampler_destroy;
pub const speex_resampler_process_int = c.speex_resampler_process_int;
pub const speex_resampler_process_interleaved_int = c.speex_resampler_process_interleaved_int;
pub const speex_resampler_set_rate = c.speex_resampler_set_rate;
pub const speex_resampler_get_rate = c.speex_resampler_get_rate;
pub const speex_resampler_set_quality = c.speex_resampler_set_quality;
pub const speex_resampler_get_quality = c.speex_resampler_get_quality;
pub const speex_resampler_get_input_latency = c.speex_resampler_get_input_latency;
pub const speex_resampler_get_output_latency = c.speex_resampler_get_output_latency;
pub const speex_resampler_skip_zeros = c.speex_resampler_skip_zeros;
pub const speex_resampler_reset_mem = c.speex_resampler_reset_mem;
pub const speex_resampler_strerror = c.speex_resampler_strerror;

pub fn TestRunner(comptime lib: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const TestCase = struct {
        fn exportsCoreSymbols() !void {
            try lib.testing.expect(@sizeOf(spx_int16_t) == 2);
            try lib.testing.expect(@sizeOf(spx_int32_t) == 4);
            try lib.testing.expect(@sizeOf(*SpeexEchoState) > 0);
            try lib.testing.expect(@sizeOf(*SpeexPreprocessState) > 0);
            try lib.testing.expect(@sizeOf(*SpeexResamplerState) > 0);

            _ = speex_echo_state_init;
            _ = speex_preprocess_state_init;
            _ = speex_resampler_init;
            _ = speex_resampler_strerror;
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

            TestCase.exportsCoreSymbols() catch |err| {
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
