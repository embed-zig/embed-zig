//! audio.Mixer — type-erased PCM mixer surface.

const root = @This();

const TrackStateMod = @import("mixer/TrackState.zig");
const glib = @import("glib");

pub const Track = @import("mixer/Track.zig");
pub const Format = Track.Format;
pub const TrackCtrl = @import("mixer/TrackCtrl.zig");

/// `TrackHandle` returns two views over one logical track. Callers must
/// eventually `deinit()` both `track` and `ctrl` exactly once, and must not use
/// either view after its own `deinit()` or after the mixer that created it has
/// been torn down. Teardown of either side must also be serialized against
/// in-flight reads, writes, control calls, and mixer lifecycle operations.
pub const TrackHandle = struct {
    track: Track,
    ctrl: TrackCtrl,
};

pub const CreateTrackError = anyerror;

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    deinit: *const fn (ptr: *anyopaque) void,
    createTrack: *const fn (ptr: *anyopaque, config: Track.Config) CreateTrackError!TrackHandle,
    read: *const fn (ptr: *anyopaque, out: []i16) ?usize,
    readWithReference: *const fn (ptr: *anyopaque, out: []i16, ref_out: []i16) ?usize,
    closeWrite: *const fn (ptr: *anyopaque) void,
    close: *const fn (ptr: *anyopaque) void,
    closeWithError: *const fn (ptr: *anyopaque) void,
};

/// `deinit()` must not race with active use of this handle or any copied value
/// derived from it. Callers must serialize teardown against in-flight reads,
/// writes, and control operations on handles created from this mixer.
pub fn deinit(self: root) void {
    self.vtable.deinit(self.ptr);
}

pub fn createTrack(self: root, config: Track.Config) CreateTrackError!TrackHandle {
    return self.vtable.createTrack(self.ptr, config);
}

pub fn read(self: root, out: []i16) ?usize {
    return self.vtable.read(self.ptr, out);
}

pub fn readWithReference(self: root, out: []i16, ref_out: []i16) ?usize {
    return self.vtable.readWithReference(self.ptr, out, ref_out);
}

pub fn closeWrite(self: root) void {
    self.vtable.closeWrite(self.ptr);
}

pub fn close(self: root) void {
    self.vtable.close(self.ptr);
}

pub fn closeWithError(self: root) void {
    self.vtable.closeWithError(self.ptr);
}

