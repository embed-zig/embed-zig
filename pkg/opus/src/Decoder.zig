const embed = @import("embed");
const binding = @import("binding.zig");
const opus_error = @import("error.zig");
pub const Error = @import("types.zig").Error;

const Self = @This();

handle: *binding.OpusDecoder,
mem: []align(16) u8,
sample_rate: u32,
channels: u8,

pub fn getSize(channels: u8) usize {
    if (channels != 1 and channels != 2) return 0;
    return @intCast(binding.opus_decoder_get_size(@intCast(channels)));
}

pub fn init(
    allocator: embed.mem.Allocator,
    sample_rate: u32,
    channels: u8,
) (Error || embed.mem.Allocator.Error)!Self {
    try validateChannels(channels);
    try validateSampleRate(sample_rate);
    const size = getSize(channels);
    const mem = try allocator.alignedAlloc(u8, .@"16", size);
    errdefer allocator.free(mem);

    const handle: *binding.OpusDecoder = @ptrCast(mem.ptr);
    try opus_error.checkError(binding.opus_decoder_init(handle, @intCast(sample_rate), @intCast(channels)));

    return .{
        .handle = handle,
        .mem = mem,
        .sample_rate = sample_rate,
        .channels = channels,
    };
}

pub fn deinit(self: *Self, allocator: embed.mem.Allocator) void {
    allocator.free(self.mem);
    self.* = undefined;
}

pub fn frameSizeForMs(self: *const Self, ms: u32) u32 {
    return self.sample_rate * ms / 1000;
}

pub fn decode(self: *Self, data: []const u8, pcm: []i16, fec: bool) Error![]const i16 {
    try validatePacketData(data);
    const frame_size = try self.frameSizeFromPcmLen(pcm.len);
    const n = try opus_error.checkedPositive(binding.opus_decode(
        self.handle,
        data.ptr,
        @intCast(data.len),
        pcm.ptr,
        frame_size,
        @intFromBool(fec),
    ));
    return pcm[0 .. try self.totalSamples(n, pcm.len)];
}

pub fn decodeFloat(self: *Self, data: []const u8, pcm: []f32, fec: bool) Error![]const f32 {
    try validatePacketData(data);
    const frame_size = try self.frameSizeFromPcmLen(pcm.len);
    const n = try opus_error.checkedPositive(binding.opus_decode_float(
        self.handle,
        data.ptr,
        @intCast(data.len),
        pcm.ptr,
        frame_size,
        @intFromBool(fec),
    ));
    return pcm[0 .. try self.totalSamples(n, pcm.len)];
}

pub fn plc(self: *Self, pcm: []i16) Error![]const i16 {
    const frame_size = try self.frameSizeFromPcmLen(pcm.len);
    const n = try opus_error.checkedPositive(binding.opus_decode(self.handle, null, 0, pcm.ptr, frame_size, 0));
    return pcm[0 .. try self.totalSamples(n, pcm.len)];
}

pub fn plcFloat(self: *Self, pcm: []f32) Error![]const f32 {
    const frame_size = try self.frameSizeFromPcmLen(pcm.len);
    const n = try opus_error.checkedPositive(binding.opus_decode_float(self.handle, null, 0, pcm.ptr, frame_size, 0));
    return pcm[0 .. try self.totalSamples(n, pcm.len)];
}

pub fn getSampleRate(self: *Self) Error!u32 {
    var value: i32 = 0;
    try opus_error.checkError(binding.opus_decoder_ctl(self.handle, binding.OPUS_GET_SAMPLE_RATE_REQUEST, &value));
    return @intCast(value);
}

pub fn resetState(self: *Self) Error!void {
    try opus_error.checkError(binding.opus_decoder_ctl(self.handle, binding.OPUS_RESET_STATE));
}

fn validateChannels(channels: u8) Error!void {
    if (channels != 1 and channels != 2) return Error.BadArg;
}

fn validateSampleRate(sample_rate: u32) Error!void {
    switch (sample_rate) {
        8_000, 12_000, 16_000, 24_000, 48_000 => {},
        else => return Error.BadArg,
    }
}

fn validatePacketData(data: []const u8) Error!void {
    if (data.len == 0) return Error.InvalidPacket;
}

fn frameSizeFromPcmLen(self: *const Self, sample_count: usize) Error!c_int {
    const channels: usize = self.channels;
    if (sample_count == 0 or sample_count % channels != 0) return Error.BadArg;
    return @intCast(sample_count / channels);
}

fn totalSamples(self: *const Self, samples_per_channel: usize, capacity: usize) Error!usize {
    const channels: usize = self.channels;
    const max_usize = ~@as(usize, 0);
    if (samples_per_channel > max_usize / channels) return Error.InternalError;
    const total = samples_per_channel * channels;
    if (total > capacity) return Error.InternalError;
    return total;
}

