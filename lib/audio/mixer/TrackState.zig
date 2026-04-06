//! audio.mixer.TrackState — shared mixer-owned track state.

const Track = @import("Track.zig");
const Format = @import("Format.zig");
const RingBufferMod = @import("RingBuffer.zig");
const testing_api = @import("testing");

pub fn make(comptime lib: type) type {
    const Allocator = lib.mem.Allocator;
    const RingBuffer = RingBufferMod.make(lib);

    return struct {
        allocator: Allocator,
        output: Format,
        label_buf: []u8,
        gain_bits: u32 = @bitCast(@as(f32, 1.0)),
        read_bytes_val: usize = 0,
        fade_out_ms_val: u32 = 0,
        refs: usize = 0,
        owner_ptr: ?*anyopaque = null,
        on_last_handle_dropped: ?*const fn (ptr: *anyopaque, state: *@This()) void = null,
        buffer: RingBuffer,

        pub fn create(allocator: Allocator, output: Format, config: Track.Config) !*@This() {
            if (output.rate == 0) return error.InvalidConfig;
            if (config.buffer_capacity == 0) return error.InvalidConfig;

            const state = try allocator.create(@This());
            errdefer allocator.destroy(state);

            const label_buf = try allocator.dupe(u8, config.label);
            errdefer allocator.free(label_buf);

            const buffer = try RingBuffer.init(allocator, config.buffer_capacity);
            errdefer {
                var cleanup = buffer;
                cleanup.deinit();
            }

            state.* = .{
                .allocator = allocator,
                .output = output,
                .label_buf = label_buf,
                .buffer = buffer,
            };
            state.setGain(config.gain);
            return state;
        }

        pub fn retain(self: *@This()) void {
            _ = @atomicRmw(usize, &self.refs, .Add, 1, .acq_rel);
        }

        pub fn releaseHandle(self: *@This()) void {
            const old = @atomicRmw(usize, &self.refs, .Sub, 1, .acq_rel);
            if (old == 1) {
                self.destroy();
                return;
            }

            if (old == 2) {
                self.closeWrite();
                if (self.owner_ptr) |owner_ptr| {
                    if (self.on_last_handle_dropped) |cb| cb(owner_ptr, self);
                }
            }
        }

        pub fn releaseSetupRef(self: *@This()) void {
            const old = @atomicRmw(usize, &self.refs, .Sub, 1, .acq_rel);
            if (old == 1) self.destroy();
        }

        pub fn releaseMixerRef(self: *@This()) void {
            const old = @atomicRmw(usize, &self.refs, .Sub, 1, .acq_rel);
            if (old == 1) self.destroy();
        }

        pub fn setGain(self: *@This(), value: f32) void {
            const sanitized = if (value == value) value else 0;
            @atomicStore(u32, &self.gain_bits, @bitCast(sanitized), .release);
        }

        pub fn gain(self: *@This()) f32 {
            return @bitCast(@atomicLoad(u32, &self.gain_bits, .acquire));
        }

        pub fn label(self: *@This()) []const u8 {
            return self.label_buf;
        }

        pub fn readBytes(self: *@This()) usize {
            return @atomicLoad(usize, &self.read_bytes_val, .acquire);
        }

        pub fn setFadeOutDuration(self: *@This(), ms: u32) void {
            @atomicStore(u32, &self.fade_out_ms_val, ms, .release);
        }

        pub fn closeWrite(self: *@This()) void {
            self.buffer.closeWrite();
        }

        pub fn close(self: *@This()) void {
            if (@atomicLoad(u32, &self.fade_out_ms_val, .acquire) > 0) {
                self.setGain(0);
            }
            self.closeWrite();
        }

        pub fn closeWithError(self: *@This()) void {
            self.buffer.closeWithError();
        }

        pub fn closeWriteWithSilence(self: *@This(), silence_ms: u32) !void {
            const rate = @as(u64, self.output.rate);
            const channels = @as(u64, self.output.channelCount());
            const ms = @as(u64, silence_ms);

            if (rate != 0 and channels > lib.math.maxInt(u64) / rate) return error.Overflow;
            const rate_channels = rate * channels;
            if (rate_channels != 0 and ms > lib.math.maxInt(u64) / rate_channels) return error.Overflow;

            const total_samples = (rate_channels * ms) / 1000;
            if (total_samples > lib.math.maxInt(usize)) return error.Overflow;

            var remaining: usize = @intCast(total_samples);
            var zeros: [256]i16 = @splat(0);

            while (remaining > 0) {
                const n = @min(remaining, zeros.len);
                try self.buffer.write(zeros[0..n]);
                remaining -= n;
            }
            self.closeWrite();
        }

        pub fn setGainLinearTo(self: *@This(), to: f32, _: u32) void {
            self.setGain(to);
        }

        pub fn write(self: *@This(), format: Format, samples: []const i16) !void {
            if (samples.len == 0) return;

            const in_channels = @as(usize, format.channelCount());
            if (format.rate == 0 or samples.len % in_channels != 0) return error.InvalidSamples;

            if (format.eql(self.output)) {
                return self.buffer.write(samples);
            }

            try self.convertAndWrite(format, samples);
        }

        pub fn mixInto(self: *@This(), out: []i16) usize {
            const n = self.buffer.mixInto(out, self.gain());
            if (n > 0) self.addReadBytes(n * @sizeOf(i16));
            return n;
        }

        pub fn isDrained(self: *@This()) bool {
            return self.buffer.isDrained();
        }

        fn destroy(self: *@This()) void {
            self.buffer.deinit();
            self.allocator.free(self.label_buf);
            self.allocator.destroy(self);
        }

        fn addReadBytes(self: *@This(), count: usize) void {
            _ = @atomicRmw(usize, &self.read_bytes_val, .Add, count, .acq_rel);
        }

        fn convertAndWrite(self: *@This(), input_format: Format, input_samples: []const i16) !void {
            const in_channels = @as(usize, input_format.channelCount());
            const out_channels = @as(usize, self.output.channelCount());
            const in_frames = input_samples.len / in_channels;
            if (in_frames == 0) return;

            const total_out_frames_128 = ((@as(u128, in_frames) *
                @as(u128, self.output.rate)) +
                @as(u128, input_format.rate) -
                1) / @as(u128, input_format.rate);
            if (total_out_frames_128 > @as(u128, lib.math.maxInt(usize))) return error.Overflow;
            const total_out_frames: usize = @intCast(total_out_frames_128);
            var out_frame_index: usize = 0;
            var scratch: [256]i16 = undefined;
            const chunk_frames_cap = scratch.len / out_channels;

            while (out_frame_index < total_out_frames) {
                const chunk_frames = @min(chunk_frames_cap, total_out_frames - out_frame_index);
                var frame: usize = 0;
                while (frame < chunk_frames) : (frame += 1) {
                    var ch: usize = 0;
                    while (ch < out_channels) : (ch += 1) {
                        scratch[frame * out_channels + ch] = convertSample(
                            input_samples,
                            input_format,
                            self.output,
                            out_frame_index + frame,
                            ch,
                        );
                    }
                }
                try self.buffer.write(scratch[0 .. chunk_frames * out_channels]);
                out_frame_index += chunk_frames;
            }
        }
    };
}

