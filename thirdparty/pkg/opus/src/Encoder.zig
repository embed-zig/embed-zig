const glib = @import("glib");
const binding = @import("binding.zig");
const opus_error = @import("error.zig");
const types = @import("types.zig");

const Self = @This();

handle: *binding.OpusEncoder,
mem: []align(16) u8,
sample_rate: u32,
channels: u8,

pub const Error = types.Error;
pub const Application = types.Application;
pub const Signal = types.Signal;
pub const Bandwidth = types.Bandwidth;

pub fn getSize(channels: u8) usize {
    if (channels != 1 and channels != 2) return 0;
    return @intCast(binding.opus_encoder_get_size(@intCast(channels)));
}

pub fn init(
    allocator: glib.std.mem.Allocator,
    sample_rate: u32,
    channels: u8,
    application: Application,
) (Error || glib.std.mem.Allocator.Error)!Self {
    try validateChannels(channels);
    try validateSampleRate(sample_rate);
    const size = getSize(channels);
    const mem = try allocator.alignedAlloc(u8, .@"16", size);
    errdefer allocator.free(mem);

    const handle: *binding.OpusEncoder = @ptrCast(mem.ptr);
    try opus_error.checkError(binding.opus_encoder_init(
        handle,
        @intCast(sample_rate),
        @intCast(channels),
        @intFromEnum(application),
    ));

    return .{
        .handle = handle,
        .mem = mem,
        .sample_rate = sample_rate,
        .channels = channels,
    };
}

pub fn deinit(self: *Self, allocator: glib.std.mem.Allocator) void {
    allocator.free(self.mem);
    self.* = undefined;
}

pub fn frameSizeForMs(self: *const Self, ms: u32) u32 {
    return self.sample_rate * ms / 1000;
}

pub fn encode(self: *Self, pcm: []const i16, frame_size: u32, out: []u8) Error![]const u8 {
    try self.validatePcmLen(pcm.len, frame_size);
    try validateOutLen(out.len);
    const n = try opus_error.checkedPositive(binding.opus_encode(
        self.handle,
        pcm.ptr,
        @intCast(frame_size),
        out.ptr,
        @intCast(out.len),
    ));
    return out[0..n];
}

pub fn encodeFloat(self: *Self, pcm: []const f32, frame_size: u32, out: []u8) Error![]const u8 {
    try self.validatePcmLen(pcm.len, frame_size);
    try validateOutLen(out.len);
    const n = try opus_error.checkedPositive(binding.opus_encode_float(
        self.handle,
        pcm.ptr,
        @intCast(frame_size),
        out.ptr,
        @intCast(out.len),
    ));
    return out[0..n];
}

pub fn setBitrate(self: *Self, bitrate: u32) Error!void {
    try opus_error.checkError(binding.opus_encoder_ctl(
        self.handle,
        binding.OPUS_SET_BITRATE_REQUEST,
        @as(c_int, @intCast(bitrate)),
    ));
}

pub fn getBitrate(self: *Self) Error!u32 {
    var value: i32 = 0;
    try opus_error.checkError(binding.opus_encoder_ctl(self.handle, binding.OPUS_GET_BITRATE_REQUEST, &value));
    return @intCast(value);
}

pub fn setComplexity(self: *Self, complexity: u4) Error!void {
    if (complexity > 10) return Error.BadArg;
    try opus_error.checkError(binding.opus_encoder_ctl(self.handle, binding.OPUS_SET_COMPLEXITY_REQUEST, @as(c_int, complexity)));
}

pub fn setSignal(self: *Self, signal: Signal) Error!void {
    try opus_error.checkError(binding.opus_encoder_ctl(self.handle, binding.OPUS_SET_SIGNAL_REQUEST, @intFromEnum(signal)));
}

pub fn setBandwidth(self: *Self, bandwidth: Bandwidth) Error!void {
    try opus_error.checkError(binding.opus_encoder_ctl(self.handle, binding.OPUS_SET_BANDWIDTH_REQUEST, @intFromEnum(bandwidth)));
}