pub fn TestRunner(comptime lib: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const TestCase = struct {
        fn initAndQuerySampleRate() !void {
            try lib.testing.expect(getSize(1) > 0);

            var decoder = try Self.init(lib.testing.allocator, 48_000, 1);
            defer decoder.deinit(lib.testing.allocator);

            try lib.testing.expectEqual(@as(u32, 48_000), decoder.sample_rate);
            try lib.testing.expectEqual(@as(u8, 1), decoder.channels);
            try lib.testing.expectEqual(@as(u32, 960), decoder.frameSizeForMs(20));
            try lib.testing.expectEqual(@as(u32, 48_000), try decoder.getSampleRate());
            try decoder.resetState();
        }

        fn rejectsInvalidSampleRate() !void {
            try lib.testing.expectError(Error.BadArg, Self.init(lib.testing.allocator, 44_100, 1));
        }

        fn stereoDecodeAndPlcReturnFullInterleavedFrames() !void {
            const Encoder = @import("Encoder.zig");

            try lib.testing.expectEqual(@as(usize, 0), getSize(3));
            try lib.testing.expectError(Error.BadArg, Self.init(lib.testing.allocator, 48_000, 3));

            var encoder = try Encoder.init(lib.testing.allocator, 48_000, 2, .audio);
            defer encoder.deinit(lib.testing.allocator);
            var decoder = try Self.init(lib.testing.allocator, 48_000, 2);
            defer decoder.deinit(lib.testing.allocator);

            var pcm: [1920]i16 = undefined;
            for (&pcm, 0..) |*sample, i| {
                const lane: i32 = if (i % 2 == 0) -1 else 1;
                const value: i32 = @as(i32, @intCast(i % 97)) * 120 * lane;
                sample.* = @intCast(value);
            }

            var packet_buf: [1500]u8 = undefined;
            const packet = try encoder.encode(pcm[0..], 960, packet_buf[0..]);

            var decoded: [1920]i16 = undefined;
            const samples = try decoder.decode(packet, decoded[0..], false);
            try lib.testing.expectEqual(@as(usize, 1920), samples.len);
            const fec_samples = try decoder.decode(packet, decoded[0..], true);
            try lib.testing.expectEqual(@as(usize, 1920), fec_samples.len);
            try lib.testing.expectError(Error.BadArg, decoder.decode(packet, decoded[0 .. decoded.len - 1], false));

            const concealed = try decoder.plc(decoded[0..]);
            try lib.testing.expectEqual(@as(usize, 1920), concealed.len);
        }

        fn rejectsEmptyPacketInput() !void {
            var decoder = try Self.init(lib.testing.allocator, 48_000, 1);
            defer decoder.deinit(lib.testing.allocator);

            const empty = [_]u8{};
            var pcm_i16: [960]i16 = undefined;
            var pcm_f32: [960]f32 = undefined;

            try lib.testing.expectError(Error.InvalidPacket, decoder.decode(empty[0..], pcm_i16[0..], false));
            try lib.testing.expectError(Error.InvalidPacket, decoder.decodeFloat(empty[0..], pcm_f32[0..], false));
        }

        fn rejectsNonEmptyInvalidPacketInput() !void {
            var decoder = try Self.init(lib.testing.allocator, 48_000, 1);
            defer decoder.deinit(lib.testing.allocator);

            const invalid = [_]u8{ 0xff, 0xff };
            var pcm_i16: [960]i16 = undefined;
            var pcm_f32: [960]f32 = undefined;

            if (decoder.decode(invalid[0..], pcm_i16[0..], false)) |_| {
                return error.TestUnexpectedResult;
            } else |err| switch (err) {
                Error.InvalidPacket, Error.BadArg, Error.InternalError => {},
                else => return err,
            }

            if (decoder.decodeFloat(invalid[0..], pcm_f32[0..], false)) |_| {
                return error.TestUnexpectedResult;
            } else |err| switch (err) {
                Error.InvalidPacket, Error.BadArg, Error.InternalError => {},
                else => return err,
            }
        }

        fn floatRoundtripSmoke() !void {
            const Encoder = @import("Encoder.zig");

            var encoder = try Encoder.init(lib.testing.allocator, 48_000, 1, .audio);
            defer encoder.deinit(lib.testing.allocator);
            var decoder = try Self.init(lib.testing.allocator, 48_000, 1);
            defer decoder.deinit(lib.testing.allocator);

            var pcm: [960]f32 = undefined;
            for (&pcm, 0..) |*sample, i| {
                const centered = @as(f32, @floatFromInt(@as(i32, @intCast(i % 64)) - 32));
                sample.* = centered / 32.0;
            }

            var packet_buf: [1500]u8 = undefined;
            const packet = try encoder.encodeFloat(pcm[0..], 960, packet_buf[0..]);

            var decoded: [960]f32 = undefined;
            const samples = try decoder.decodeFloat(packet, decoded[0..], false);
            try lib.testing.expectEqual(@as(usize, 960), samples.len);
            const fec_samples = try decoder.decodeFloat(packet, decoded[0..], true);
            try lib.testing.expectEqual(@as(usize, 960), fec_samples.len);

            var energy: f32 = 0;
            for (samples) |sample| energy += @abs(sample);
            try lib.testing.expect(energy > 1.0);

            const concealed = try decoder.plcFloat(decoded[0..]);
            try lib.testing.expectEqual(@as(usize, 960), concealed.len);
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

            TestCase.initAndQuerySampleRate() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.rejectsInvalidSampleRate() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.stereoDecodeAndPlcReturnFullInterleavedFrames() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.rejectsEmptyPacketInput() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.rejectsNonEmptyInvalidPacketInput() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.floatRoundtripSmoke() catch |err| {
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
