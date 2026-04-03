//! audio.mixer.Default — portable default mixer backend.

const Track = @import("Track.zig");
const TrackCtrl = @import("TrackCtrl.zig");
const Format = @import("Format.zig");

pub fn make(comptime lib: type, comptime TrackHandle: type) type {
    const Allocator = lib.mem.Allocator;
    const Thread = lib.Thread;
    const ArrayListUnmanaged = lib.ArrayListUnmanaged;

    const RingBuffer = struct {
        allocator: Allocator,
        items: []i16,
        head: usize = 0,
        len: usize = 0,
        write_closed: bool = false,
        has_error: bool = false,
        mutex: Thread.Mutex = .{},
        cond: Thread.Condition = .{},

        fn init(allocator: Allocator, capacity: usize) !@This() {
            return .{
                .allocator = allocator,
                .items = try allocator.alloc(i16, capacity),
            };
        }

        fn deinit(self: *@This()) void {
            self.allocator.free(self.items);
            self.* = undefined;
        }

        fn write(self: *@This(), samples: []const i16) error{Closed}!void {
            if (samples.len == 0) return;

            var offset: usize = 0;
            self.mutex.lock();
            defer self.mutex.unlock();

            while (offset < samples.len) {
                while (self.len >= self.items.len and !self.write_closed and !self.has_error) {
                    self.cond.wait(&self.mutex);
                }

                if (self.write_closed or self.has_error) return error.Closed;

                const space = self.items.len - self.len;
                const n = @min(samples.len - offset, space);
                self.writeLocked(samples[offset .. offset + n]);
                offset += n;
            }
        }

        fn closeWrite(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.write_closed = true;
            self.cond.broadcast();
        }

        fn closeWithError(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.write_closed = true;
            self.has_error = true;
            self.head = 0;
            self.len = 0;
            self.cond.broadcast();
        }

        fn count(self: *@This()) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.len;
        }

        fn isDrained(self: *@This()) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.write_closed and self.len == 0;
        }

        fn mixInto(self: *@This(), out: []i16, gain: f32) usize {
            self.mutex.lock();
            defer self.mutex.unlock();

            const n = @min(out.len, self.len);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const sample = self.peekLocked(i);
                const scaled = @as(f32, @floatFromInt(sample)) * gain;
                const mixed = @as(f32, @floatFromInt(out[i])) + scaled;
                out[i] = clampToI16(mixed);
            }
            self.consumeLocked(n);
            if (n > 0) self.cond.broadcast();
            return n;
        }

        fn writeLocked(self: *@This(), samples: []const i16) void {
            var offset: usize = 0;
            while (offset < samples.len) {
                const tail = (self.head + self.len) % self.items.len;
                const contiguous = @min(samples.len - offset, self.items.len - tail);
                @memcpy(self.items[tail .. tail + contiguous], samples[offset .. offset + contiguous]);
                self.len += contiguous;
                offset += contiguous;
            }
        }

        fn peekLocked(self: *@This(), index: usize) i16 {
            return self.items[(self.head + index) % self.items.len];
        }

        fn consumeLocked(self: *@This(), n: usize) void {
            const actual = @min(n, self.len);
            if (actual == 0) return;
            self.head = (self.head + actual) % self.items.len;
            self.len -= actual;
            if (self.len == 0) self.head = 0;
        }
    };

    const TrackState = struct {
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

        fn create(allocator: Allocator, output: Format, config: Track.Config) !*@This() {
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

        fn retain(self: *@This()) void {
            _ = @atomicRmw(usize, &self.refs, .Add, 1, .acq_rel);
        }

        fn releaseHandle(self: *@This()) void {
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

        fn releaseSetupRef(self: *@This()) void {
            const old = @atomicRmw(usize, &self.refs, .Sub, 1, .acq_rel);
            if (old == 1) self.destroy();
        }

        fn releaseMixerRef(self: *@This()) void {
            const old = @atomicRmw(usize, &self.refs, .Sub, 1, .acq_rel);
            if (old == 1) self.destroy();
        }

        fn destroy(self: *@This()) void {
            self.buffer.deinit();
            self.allocator.free(self.label_buf);
            self.allocator.destroy(self);
        }

        fn setGain(self: *@This(), value: f32) void {
            const sanitized = if (value == value) value else 0;
            @atomicStore(u32, &self.gain_bits, @bitCast(sanitized), .release);
        }

        fn gain(self: *@This()) f32 {
            return @bitCast(@atomicLoad(u32, &self.gain_bits, .acquire));
        }

        fn label(self: *@This()) []const u8 {
            return self.label_buf;
        }

        fn readBytes(self: *@This()) usize {
            return @atomicLoad(usize, &self.read_bytes_val, .acquire);
        }

        fn addReadBytes(self: *@This(), count: usize) void {
            _ = @atomicRmw(usize, &self.read_bytes_val, .Add, count, .acq_rel);
        }

        fn setFadeOutDuration(self: *@This(), ms: u32) void {
            @atomicStore(u32, &self.fade_out_ms_val, ms, .release);
        }

        fn closeWrite(self: *@This()) void {
            self.buffer.closeWrite();
        }

        fn close(self: *@This()) void {
            if (@atomicLoad(u32, &self.fade_out_ms_val, .acquire) > 0) {
                self.setGain(0);
            }
            self.closeWrite();
        }

        fn closeWithError(self: *@This()) void {
            self.buffer.closeWithError();
        }

        fn closeWriteWithSilence(self: *@This(), silence_ms: u32) !void {
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

        fn setGainLinearTo(self: *@This(), to: f32, _: u32) void {
            self.setGain(to);
        }

        fn write(self: *@This(), format: Format, samples: []const i16) !void {
            if (samples.len == 0) return;

            const in_channels = @as(usize, format.channelCount());
            if (format.rate == 0 or samples.len % in_channels != 0) return error.InvalidSamples;

            if (format.eql(self.output)) {
                return self.buffer.write(samples);
            }

            try self.convertAndWrite(format, samples);
        }

        fn mixInto(self: *@This(), out: []i16) usize {
            const n = self.buffer.mixInto(out, self.gain());
            if (n > 0) self.addReadBytes(n * @sizeOf(i16));
            return n;
        }

        fn isDrained(self: *@This()) bool {
            return self.buffer.isDrained();
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

    const TrackImpl = struct {
        pub const Config = struct {
            allocator: Allocator,
            state: *TrackState,
        };

        state: *TrackState,

        pub fn init(config: Config) !@This() {
            _ = config.allocator;
            return .{ .state = config.state };
        }

        pub fn write(self: *@This(), format: Format, samples: []const i16) !void {
            return self.state.write(format, samples);
        }

        pub fn deinit(self: *@This()) void {
            self.state.releaseHandle();
        }
    };

    const TrackCtrlImpl = struct {
        pub const Config = struct {
            allocator: Allocator,
            state: *TrackState,
        };

        state: *TrackState,

        pub fn init(config: Config) !@This() {
            _ = config.allocator;
            return .{ .state = config.state };
        }

        pub fn setGain(self: *@This(), value: f32) void {
            self.state.setGain(value);
        }

        pub fn gain(self: *@This()) f32 {
            return self.state.gain();
        }

        pub fn label(self: *@This()) []const u8 {
            return self.state.label();
        }

        pub fn readBytes(self: *@This()) usize {
            return self.state.readBytes();
        }

        pub fn setFadeOutDuration(self: *@This(), ms: u32) void {
            self.state.setFadeOutDuration(ms);
        }

        pub fn closeWrite(self: *@This()) void {
            self.state.closeWrite();
        }

        pub fn closeWriteWithSilence(self: *@This(), silence_ms: u32) void {
            self.state.closeWriteWithSilence(silence_ms) catch self.state.closeWrite();
        }

        pub fn close(self: *@This()) void {
            self.state.close();
        }

        pub fn closeWithError(self: *@This()) void {
            self.state.closeWithError();
        }

        pub fn setGainLinearTo(self: *@This(), to: f32, duration_ms: u32) void {
            self.state.setGainLinearTo(to, duration_ms);
        }

        pub fn deinit(self: *@This()) void {
            self.state.releaseHandle();
        }
    };

    return struct {
        const Self = @This();

        pub const Config = struct {
            allocator: Allocator,
            output: Format,
        };

        allocator: Allocator,
        output: Format,
        mutex: Thread.Mutex = .{},
        tracks: ArrayListUnmanaged(*TrackState) = .{},
        close_write: bool = false,
        closed: bool = false,
        close_error: bool = false,

        pub fn init(config: Config) !Self {
            if (config.output.rate == 0) return error.InvalidConfig;
            return .{
                .allocator = config.allocator,
                .output = config.output,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.close_write = true;
            self.closed = true;
            self.close_error = true;
            while (self.tracks.items.len > 0) {
                const state = self.tracks.orderedRemove(self.tracks.items.len - 1);
                state.closeWithError();
                state.releaseMixerRef();
            }
            self.tracks.deinit(self.allocator);
        }

        pub fn createTrack(self: *Self, config: Track.Config) !TrackHandle {
            const TrackType = Track.make(lib, TrackImpl);
            const TrackCtrlType = TrackCtrl.make(lib, TrackCtrlImpl);

            self.mutex.lock();
            const unavailable = self.close_write or self.closed or self.close_error;
            self.mutex.unlock();
            if (unavailable) return error.Closed;

            const state = try TrackState.create(self.allocator, self.output, config);
            state.owner_ptr = self;
            state.on_last_handle_dropped = onLastHandleDroppedFn;

            state.retain();
            const track = TrackType.init(.{
                .allocator = self.allocator,
                .state = state,
            }) catch |err| {
                state.releaseSetupRef();
                return err;
            };
            errdefer track.deinit();

            state.retain();
            const ctrl = TrackCtrlType.init(.{
                .allocator = self.allocator,
                .state = state,
            }) catch |err| {
                state.releaseSetupRef();
                return err;
            };
            errdefer ctrl.deinit();

            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.close_write or self.closed or self.close_error) return error.Closed;

            state.retain();
            self.tracks.append(self.allocator, state) catch |err| {
                state.releaseSetupRef();
                return err;
            };

            return .{
                .track = track,
                .ctrl = ctrl,
            };
        }

        pub fn read(self: *Self, out: []i16) ?usize {
            if (out.len == 0) return 0;

            @memset(out, 0);

            self.mutex.lock();
            defer self.mutex.unlock();

            var read_n: usize = 0;
            var i: usize = 0;
            while (i < self.tracks.items.len) {
                const state = self.tracks.items[i];
                const mixed_n = state.mixInto(out);
                if (mixed_n > read_n) read_n = mixed_n;

                if (state.isDrained()) {
                    _ = self.tracks.swapRemove(i);
                    state.releaseMixerRef();
                    continue;
                }
                i += 1;
            }

            if (read_n > 0) return read_n;
            if (self.closed or self.close_error) return null;
            if (self.close_write and self.tracks.items.len == 0) return null;
            return 0;
        }

        pub fn closeWrite(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.close_write) return;
            self.close_write = true;
            for (self.tracks.items) |state| state.closeWrite();
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Mixer-level close is terminal: unlike per-track close, it stops
            // exposing any remaining queued audio through future reads.
            self.closed = true;
            self.close_write = true;
            while (self.tracks.items.len > 0) {
                const state = self.tracks.orderedRemove(self.tracks.items.len - 1);
                state.closeWithError();
                state.releaseMixerRef();
            }
        }

        pub fn closeWithError(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.closed = true;
            self.close_write = true;
            self.close_error = true;
            while (self.tracks.items.len > 0) {
                const state = self.tracks.orderedRemove(self.tracks.items.len - 1);
                state.closeWithError();
                state.releaseMixerRef();
            }
        }

        fn onLastHandleDroppedFn(ptr: *anyopaque, state: *TrackState) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.onLastHandleDropped(state);
        }

        fn onLastHandleDropped(self: *Self, state: *TrackState) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            var i: usize = 0;
            while (i < self.tracks.items.len) : (i += 1) {
                if (self.tracks.items[i] != state) continue;
                if (state.isDrained()) {
                    _ = self.tracks.swapRemove(i);
                    state.releaseMixerRef();
                }
                return;
            }
        }
    };
}

fn clampToI16(value: f32) i16 {
    if (value != value) return 0;
    if (value > 32767.0) return 32767;
    if (value < -32768.0) return -32768;
    return @intFromFloat(value);
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

test "audio/unit_tests/Mixer_default_backend_happy_path" {
    const std = @import("std");

    const MixerType = @import("../Mixer.zig").makeDefault(std);
    const mixer = try MixerType.init(.{
        .allocator = std.testing.allocator,
        .output = .{ .rate = 16000, .channels = .mono },
    });
    defer mixer.deinit();

    const handle = try mixer.createTrack(.{ .label = "song" });
    defer handle.track.deinit();
    defer handle.ctrl.deinit();

    try handle.track.write(.{ .rate = 16000, .channels = .mono }, &.{ 10, 20, 30 });

    var out: [4]i16 = undefined;
    const n = mixer.read(&out) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(i16, &.{ 10, 20, 30 }, out[0..3]);
    try std.testing.expectEqual(@as(usize, 6), handle.ctrl.readBytes());
}

test "audio/unit_tests/Mixer_default_backend_mixes_gain" {
    const std = @import("std");

    const MixerType = @import("../Mixer.zig").makeDefault(std);
    const mixer = try MixerType.init(.{
        .allocator = std.testing.allocator,
        .output = .{ .rate = 16000, .channels = .mono },
    });
    defer mixer.deinit();

    const a = try mixer.createTrack(.{ .label = "a" });
    defer a.track.deinit();
    defer a.ctrl.deinit();
    const b = try mixer.createTrack(.{ .label = "b" });
    defer b.track.deinit();
    defer b.ctrl.deinit();

    b.ctrl.setGain(0.5);
    try a.track.write(.{ .rate = 16000, .channels = .mono }, &.{ 100, 200 });
    try b.track.write(.{ .rate = 16000, .channels = .mono }, &.{ 100, 200 });

    var out: [4]i16 = undefined;
    const n = mixer.read(&out) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualSlices(i16, &.{ 150, 300 }, out[0..2]);
}

test "audio/unit_tests/Mixer_default_backend_drains_after_close_write" {
    const std = @import("std");

    const MixerType = @import("../Mixer.zig").makeDefault(std);
    const mixer = try MixerType.init(.{
        .allocator = std.testing.allocator,
        .output = .{ .rate = 8000, .channels = .mono },
    });
    defer mixer.deinit();

    const handle = try mixer.createTrack(.{});
    defer handle.track.deinit();
    defer handle.ctrl.deinit();

    try handle.track.write(.{ .rate = 8000, .channels = .mono }, &.{ 7, 8 });
    mixer.closeWrite();

    var out: [4]i16 = undefined;
    try std.testing.expectEqual(@as(?usize, 2), mixer.read(&out));
    try std.testing.expectEqual(@as(?usize, null), mixer.read(&out));
}

test "audio/unit_tests/Mixer_default_backend_rejects_writes_after_close" {
    const std = @import("std");

    const MixerType = @import("../Mixer.zig").makeDefault(std);
    const mixer = try MixerType.init(.{
        .allocator = std.testing.allocator,
        .output = .{ .rate = 8000, .channels = .mono },
    });
    defer mixer.deinit();

    const handle = try mixer.createTrack(.{});
    defer handle.track.deinit();
    defer handle.ctrl.deinit();

    handle.ctrl.closeWrite();
    try std.testing.expectError(error.Closed, handle.track.write(.{ .rate = 8000, .channels = .mono }, &.{ 1, 2 }));
}

test "audio/unit_tests/Mixer_default_backend_rejects_create_after_mixer_close_write" {
    const std = @import("std");

    const MixerType = @import("../Mixer.zig").makeDefault(std);
    const mixer = try MixerType.init(.{
        .allocator = std.testing.allocator,
        .output = .{ .rate = 8000, .channels = .mono },
    });
    defer mixer.deinit();

    mixer.closeWrite();
    try std.testing.expectError(error.Closed, mixer.createTrack(.{}));
}

test "audio/unit_tests/Mixer_default_backend_close_is_terminal_without_error_path" {
    const std = @import("std");

    const MixerType = @import("../Mixer.zig").makeDefault(std);
    const mixer = try MixerType.init(.{
        .allocator = std.testing.allocator,
        .output = .{ .rate = 8000, .channels = .mono },
    });
    defer mixer.deinit();

    const handle = try mixer.createTrack(.{});
    defer handle.track.deinit();
    defer handle.ctrl.deinit();

    try handle.track.write(.{ .rate = 8000, .channels = .mono }, &.{ 1, 2 });
    mixer.close();

    var out: [4]i16 = undefined;
    try std.testing.expectEqual(@as(?usize, null), mixer.read(&out));
    try std.testing.expectError(error.Closed, mixer.createTrack(.{}));
}

test "audio/unit_tests/Mixer_default_backend_last_handle_drop_closes_track_and_preserves_buffered_audio" {
    const std = @import("std");

    const MixerType = @import("../Mixer.zig").makeDefault(std);
    const mixer = try MixerType.init(.{
        .allocator = std.testing.allocator,
        .output = .{ .rate = 8000, .channels = .mono },
    });
    defer mixer.deinit();

    var handle = try mixer.createTrack(.{});
    try handle.track.write(.{ .rate = 8000, .channels = .mono }, &.{ 4, 5 });
    handle.track.deinit();
    handle.ctrl.deinit();

    var out: [4]i16 = undefined;
    try std.testing.expectEqual(@as(?usize, 2), mixer.read(&out));
    try std.testing.expectEqualSlices(i16, &.{ 4, 5 }, out[0..2]);
    try std.testing.expectEqual(@as(?usize, 0), mixer.read(&out));
}

test "audio/unit_tests/Mixer_default_backend_close_write_with_silence_appends_tail" {
    const std = @import("std");

    const MixerType = @import("../Mixer.zig").makeDefault(std);
    const mixer = try MixerType.init(.{
        .allocator = std.testing.allocator,
        .output = .{ .rate = 1000, .channels = .mono },
    });
    defer mixer.deinit();

    const handle = try mixer.createTrack(.{});
    defer handle.track.deinit();
    defer handle.ctrl.deinit();

    try handle.track.write(.{ .rate = 1000, .channels = .mono }, &.{9});
    handle.ctrl.closeWriteWithSilence(2);

    var out: [4]i16 = undefined;
    const n = mixer.read(&out) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(i16, &.{ 9, 0, 0 }, out[0..3]);
    try std.testing.expectEqual(@as(?usize, 0), mixer.read(&out));
}

test "audio/unit_tests/Mixer_default_backend_sanitizes_nan_gain" {
    const std = @import("std");

    const MixerType = @import("../Mixer.zig").makeDefault(std);
    const mixer = try MixerType.init(.{
        .allocator = std.testing.allocator,
        .output = .{ .rate = 1000, .channels = .mono },
    });
    defer mixer.deinit();

    const handle = try mixer.createTrack(.{});
    defer handle.track.deinit();
    defer handle.ctrl.deinit();

    handle.ctrl.setGain(std.math.nan(f32));
    try handle.track.write(.{ .rate = 1000, .channels = .mono }, &.{ 9, 9 });

    var out: [4]i16 = undefined;
    const n = mixer.read(&out) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualSlices(i16, &.{ 0, 0 }, out[0..2]);
}

test "audio/unit_tests/Mixer_default_backend_overflowing_silence_tail_falls_back_to_close_write" {
    const std = @import("std");

    const MixerType = @import("../Mixer.zig").makeDefault(std);
    const mixer = try MixerType.init(.{
        .allocator = std.testing.allocator,
        .output = .{ .rate = std.math.maxInt(u32), .channels = .stereo },
    });
    defer mixer.deinit();

    const handle = try mixer.createTrack(.{});
    defer handle.track.deinit();
    defer handle.ctrl.deinit();

    try handle.track.write(.{ .rate = std.math.maxInt(u32), .channels = .stereo }, &.{ 1, 2 });
    handle.ctrl.closeWriteWithSilence(std.math.maxInt(u32));

    var out: [8]i16 = undefined;
    const n = mixer.read(&out) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualSlices(i16, &.{ 1, 2 }, out[0..2]);
    try std.testing.expectEqual(@as(?usize, 0), mixer.read(&out));
}

test "audio/unit_tests/Mixer_default_backend_converts_format" {
    const std = @import("std");

    const MixerType = @import("../Mixer.zig").makeDefault(std);
    const mixer = try MixerType.init(.{
        .allocator = std.testing.allocator,
        .output = .{ .rate = 2000, .channels = .mono },
    });
    defer mixer.deinit();

    const handle = try mixer.createTrack(.{});
    defer handle.track.deinit();
    defer handle.ctrl.deinit();

    try handle.track.write(.{ .rate = 1000, .channels = .stereo }, &.{ 10, 30, 20, 40 });

    var out: [8]i16 = undefined;
    const n = mixer.read(&out) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualSlices(i16, &.{ 20, 20, 30, 30 }, out[0..4]);
}

test "audio/unit_tests/Mixer_default_backend_unblocks_blocked_writer_on_error_close" {
    const std = @import("std");

    const MixerType = @import("../Mixer.zig").makeDefault(std);
    const mixer = try MixerType.init(.{
        .allocator = std.testing.allocator,
        .output = .{ .rate = 16000, .channels = .mono },
    });
    defer mixer.deinit();

    const handle = try mixer.createTrack(.{ .buffer_capacity = 2 });
    defer handle.track.deinit();
    defer handle.ctrl.deinit();

    const State = struct {
        track: Track,
        result: ?anyerror = null,
    };

    var state = State{
        .track = handle.track,
    };

    const worker = try std.Thread.spawn(.{}, struct {
        fn run(s: *State) void {
            s.result = s.track.write(.{ .rate = 16000, .channels = .mono }, &.{ 1, 2, 3, 4 });
        }
    }.run, .{&state});

    std.Thread.sleep(10 * std.time.ns_per_ms);
    handle.ctrl.closeWithError();
    worker.join();

    try std.testing.expectError(error.Closed, state.result.?);
}