fn convertSample(input: []const i16, input_format: Format, output_format: Format, out_frame: usize, out_channel: usize) i16 {
    const in_channels = @as(usize, input_format.channelCount());
    const out_channels = @as(usize, output_format.channelCount());
    const in_frames = input.len / in_channels;
    if (in_frames == 0) return 0;

    var in_frame = out_frame;
    if (input_format.rate != output_format.rate) {
        const scaled = (@as(u128, out_frame) * @as(u128, input_format.rate)) / @as(u128, output_format.rate);
        if (scaled >= in_frames) {
            in_frame = in_frames - 1;
        } else {
            in_frame = @intCast(scaled);
        }
    }

    const base = in_frame * in_channels;
    if (in_channels == out_channels) return input[base + out_channel];
    if (in_channels == 1 and out_channels == 2) return input[base];

    const left = @as(i32, input[base]);
    const right = @as(i32, input[base + 1]);
    return @intCast(@divTrunc(left + right, 2));
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const State = make(lib);

    const TestCase = struct {
        fn closeWriteWithSilenceAppendsTail(testing: anytype) !void {
            const state = try State.create(lib.testing.allocator, .{ .rate = 1000, .channels = .mono }, .{});
            defer state.destroy();

            try state.write(.{ .rate = 1000, .channels = .mono }, &.{9});
            try state.closeWriteWithSilence(2);

            var out: [4]i16 = @splat(0);
            const n = state.mixInto(&out);
            try testing.expectEqual(@as(usize, 3), n);
            try testing.expectEqualSlices(i16, &.{ 9, 0, 0 }, out[0..3]);
            try testing.expectEqual(@as(usize, 6), state.readBytes());
            try testing.expect(state.isDrained());
        }

        fn sanitizesNanGain(testing: anytype) !void {
            const state = try State.create(lib.testing.allocator, .{ .rate = 1000, .channels = .mono }, .{});
            defer state.destroy();

            state.setGain(lib.math.nan(f32));
            try state.write(.{ .rate = 1000, .channels = .mono }, &.{ 9, 9 });

            var out: [4]i16 = @splat(0);
            const n = state.mixInto(&out);
            try testing.expectEqual(@as(usize, 2), n);
            try testing.expectEqualSlices(i16, &.{ 0, 0 }, out[0..2]);
        }

        fn convertsFormat(testing: anytype) !void {
            const state = try State.create(lib.testing.allocator, .{ .rate = 2000, .channels = .mono }, .{});
            defer state.destroy();

            try state.write(.{ .rate = 1000, .channels = .stereo }, &.{ 10, 30, 20, 40 });

            var out: [8]i16 = @splat(0);
            const n = state.mixInto(&out);
            try testing.expectEqual(@as(usize, 4), n);
            try testing.expectEqualSlices(i16, &.{ 20, 20, 30, 30 }, out[0..4]);
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
            const testing = lib.testing;

            TestCase.closeWriteWithSilenceAppendsTail(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.sanitizesNanGain(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.convertsFormat(testing) catch |err| {
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