pub fn setVbr(self: *Self, enable: bool) Error!void {
    try opus_error.checkError(binding.opus_encoder_ctl(self.handle, binding.OPUS_SET_VBR_REQUEST, @as(c_int, @intFromBool(enable))));
}

pub fn setDtx(self: *Self, enable: bool) Error!void {
    try opus_error.checkError(binding.opus_encoder_ctl(self.handle, binding.OPUS_SET_DTX_REQUEST, @as(c_int, @intFromBool(enable))));
}

pub fn resetState(self: *Self) Error!void {
    try opus_error.checkError(binding.opus_encoder_ctl(self.handle, binding.OPUS_RESET_STATE));
}

fn validateChannels(channels: u8) Error!void {
    if (channels != 1 and channels != 2) return Error.BadArg;
}

fn validateOutLen(out_len: usize) Error!void {
    if (out_len == 0) return Error.BufferTooSmall;
}

fn validateSampleRate(sample_rate: u32) Error!void {
    switch (sample_rate) {
        8_000, 12_000, 16_000, 24_000, 48_000 => {},
        else => return Error.BadArg,
    }
}

fn validatePcmLen(self: *const Self, sample_count: usize, frame_size: u32) Error!void {
    if (frame_size == 0) return Error.BadArg;
    const channels: usize = self.channels;
    const max_usize = ~@as(usize, 0);
    const frame_samples: usize = @intCast(frame_size);
    if (frame_samples > max_usize / channels) return Error.BadArg;
    if (sample_count < frame_samples * channels) return Error.BadArg;
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn initAndControls() !void {
            try grt.std.testing.expect(getSize(1) > 0);

            var encoder = try Self.init(grt.std.testing.allocator, 48_000, 1, .audio);
            defer encoder.deinit(grt.std.testing.allocator);

            try grt.std.testing.expectEqual(@as(u32, 48_000), encoder.sample_rate);
            try grt.std.testing.expectEqual(@as(u8, 1), encoder.channels);
            try grt.std.testing.expectEqual(@as(u32, 960), encoder.frameSizeForMs(20));

            try encoder.setBitrate(64_000);
            try grt.std.testing.expect(try encoder.getBitrate() > 0);
            try encoder.setComplexity(10);
            try encoder.setSignal(.music);
            try encoder.setBandwidth(.fullband);
            try encoder.setVbr(false);
            try encoder.setDtx(false);
            try encoder.resetState();
        }

        fn rejectsInvalidChannelsAndShortPcm() !void {
            try grt.std.testing.expectEqual(@as(usize, 0), getSize(3));
            try grt.std.testing.expectError(Error.BadArg, Self.init(grt.std.testing.allocator, 48_000, 3, .audio));

            var encoder = try Self.init(grt.std.testing.allocator, 48_000, 2, .audio);
            defer encoder.deinit(grt.std.testing.allocator);

            const frame_size = encoder.frameSizeForMs(20);
            const too_short = [_]i16{0} ** 1919;
            var valid_pcm: [1920]i16 = undefined;
            for (&valid_pcm, 0..) |*sample, i| {
                const lane: i32 = if (i % 2 == 0) -1 else 1;
                sample.* = @intCast((@as(i32, @intCast(i % 113)) + 17) * 97 * lane);
            }
            var out: [1500]u8 = undefined;
            const empty_out = [_]u8{};

            try grt.std.testing.expectError(Error.BadArg, encoder.encode(too_short[0..], frame_size, out[0..]));
            try grt.std.testing.expectError(Error.BadArg, encoder.encode(too_short[0..0], 0, out[0..]));
            try grt.std.testing.expectError(Error.BufferTooSmall, encoder.encode(valid_pcm[0..], frame_size, empty_out[0..]));
            try grt.std.testing.expectError(Error.BadArg, encoder.setComplexity(11));
        }

        fn rejectsInvalidSampleRate() !void {
            try grt.std.testing.expectError(Error.BadArg, Self.init(grt.std.testing.allocator, 44_100, 1, .audio));
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

            TestCase.initAndControls() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.rejectsInvalidChannelsAndShortPcm() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.rejectsInvalidSampleRate() catch |err| {
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
