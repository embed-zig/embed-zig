const embed = @import("embed");
const glib = @import("glib");
const gstd = @import("gstd");
const portaudio = @import("portaudio");
const speexdsp = @import("speexdsp");

const audio = embed.audio;
const grt = gstd.runtime;

const sample_rate: u32 = 16_000;
const samples_per_channel: usize = 320;
const mic_count: usize = 1;
const echo_filter_samples: usize = samples_per_channel * 10;

const Builder = audio.AudioSystem.Builder(grt);
const Mic = audio.Mic.make(grt, mic_count, samples_per_channel);
const Speaker = audio.Speaker.make(grt, samples_per_channel);
const BuiltAudioSystem = blk: {
    var builder = Builder.init();
    builder.configMic(mic_count, samples_per_channel);
    builder.configSpeaker(samples_per_channel);
    builder.setProcessor(&SpeexProcessor.process);
    break :blk builder.build();
};

pub const AudioSystem = struct {
    pub const TrackHandle = audio.AudioSystem.TrackHandle;
    pub const Track = audio.AudioSystem.Track;
    pub const TrackCtrl = audio.AudioSystem.TrackCtrl;
    pub const Format = audio.AudioSystem.Format;
    pub const State = struct {
        started: bool = false,
        start_count: usize = 0,
        stop_count: usize = 0,
        created_tracks: usize = 0,
        writes: usize = 0,
        reads: usize = 0,
        discard_read_count: usize = 0,
        sample_rate_requests: usize = 0,
        gain_db: i8 = 0,
        last_write_rate: u32 = 0,
        last_write_samples: usize = 0,
    };

    allocator: glib.std.mem.Allocator,
    inner: BuiltAudioSystem,
    pa: portaudio.PortAudio = .{},
    mic_backend: PortAudioMic = .{},
    speaker_backend: PortAudioSpeaker = .{},
    configured: bool = false,
    state_mu: grt.sync.Mutex = .{},
    state: State = .{},

    pub fn init(allocator: glib.std.mem.Allocator) !AudioSystem {
        return .{
            .allocator = allocator,
            .inner = try BuiltAudioSystem.init(allocator, .{}),
        };
    }

    pub fn deinit(self: *AudioSystem) void {
        self.inner.deinit();
        self.pa.deinit() catch {};
        SpeexProcessor.deinit();
        self.* = undefined;
    }

    pub fn start(self: *AudioSystem) !void {
        try self.ensureConfigured();
        try self.inner.start();

        self.state_mu.lock();
        defer self.state_mu.unlock();
        self.state.started = true;
        self.state.start_count += 1;
    }

    pub fn stop(self: *AudioSystem) !void {
        try self.inner.stop();

        self.state_mu.lock();
        defer self.state_mu.unlock();
        self.state.started = false;
        self.state.stop_count += 1;
    }

    pub fn createTrack(self: *AudioSystem, config: audio.Mixer.Track.Config) !TrackHandle {
        try self.ensureConfigured();
        const handle = try self.inner.createTrack(config);

        self.state_mu.lock();
        defer self.state_mu.unlock();
        self.state.created_tracks += 1;
        return handle;
    }

    pub fn read(self: *AudioSystem, out: []i16) !usize {
        try self.ensureConfigured();
        const n = try self.inner.read(out);

        self.state_mu.lock();
        defer self.state_mu.unlock();
        self.state.reads += 1;
        return n;
    }

    pub fn discardReadBuffer(self: *AudioSystem) void {
        self.inner.discardReadBuffer();

        self.state_mu.lock();
        defer self.state_mu.unlock();
        self.state.discard_read_count += 1;
    }

    pub fn setSpkGain(self: *AudioSystem, gain_db: i8) !void {
        try self.ensureConfigured();
        try self.inner.setSpkGain(gain_db);

        self.state_mu.lock();
        defer self.state_mu.unlock();
        self.state.gain_db = gain_db;
    }

    pub fn spkSampleRate(self: *AudioSystem) !u32 {
        try self.ensureConfigured();

        self.state_mu.lock();
        defer self.state_mu.unlock();
        self.state.sample_rate_requests += 1;
        return try self.inner.spkSampleRate();
    }

    fn ensureConfigured(self: *AudioSystem) !void {
        if (self.configured) return;

        if (!self.pa.initialized) {
            self.pa = portaudio.PortAudio.init() catch return error.Unexpected;
        }

        self.mic_backend.configure(&self.pa);
        self.speaker_backend.configure(&self.pa);
        try self.inner.setMic(Mic.init(&self.mic_backend, &PortAudioMic.vtable));
        try self.inner.setSpeaker(Speaker.init(&self.speaker_backend, &PortAudioSpeaker.vtable));
        self.configured = true;
    }
};

