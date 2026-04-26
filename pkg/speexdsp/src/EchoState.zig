const glib = @import("glib");
const binding = @import("binding.zig");
const error_mod = @import("error.zig");
const types = @import("types.zig");

const Self = @This();
const ValidationError = error{InvalidArgument};
const ControlError = ValidationError || error_mod.ControlError;

state: *binding.SpeexEchoState,
frame_size: usize,

pub fn init(frame_size: usize, filter_length: usize) error_mod.InitError!Self {
    if (frame_size == 0 or filter_length == 0) return error.InvalidArgument;
    if (!fitsCInt(frame_size) or !fitsCInt(filter_length)) return error.InvalidArgument;

    const state = binding.speex_echo_state_init(
        @intCast(frame_size),
        @intCast(filter_length),
    ) orelse return error.OutOfMemory;

    return .{
        .state = state,
        .frame_size = frame_size,
    };
}

pub fn deinit(self: *Self) void {
    binding.speex_echo_state_destroy(self.state);
    self.* = undefined;
}

pub fn cancellation(self: Self, rec: []const types.Sample, play: []const types.Sample, out: []types.Sample) ValidationError!void {
    try validateFrame(self.frame_size, rec.len);
    try validateFrame(self.frame_size, play.len);
    try validateFrame(self.frame_size, out.len);

    binding.speex_echo_cancellation(self.state, rec.ptr, play.ptr, out.ptr);
}

pub fn capture(self: Self, rec: []const types.Sample, out: []types.Sample) ValidationError!void {
    try validateFrame(self.frame_size, rec.len);
    try validateFrame(self.frame_size, out.len);

    binding.speex_echo_capture(self.state, rec.ptr, out.ptr);
}

pub fn playback(self: Self, play: []const types.Sample) ValidationError!void {
    try validateFrame(self.frame_size, play.len);
    binding.speex_echo_playback(self.state, play.ptr);
}

pub fn reset(self: Self) void {
    binding.speex_echo_state_reset(self.state);
}

pub fn setSamplingRate(self: Self, rate: types.SampleRate) ControlError!void {
    if (rate == 0 or !fitsCInt(rate)) return error.InvalidArgument;
    var c_rate: c_int = @intCast(rate);
    try error_mod.fromCtlStatus(binding.speex_echo_ctl(
        self.state,
        binding.SPEEX_ECHO_SET_SAMPLING_RATE,
        @ptrCast(&c_rate),
    ));
}

pub fn samplingRate(self: Self) ControlError!types.SampleRate {
    var c_rate: c_int = 0;
    try error_mod.fromCtlStatus(binding.speex_echo_ctl(
        self.state,
        binding.SPEEX_ECHO_GET_SAMPLING_RATE,
        @ptrCast(&c_rate),
    ));
    if (c_rate <= 0) return error.InvalidArgument;
    return @intCast(c_rate);
}

pub fn frameSize(self: Self) usize {
    return self.frame_size;
}

pub fn raw(self: Self) *binding.SpeexEchoState {
    return self.state;
}

fn validateFrame(expected: usize, actual: usize) ValidationError!void {
    if (actual != expected) return error.InvalidArgument;
}

fn fitsCInt(value: anytype) bool {
    const max = (@as(u64, 1) << (@bitSizeOf(c_int) - 1)) - 1;
    return @as(u64, @intCast(value)) <= max;
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn rejectsInvalidInitArguments() !void {
            try grt.std.testing.expectError(error.InvalidArgument, Self.init(0, 160));
            try grt.std.testing.expectError(error.InvalidArgument, Self.init(160, 0));
        }

        fn rejectsInvalidFrameLengths() !void {
            var echo = try Self.init(160, 1600);
            defer echo.deinit();

            var rec = [_]types.Sample{0} ** 160;
            var play = [_]types.Sample{0} ** 160;
            var out = [_]types.Sample{0} ** 160;

            try grt.std.testing.expectError(error.InvalidArgument, echo.cancellation(rec[0..159], play[0..], out[0..]));
            try grt.std.testing.expectError(error.InvalidArgument, echo.cancellation(rec[0..], play[0..159], out[0..]));
            try grt.std.testing.expectError(error.InvalidArgument, echo.cancellation(rec[0..], play[0..], out[0..159]));
            try grt.std.testing.expectError(error.InvalidArgument, echo.capture(rec[0..159], out[0..]));
            try grt.std.testing.expectError(error.InvalidArgument, echo.capture(rec[0..], out[0..159]));
            try grt.std.testing.expectError(error.InvalidArgument, echo.playback(play[0..159]));
        }

        fn rejectsInvalidSamplingRate() !void {
            var echo = try Self.init(160, 1600);
            defer echo.deinit();

            try grt.std.testing.expectError(error.InvalidArgument, echo.setSamplingRate(0));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.rejectsInvalidInitArguments() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.rejectsInvalidFrameLengths() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.rejectsInvalidSamplingRate() catch |err| {
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