pub fn make(comptime grt: type) type {
    const Allocator = glib.std.mem.Allocator;
    const ArrayListUnmanaged = grt.std.ArrayListUnmanaged;
    const TrackState = TrackStateMod.make(grt);

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

        pub fn setFadeOutDuration(self: *@This(), duration: glib.time.duration.Duration) void {
            self.state.setFadeOutDuration(duration);
        }

        pub fn closeWrite(self: *@This()) void {
            self.state.closeWrite();
        }

        pub fn closeWriteWithSilence(self: *@This(), duration: glib.time.duration.Duration) void {
            self.state.closeWriteWithSilence(duration) catch self.state.closeWrite();
        }

        pub fn close(self: *@This()) void {
            self.state.close();
        }

        pub fn closeWithError(self: *@This()) void {
            self.state.closeWithError();
        }

        pub fn setGainLinearTo(self: *@This(), to: f32, duration: glib.time.duration.Duration) void {
            self.state.setGainLinearTo(to, duration);
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
            headroom_gain: f32 = 0.5,
            limiter_threshold: f32 = 0.9,
        };

        allocator: Allocator,
        output: Format,
        headroom_gain: f32,
        limiter_threshold: f32,
        mutex: grt.sync.Mutex = .{},
        tracks: ArrayListUnmanaged(*TrackState) = .{},
        mix_accum: ArrayListUnmanaged(f32) = .{},
        ref_accum: ArrayListUnmanaged(f32) = .{},
        close_write: bool = false,
        closed: bool = false,
        close_error: bool = false,

        const Gen = struct {
            fn deinitFn(ptr: *anyopaque) void {
                const self: *Self = @ptrCast(@alignCast(ptr));
                self.deinit();
            }

            fn createTrackFn(ptr: *anyopaque, config: Track.Config) CreateTrackError!TrackHandle {
                const self: *Self = @ptrCast(@alignCast(ptr));
                return self.createTrack(config);
            }

            fn readFn(ptr: *anyopaque, out: []i16) ?usize {
                const self: *Self = @ptrCast(@alignCast(ptr));
                return self.read(out);
            }

            fn readWithReferenceFn(ptr: *anyopaque, out: []i16, ref_out: []i16) ?usize {
                const self: *Self = @ptrCast(@alignCast(ptr));
                return self.readWithReference(out, ref_out);
            }

            fn closeWriteFn(ptr: *anyopaque) void {
                const self: *Self = @ptrCast(@alignCast(ptr));
                self.closeWrite();
            }

            fn closeFn(ptr: *anyopaque) void {
                const self: *Self = @ptrCast(@alignCast(ptr));
                self.close();
            }

            fn closeWithErrorFn(ptr: *anyopaque) void {
                const self: *Self = @ptrCast(@alignCast(ptr));
                self.closeWithError();
            }

            const vtable = VTable{
                .deinit = deinitFn,
                .createTrack = createTrackFn,
                .read = readFn,
                .readWithReference = readWithReferenceFn,
                .closeWrite = closeWriteFn,
                .close = closeFn,
                .closeWithError = closeWithErrorFn,
            };
        };

        pub fn init(config: Config) !root {
            if (config.output.rate == 0) return error.InvalidConfig;

            const self = try config.allocator.create(Self);
            errdefer config.allocator.destroy(self);
            self.* = .{
                .allocator = config.allocator,
                .output = config.output,
                .headroom_gain = sanitizeHeadroomGain(config.headroom_gain),
                .limiter_threshold = sanitizeLimiterThreshold(config.limiter_threshold),
            };

            return .{
                .ptr = self,
                .vtable = &Gen.vtable,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            self.close_write = true;
            self.closed = true;
            self.close_error = true;
            while (self.tracks.items.len > 0) {
                const state = self.tracks.orderedRemove(self.tracks.items.len - 1);
                state.closeWithError();
                state.releaseMixerRef();
            }
            self.tracks.deinit(self.allocator);
            self.mix_accum.deinit(self.allocator);
            self.ref_accum.deinit(self.allocator);
            self.mutex.unlock();
            self.allocator.destroy(self);
        }

        pub fn createTrack(self: *Self, config: Track.Config) !TrackHandle {
            const TrackType = Track.make(grt, TrackImpl);
            const TrackCtrlType = TrackCtrl.make(grt, TrackCtrlImpl);

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
            return self.readWithReferenceMaybe(out, null);
        }

        pub fn readWithReference(self: *Self, out: []i16, ref_out: []i16) ?usize {
            return self.readWithReferenceMaybe(out, ref_out);
        }

        fn readWithReferenceMaybe(self: *Self, out: []i16, ref_out: ?[]i16) ?usize {
            if (out.len == 0) return 0;
            if (ref_out) |reference| glib.std.debug.assert(reference.len >= out.len);

            self.mutex.lock();
            defer self.mutex.unlock();

            const mix = self.prepareAccum(&self.mix_accum, out.len) catch return null;
            const reference_mix = if (ref_out != null)
                self.prepareAccum(&self.ref_accum, out.len) catch return null
            else
                null;

            var read_n: usize = 0;
            var i: usize = 0;
            while (i < self.tracks.items.len) {
                const state = self.tracks.items[i];
                const mixed_n = if (ref_out != null)
                    state.mixFloatIntoReference(mix, reference_mix.?[0..out.len])
                else
                    state.mixFloatInto(mix);
                if (mixed_n > read_n) read_n = mixed_n;

                if (state.isDrained()) {
                    _ = self.tracks.swapRemove(i);
                    state.releaseMixerRef();
                    continue;
                }
                i += 1;
            }

            self.finalizeAccum(out, mix);
            if (ref_out) |reference| self.finalizeAccum(reference[0..out.len], reference_mix.?);

            if (read_n > 0) return read_n;
            if (self.closed or self.close_error) return null;
            if (self.close_write and self.tracks.items.len == 0) return null;
            return 0;
        }

        fn prepareAccum(self: *Self, accum: *ArrayListUnmanaged(f32), len: usize) ![]f32 {
            try accum.ensureTotalCapacity(self.allocator, len);
            accum.items.len = len;
            @memset(accum.items, 0);
            return accum.items;
        }

        fn finalizeAccum(self: *Self, out: []i16, accum: []const f32) void {
            for (out, accum) |*sample, value| {
                sample.* = softLimitToI16(value * self.headroom_gain, self.limiter_threshold);
            }
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

fn sanitizeHeadroomGain(value: f32) f32 {
    if (value != value or value <= 0) return 1.0;
    if (value > 1.0) return 1.0;
    return value;
}

fn sanitizeLimiterThreshold(value: f32) f32 {
    if (value != value) return 0.9;
    if (value < 0.1) return 0.1;
    if (value > 1.0) return 1.0;
    return value;
}

fn softLimitToI16(value: f32, threshold: f32) i16 {
    if (value != value) return 0;

    const full_scale = 32767.0;
    const sign: f32 = if (value < 0) -1.0 else 1.0;
    const abs_value = if (value < 0) -value else value;
    const normalized = abs_value / full_scale;
    const limited = softLimitNormalized(normalized, threshold);
    const scaled = sign * limited * full_scale;

    if (scaled > 32767.0) return 32767;
    if (scaled < -32768.0) return -32768;
    return @intFromFloat(scaled);
}

fn softLimitNormalized(value: f32, threshold: f32) f32 {
    if (value <= threshold) return value;
    if (threshold >= 1.0) return 1.0;

    const knee = 1.0 - threshold;
    const over = value - threshold;
    return threshold + (knee * over) / (over + knee);
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const MixerType = make(grt);

    const TestCase = struct {
        fn exposesSurface() void {
            comptime {
                _ = root.Format;
                _ = root.Track;
                _ = root.TrackCtrl;
                _ = root.TrackHandle;
                _ = root.VTable;
                _ = root.deinit;
                _ = root.createTrack;
                _ = root.read;
                _ = root.closeWrite;
                _ = root.close;
                _ = root.closeWithError;
                _ = root.make;
                _ = make(grt).init;
                _ = Track.write;
                _ = Track.deinit;
                _ = Track.make;
                _ = TrackCtrl.setGain;
                _ = TrackCtrl.gain;
                _ = TrackCtrl.label;
                _ = TrackCtrl.readBytes;
                _ = TrackCtrl.closeWrite;
                _ = TrackCtrl.close;
                _ = TrackCtrl.closeWithError;
                _ = TrackCtrl.deinit;
                _ = TrackCtrl.make;
            }
        }

        fn defaultBackendHappyPath() !void {
            const mixer = try MixerType.init(.{
                .allocator = grt.std.testing.allocator,
                .output = .{ .rate = 16000, .channels = .mono },
            });
            defer mixer.deinit();

            const handle = try mixer.createTrack(.{ .label = "song" });
            defer handle.track.deinit();
            defer handle.ctrl.deinit();

            try handle.track.write(.{ .rate = 16000, .channels = .mono }, &.{ 10, 20, 30 });

            var out: [4]i16 = undefined;
            const n = mixer.read(&out) orelse unreachable;
            try grt.std.testing.expectEqual(@as(usize, 3), n);
            try grt.std.testing.expectEqualSlices(i16, &.{ 5, 10, 15 }, out[0..3]);
            try grt.std.testing.expectEqual(@as(usize, 6), handle.ctrl.readBytes());
        }

        fn defaultBackendMixesGain() !void {
            const mixer = try MixerType.init(.{
                .allocator = grt.std.testing.allocator,
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
            try grt.std.testing.expectEqual(@as(usize, 2), n);
            try grt.std.testing.expectEqualSlices(i16, &.{ 75, 150 }, out[0..2]);
        }

        fn defaultBackendSoftLimitsFullScaleMix() !void {
            const mixer = try MixerType.init(.{
                .allocator = grt.std.testing.allocator,
                .output = .{ .rate = 16000, .channels = .mono },
            });
            defer mixer.deinit();

            const a = try mixer.createTrack(.{ .label = "a" });
            defer a.track.deinit();
            defer a.ctrl.deinit();
            const b = try mixer.createTrack(.{ .label = "b" });
            defer b.track.deinit();
            defer b.ctrl.deinit();

            try a.track.write(.{ .rate = 16000, .channels = .mono }, &.{ 32767, -32768 });
            try b.track.write(.{ .rate = 16000, .channels = .mono }, &.{ 32767, -32768 });

            var out: [2]i16 = undefined;
            const n = mixer.read(&out) orelse unreachable;
            try grt.std.testing.expectEqual(@as(usize, 2), n);
            try grt.std.testing.expect(out[0] > 30000);
            try grt.std.testing.expect(out[0] <= 32767);
            try grt.std.testing.expect(out[1] < -30000);
            try grt.std.testing.expect(out[1] >= -32768);
        }

        fn defaultBackendDrainsAfterCloseWrite() !void {
            const mixer = try MixerType.init(.{
                .allocator = grt.std.testing.allocator,
                .output = .{ .rate = 8000, .channels = .mono },
            });
            defer mixer.deinit();

            const handle = try mixer.createTrack(.{});
            defer handle.track.deinit();
            defer handle.ctrl.deinit();

            try handle.track.write(.{ .rate = 8000, .channels = .mono }, &.{ 7, 8 });
            mixer.closeWrite();

            var out: [4]i16 = undefined;
            try grt.std.testing.expectEqual(@as(?usize, 2), mixer.read(&out));
            try grt.std.testing.expectEqual(@as(?usize, null), mixer.read(&out));
        }

        fn defaultBackendRejectsCreateAfterMixerCloseWrite() !void {
            const mixer = try MixerType.init(.{
                .allocator = grt.std.testing.allocator,
                .output = .{ .rate = 8000, .channels = .mono },
            });
            defer mixer.deinit();

            mixer.closeWrite();
            try grt.std.testing.expectError(error.Closed, mixer.createTrack(.{}));
        }

        fn defaultBackendCloseIsTerminalWithoutErrorPath() !void {
            const mixer = try MixerType.init(.{
                .allocator = grt.std.testing.allocator,
                .output = .{ .rate = 8000, .channels = .mono },
            });
            defer mixer.deinit();

            const handle = try mixer.createTrack(.{});
            defer handle.track.deinit();
            defer handle.ctrl.deinit();

            try handle.track.write(.{ .rate = 8000, .channels = .mono }, &.{ 1, 2 });
            mixer.close();

            var out: [4]i16 = undefined;
            try grt.std.testing.expectEqual(@as(?usize, null), mixer.read(&out));
            try grt.std.testing.expectError(error.Closed, mixer.createTrack(.{}));
        }

        fn defaultBackendLastHandleDropClosesTrackAndPreservesBufferedAudio() !void {
            const mixer = try MixerType.init(.{
                .allocator = grt.std.testing.allocator,
                .output = .{ .rate = 8000, .channels = .mono },
            });
            defer mixer.deinit();

            var handle = try mixer.createTrack(.{});
            try handle.track.write(.{ .rate = 8000, .channels = .mono }, &.{ 4, 5 });
            handle.track.deinit();
            handle.ctrl.deinit();

            var out: [4]i16 = undefined;
            try grt.std.testing.expectEqual(@as(?usize, 2), mixer.read(&out));
            try grt.std.testing.expectEqualSlices(i16, &.{ 2, 2 }, out[0..2]);
            try grt.std.testing.expectEqual(@as(?usize, 0), mixer.read(&out));
        }

        fn defaultBackendOverflowingSilenceTailFallsBackToCloseWrite() !void {
            const max_u32 = grt.std.math.maxInt(u32);
            const max_duration = glib.time.duration.Maximum;
            const mixer = try MixerType.init(.{
                .allocator = grt.std.testing.allocator,
                .output = .{ .rate = max_u32, .channels = .stereo },
            });
            defer mixer.deinit();

            const handle = try mixer.createTrack(.{});
            defer handle.track.deinit();
            defer handle.ctrl.deinit();

            try handle.track.write(.{ .rate = max_u32, .channels = .stereo }, &.{ 1, 2 });
            handle.ctrl.closeWriteWithSilence(max_duration);

            var out: [8]i16 = undefined;
            const n = mixer.read(&out) orelse unreachable;
            try grt.std.testing.expectEqual(@as(usize, 2), n);
            try grt.std.testing.expectEqualSlices(i16, &.{ 0, 1 }, out[0..2]);
            try grt.std.testing.expectEqual(@as(?usize, 0), mixer.read(&out));
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

            TestCase.exposesSurface();
            TestCase.defaultBackendHappyPath() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.defaultBackendMixesGain() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.defaultBackendSoftLimitsFullScaleMix() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.defaultBackendDrainsAfterCloseWrite() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.defaultBackendRejectsCreateAfterMixerCloseWrite() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.defaultBackendCloseIsTerminalWithoutErrorPath() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.defaultBackendLastHandleDropClosesTrackAndPreservesBufferedAudio() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.defaultBackendOverflowingSilenceTailFallsBackToCloseWrite() catch |err| {
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