const PortAudioMic = struct {
    pa: ?*portaudio.PortAudio = null,
    stream: ?portaudio.Stream = null,
    gain_db: ?i8 = null,
    mu: grt.sync.Mutex = .{},

    fn configure(self: *PortAudioMic, pa: *portaudio.PortAudio) void {
        self.pa = pa;
    }

    fn deinit(ptr: *anyopaque) void {
        disable(ptr) catch {};
    }

    fn sampleRate(_: *anyopaque) u32 {
        return sample_rate;
    }

    fn micCount(_: *anyopaque) u8 {
        return mic_count;
    }

    fn read(ptr: *anyopaque, frame: *Mic.Frame) audio.AudioSystem.Error!void {
        const self: *PortAudioMic = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();

        var stream = &(self.stream orelse return error.InvalidState);
        stream.read(frame.mic[0][0..], samples_per_channel) catch |err| switch (err) {
            error.InputOverflowed => @memset(frame.mic[0][0..], 0),
            else => return mapPortAudioError(err),
        };
        frame.ref = null;
    }

    fn gains(ptr: *anyopaque) Mic.Gains {
        const self: *PortAudioMic = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();
        return .{self.gain_db};
    }

    fn setGains(ptr: *anyopaque, gains_db: []const ?i8) audio.AudioSystem.Error!void {
        const self: *PortAudioMic = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();
        if (gains_db.len > 0) self.gain_db = gains_db[0];
    }

    fn enable(ptr: *anyopaque) audio.AudioSystem.Error!void {
        const self: *PortAudioMic = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();
        if (self.stream != null) return;

        const pa = self.pa orelse return error.InvalidState;
        const device = pa.defaultInputDevice() catch |err| return mapPortAudioError(err);
        const input = device orelse return error.Unsupported;
        var stream = pa.openInputStream(.{
            .device = input.index,
            .channel_count = mic_count,
            .sample_format = .int16,
            .suggested_latency = input.defaultLowInputLatency(),
        }, sample_rate, samples_per_channel, 0) catch |err| return mapPortAudioError(err);
        errdefer stream.deinit() catch {};
        stream.start() catch |err| return mapPortAudioError(err);
        self.stream = stream;
    }

    fn disable(ptr: *anyopaque) audio.AudioSystem.Error!void {
        const self: *PortAudioMic = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();

        if (self.stream) |*stream| {
            stream.stop() catch {};
            stream.deinit() catch {};
            self.stream = null;
        }
    }

    const vtable = Mic.VTable{
        .deinit = deinit,
        .sampleRate = sampleRate,
        .micCount = micCount,
        .read = read,
        .gains = gains,
        .setGains = setGains,
        .enable = enable,
        .disable = disable,
    };
};

const PortAudioSpeaker = struct {
    pa: ?*portaudio.PortAudio = null,
    stream: ?portaudio.Stream = null,
    gain_db: ?i8 = null,
    scratch: [samples_per_channel]i16 = @splat(0),
    mu: grt.sync.Mutex = .{},

    fn configure(self: *PortAudioSpeaker, pa: *portaudio.PortAudio) void {
        self.pa = pa;
    }

    fn deinit(ptr: *anyopaque) void {
        disable(ptr) catch {};
    }

    fn sampleRate(_: *anyopaque) u32 {
        return sample_rate;
    }

    fn write(ptr: *anyopaque, frame: []const i16) audio.AudioSystem.Error!usize {
        const self: *PortAudioSpeaker = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();

        var stream = &(self.stream orelse return error.InvalidState);
        const n = @min(frame.len, self.scratch.len);
        copyWithGain(self.scratch[0..n], frame[0..n], self.gain_db orelse 0);
        stream.write(self.scratch[0..n], n) catch |err| switch (err) {
            error.OutputUnderflowed => {},
            else => return mapPortAudioError(err),
        };
        return n;
    }

    fn gain(ptr: *anyopaque) ?i8 {
        const self: *PortAudioSpeaker = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();
        return self.gain_db;
    }

    fn setGain(ptr: *anyopaque, gain_db: i8) audio.AudioSystem.Error!void {
        const self: *PortAudioSpeaker = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();
        self.gain_db = gain_db;
    }

    fn enable(ptr: *anyopaque) audio.AudioSystem.Error!void {
        const self: *PortAudioSpeaker = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();
        if (self.stream != null) return;

        const pa = self.pa orelse return error.InvalidState;
        const device = pa.defaultOutputDevice() catch |err| return mapPortAudioError(err);
        const output = device orelse return error.Unsupported;
        var stream = pa.openOutputStream(.{
            .device = output.index,
            .channel_count = 1,
            .sample_format = .int16,
            .suggested_latency = output.defaultLowOutputLatency(),
        }, sample_rate, samples_per_channel, 0) catch |err| return mapPortAudioError(err);
        errdefer stream.deinit() catch {};
        stream.start() catch |err| return mapPortAudioError(err);
        self.stream = stream;
    }

    fn disable(ptr: *anyopaque) audio.AudioSystem.Error!void {
        const self: *PortAudioSpeaker = @ptrCast(@alignCast(ptr));
        self.mu.lock();
        defer self.mu.unlock();

        if (self.stream) |*stream| {
            stream.stop() catch {};
            stream.deinit() catch {};
            self.stream = null;
        }
    }

    const vtable = Speaker.VTable{
        .deinit = deinit,
        .sampleRate = sampleRate,
        .write = write,
        .gain = gain,
        .setGain = setGain,
        .enable = enable,
        .disable = disable,
    };
};

const SpeexProcessor = struct {
    var mu: grt.sync.Mutex = .{};
    var initialized: bool = false;
    var echo: speexdsp.EchoState = undefined;
    var preprocess: speexdsp.PreprocessState = undefined;

    fn process(frame: Mic.Frame, out: []i16) audio.AudioSystem.Error!usize {
        if (out.len < samples_per_channel) return error.InvalidState;

        mu.lock();
        defer mu.unlock();
        try ensureInitialized();

        const ref = frame.ref orelse [_]i16{0} ** samples_per_channel;
        echo.cancellation(frame.mic[0][0..], ref[0..], out[0..samples_per_channel]) catch return error.Unexpected;
        _ = preprocess.run(out[0..samples_per_channel]) catch return error.Unexpected;
        return samples_per_channel;
    }

    fn deinit() void {
        mu.lock();
        defer mu.unlock();
        if (!initialized) return;
        preprocess.clearEchoState() catch {};
        preprocess.deinit();
        echo.deinit();
        initialized = false;
    }

    fn ensureInitialized() audio.AudioSystem.Error!void {
        if (initialized) return;

        echo = speexdsp.EchoState.init(samples_per_channel, echo_filter_samples) catch return error.Unexpected;
        errdefer echo.deinit();
        echo.setSamplingRate(sample_rate) catch return error.Unexpected;
        preprocess = speexdsp.PreprocessState.init(samples_per_channel, sample_rate) catch return error.Unexpected;
        errdefer preprocess.deinit();
        preprocess.setDenoise(true) catch return error.Unexpected;
        preprocess.setNoiseSuppress(-30) catch return error.Unexpected;
        preprocess.setEchoSuppress(-45) catch return error.Unexpected;
        preprocess.setEchoSuppressActive(-15) catch return error.Unexpected;
        preprocess.setEchoState(&echo) catch return error.Unexpected;
        initialized = true;
    }
};

fn mapPortAudioError(err: portaudio.Error) audio.AudioSystem.Error {
    return switch (err) {
        error.InputOverflowed, error.OutputUnderflowed => error.Overflow,
        error.StreamIsStopped, error.StreamIsNotStopped, error.NotInitialized => error.InvalidState,
        error.DeviceUnavailable,
        error.InvalidDevice,
        error.InvalidChannelCount,
        error.InvalidSampleRate,
        error.SampleFormatNotSupported,
        error.BadIODeviceCombination,
        => error.Unsupported,
        error.TimedOut => error.Timeout,
        else => error.Unexpected,
    };
}

fn copyWithGain(out: []i16, input: []const i16, gain_db: i8) void {
    const gain = gainLinear(gain_db);
    for (out, input) |*dst, src| {
        const scaled = @as(f32, @floatFromInt(src)) * gain;
        dst.* = clampSample(scaled);
    }
}

fn gainLinear(gain_db: i8) f32 {
    if (gain_db == 0) return 1.0;
    return @import("std").math.pow(f32, 10.0, @as(f32, @floatFromInt(gain_db)) / 20.0);
}

fn clampSample(value: f32) i16 {
    if (value > 32767.0) return 32767;
    if (value < -32768.0) return -32768;
    return @intFromFloat(value);
}

pub fn TestRunner(comptime std: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: std.mem.Allocator) bool {
            _ = self;
            createsLazyPortAudioBackedSystem(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }

        fn createsLazyPortAudioBackedSystem(allocator: std.mem.Allocator) !void {
            var system = try AudioSystem.init(allocator);
            defer system.deinit();

            try std.testing.expectEqual(@as(u32, sample_rate), try system.spkSampleRate());
            try std.testing.expectEqual(@as(usize, 1), system.state.sample_rate_requests);
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
