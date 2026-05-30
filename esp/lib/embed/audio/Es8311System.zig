const embed = @import("embed_core");
const esp = @import("esp");
const EspAudio = @import("../audio.zig");
const EspSrAfe = @import("EspSrAfe.zig");
const native = @import("es8311_binding.zig");

const Es8311 = embed.drivers.audio.Es8311;
const I2c = esp.embed.I2c;

pub const GainTableFunc = *const fn (gain_db: i8) i8;

pub const I2sConfig = struct {
    port: i32,
    mclk_gpio: i32,
    bclk_gpio: i32,
    ws_gpio: i32,
    dout_gpio: i32,
    din_gpio: i32,
};

pub const CodecConfig = struct {
    address: u7 = @intFromEnum(Es8311.Address.ad0_low),
};

pub const CaptureConfig = struct {
    raw_channel_count: usize = 2,
    mic_lane: u8 = 0,
    ref_lane: u8 = 1,
};

pub const I2sMicChannelConfig = struct {
    slot: usize,
    sample_align: MicI2sSampleAlign = .lsb,
};

pub const MicI2sSampleAlign = enum {
    lsb,
    msb,
};

pub const I2sSpeakerSlotConfig = struct {
    index: usize,
    sample_align: SpeakerI2sSampleAlign = .lsb,
};

pub const SpeakerI2sSampleAlign = enum {
    lsb,
    msb,
};

pub const I2sAdapterConfig = struct {
    pub const Rx = struct {
        slots_per_frame: usize = 2,
        bytes_per_slot: usize = @sizeOf(i16),
        mic_channel: I2sMicChannelConfig = .{ .slot = 0 },
        ref_channel: I2sMicChannelConfig = .{ .slot = 1 },
    };

    pub const Tx = struct {
        slots_per_frame: usize = 2,
        bytes_per_slot: usize = @sizeOf(i16),
        speaker_slots: []const I2sSpeakerSlotConfig = &defaultTxSlots,
    };

    rx: Rx = .{},
    tx: Tx = .{},
};

const defaultTxSlots = [_]I2sSpeakerSlotConfig{
    .{ .index = 0 },
    .{ .index = 1 },
};

pub const Options = struct {
    sample_rate: u32 = 16_000,
    frame_samples_per_channel: usize = 256,
    i2c: I2c.Config,
    i2s: I2sConfig,
    es8311: CodecConfig = .{},
    capture: CaptureConfig = .{},
    default_volume: u8 = 0xb0,
    default_mic_gain_db: i8 = 24,
    speaker_gain_table_func: ?GainTableFunc = null,
    mic_gain_table_func: ?GainTableFunc = null,
    esp_sr: EspSrAfe.Options = .{},
    i2s_adapters: I2sAdapterConfig = .{},
};

pub fn make(comptime options: Options) type {
    if (options.frame_samples_per_channel == 0) {
        @compileError("Es8311System requires non-zero frame_samples_per_channel");
    }
    if (options.capture.raw_channel_count == 0) {
        @compileError("Es8311System requires non-zero raw_channel_count");
    }
    if (options.capture.mic_lane >= options.capture.raw_channel_count) {
        @compileError("Es8311System mic_lane must fit raw_channel_count");
    }
    if (options.capture.ref_lane >= options.capture.raw_channel_count) {
        @compileError("Es8311System ref_lane must fit raw_channel_count");
    }
    if (options.capture.ref_lane == options.capture.mic_lane) {
        @compileError("Es8311System ref_lane must differ from mic_lane");
    }
    if (options.i2s_adapters.rx.slots_per_frame == 0) {
        @compileError("Es8311System requires non-zero rx slots_per_frame");
    }
    if (options.i2s_adapters.rx.bytes_per_slot == 0) {
        @compileError("Es8311System requires non-zero rx bytes_per_slot");
    }
    if (options.i2s_adapters.tx.slots_per_frame == 0) {
        @compileError("Es8311System requires non-zero tx slots_per_frame");
    }
    if (options.i2s_adapters.tx.bytes_per_slot == 0) {
        @compileError("Es8311System requires non-zero tx bytes_per_slot");
    }
    if (options.i2s_adapters.rx.mic_channel.slot >= options.i2s_adapters.rx.slots_per_frame) {
        @compileError("Es8311System mic_channel slot must fit rx slots_per_frame");
    }
    if (options.i2s_adapters.rx.ref_channel.slot >= options.i2s_adapters.rx.slots_per_frame) {
        @compileError("Es8311System ref_channel slot must fit rx slots_per_frame");
    }
    if (options.i2s_adapters.tx.speaker_slots.len == 0) {
        @compileError("Es8311System requires at least one speaker slot");
    }
    for (options.i2s_adapters.tx.speaker_slots) |slot| {
        if (slot.index >= options.i2s_adapters.tx.slots_per_frame) {
            @compileError("Es8311System speaker slot must fit tx slots_per_frame");
        }
    }

    return struct {
        const Self = @This();
        const log = esp.grt.std.log.scoped(.esp_es8311_audio_system);

        pub const sample_rate = options.sample_rate;
        pub const mic_count = 1;
        pub const frame_samples_per_channel = options.frame_samples_per_channel;
        pub const Mic = embed.audio.Mic.make(esp.grt, mic_count, frame_samples_per_channel);
        pub const Speaker = embed.audio.Speaker.make(esp.grt, frame_samples_per_channel);
        pub const Processor = EspSrAfe.Processor(Mic, .{
            .sample_rate_hz = options.sample_rate,
            .mic_count = mic_count,
            .ref_count = 1,
            .options = options.esp_sr,
        });
        pub const Type = blk: {
            var builder = embed.audio.AudioSystem.Builder(esp.grt).init();
            builder.configMic(mic_count, frame_samples_per_channel);
            builder.configSpeaker(frame_samples_per_channel);
            builder.setProcessor(&Processor.process);
            break :blk builder.build();
        };
        const tx_slots = speakerSlots();
        const tx_channels = [_]Speaker.I2s.Channel{
            .{ .slots = &tx_slots },
        };

        allocator: esp.grt.std.mem.Allocator,
        state: *State,
        core: Type,

        pub fn init(allocator: esp.grt.std.mem.Allocator, config: Type.Config) !Self {
            const state = try allocator.create(State);
            errdefer allocator.destroy(state);
            state.* = State.init();
            errdefer state.deinit();

            var core = try Type.init(allocator, config);
            errdefer core.deinit();

            try state.ensureInitialized();
            try state.ensureI2sAdapters(allocator);
            var mic = state.i2s_mic.?.mic();
            mic.setGainTableFunc(options.mic_gain_table_func);
            try core.setMic(mic);
            var speaker = state.speaker.?.driver();
            speaker.setGainTableFunc(options.speaker_gain_table_func);
            try core.setSpeaker(speaker);

            return .{
                .allocator = allocator,
                .state = state,
                .core = core,
            };
        }

        pub fn deinit(self: *Self) void {
            self.core.deinit();
            self.state.deinit();
            self.allocator.destroy(self.state);
            self.* = undefined;
        }

        pub fn system(self: *Self) *Type {
            return &self.core;
        }

        const State = struct {
            bus: I2c.MasterBus,
            codec: ?Es8311 = null,
            initialized: bool = false,
            native_i2s: NativeI2s = .{},
            rx_stream: ?embed.drivers.I2s = null,
            tx_stream: ?embed.drivers.I2s = null,
            i2s_mic: ?Mic.I2s = null,
            i2s_speaker: ?Speaker.I2s = null,
            speaker: ?SpeakerDevice = null,

            fn init() State {
                return .{
                    .bus = I2c.MasterBus.init(options.i2c),
                };
            }

            fn deinit(self: *State) void {
                if (self.tx_stream) |*stream| {
                    stream.deinit();
                    self.tx_stream = null;
                }
                if (self.rx_stream) |*stream| {
                    stream.deinit();
                    self.rx_stream = null;
                }
                if (self.codec) |*codec| {
                    codec.close() catch |err| log.warn("es8311 close failed: {s}", .{@errorName(err)});
                }
                Processor.deinit();
                native.espz_es8311_audio_deinit();
                self.bus.deinit();
                self.* = undefined;
            }

            fn ensureInitialized(self: *State) embed.audio.AudioSystem.Error!void {
                if (self.initialized) return;

                const native_config = nativeConfig();
                try checkNative("espz_es8311_audio_configure", native.espz_es8311_audio_configure(&native_config));
                try checkNative("espz_es8311_audio_init", native.espz_es8311_audio_init());

                self.bus.open() catch |err| return fail("i2c open", err);

                const codec_i2c = self.bus.device(options.es8311.address) catch |err| return fail("es8311 i2c device", err);
                var codec = Es8311.init(codec_i2c, .{
                    .address = options.es8311.address,
                    .codec_mode = .both,
                    .disable_dac_ref = false,
                });
                codec.open() catch |err| return fail("es8311 open", err);
                const chip_id = codec.readChipId() catch |err| return fail("es8311 read chip id", err);
                log.info("es8311 chip_id=0x{x}", .{chip_id});
                codec.setSampleRate(sample_rate) catch |err| return fail("es8311 sample rate", err);
                codec.setBitsPerSample(.@"16bit") catch |err| return fail("es8311 bits", err);
                codec.setFormat(.i2s) catch |err| return fail("es8311 format", err);
                codec.setMicGainDb(options.default_mic_gain_db) catch |err| return fail("es8311 mic gain", err);
                codec.enable(true) catch |err| return fail("es8311 enable", err);
                codec.setVolume(options.default_volume) catch |err| return fail("es8311 volume", err);
                codec.setMute(false) catch |err| return fail("es8311 unmute", err);

                self.codec = codec;
                try Processor.init();
                try checkNative("espz_es8311_audio_mic_capture_start", native.espz_es8311_audio_mic_capture_start());
                try Processor.reset();
                self.initialized = true;
            }

            fn ensureI2sAdapters(self: *State, allocator: esp.grt.std.mem.Allocator) embed.audio.AudioSystem.Error!void {
                if (self.i2s_mic != null and self.i2s_speaker != null) return;
                try self.ensureInitialized();

                if (self.rx_stream == null) {
                    self.rx_stream = embed.drivers.I2s.init(allocator, &self.native_i2s, .{
                        .slots_per_frame = options.i2s_adapters.rx.slots_per_frame,
                        .bytes_per_slot = options.i2s_adapters.rx.bytes_per_slot,
                        .buffer_frame_count = frame_samples_per_channel,
                    }) catch |err| return fail("rx i2s init", err);
                }
                if (self.tx_stream == null) {
                    self.tx_stream = embed.drivers.I2s.init(allocator, &self.native_i2s, .{
                        .slots_per_frame = options.i2s_adapters.tx.slots_per_frame,
                        .bytes_per_slot = options.i2s_adapters.tx.bytes_per_slot,
                        .buffer_frame_count = frame_samples_per_channel,
                    }) catch |err| return fail("tx i2s init", err);
                }

                self.i2s_mic = Mic.i2s(.{
                    .stream = &self.rx_stream.?,
                    .sample_rate = sample_rate,
                    .mic_channels = .{micChannel(options.i2s_adapters.rx.mic_channel)},
                    .ref_channel = micChannel(options.i2s_adapters.rx.ref_channel),
                    .gains_db = .{options.default_mic_gain_db},
                });
                self.i2s_speaker = Speaker.i2s(.{
                    .stream = &self.tx_stream.?,
                    .sample_rate = sample_rate,
                    .channels = &tx_channels,
                });
                self.speaker = .{ .state = self };
            }

            fn setVolume(self: *State, volume: u8) embed.audio.AudioSystem.Error!void {
                try self.ensureInitialized();
                if (self.codec) |*codec| {
                    codec.setVolume(volume) catch |err| return fail("es8311 volume", err);
                    return;
                }
                return error.InvalidState;
            }

            fn setMicrophoneGain(self: *State, gain_db: i8) embed.audio.AudioSystem.Error!void {
                try self.ensureInitialized();
                if (self.codec) |*codec| {
                    codec.setMicGainDb(gain_db) catch |err| return fail("es8311 mic gain", err);
                    return;
                }
                return error.InvalidState;
            }
        };

        const SpeakerDevice = struct {
            state: *State,
            gain_db: ?i8 = null,

            fn driver(self: *SpeakerDevice) Speaker {
                return Speaker.init(self, &speaker_vtable);
            }

            fn deinit(_: *SpeakerDevice) void {}

            fn sampleRate(self: *SpeakerDevice) u32 {
                const speaker = self.state.i2s_speaker.?.speaker();
                return speaker.sampleRate();
            }

            fn write(self: *SpeakerDevice, frame: []const i16) embed.audio.AudioSystem.Error!usize {
                const speaker = self.state.i2s_speaker.?.speaker();
                return speaker.write(frame);
            }

            fn gain(self: *SpeakerDevice) ?i8 {
                return self.gain_db;
            }

            fn setGain(self: *SpeakerDevice, gain_db: i8) embed.audio.AudioSystem.Error!void {
                try self.state.setVolume(EspAudio.gainDbToVolume(gain_db));
                self.gain_db = gain_db;
            }

            fn enable(self: *SpeakerDevice) embed.audio.AudioSystem.Error!void {
                const speaker = self.state.i2s_speaker.?.speaker();
                return speaker.enable();
            }

            fn disable(self: *SpeakerDevice) embed.audio.AudioSystem.Error!void {
                const speaker = self.state.i2s_speaker.?.speaker();
                return speaker.disable();
            }
        };

        const speaker_vtable = Speaker.VTable{
            .deinit = speakerDeinit,
            .sampleRate = speakerSampleRate,
            .write = speakerWrite,
            .gain = speakerGain,
            .setGain = speakerSetGain,
            .enable = speakerEnable,
            .disable = speakerDisable,
        };

        const NativeI2s = struct {
            pub fn write(_: *NativeI2s, data: []const u8) embed.drivers.I2s.Error!usize {
                if (data.len == 0) return 0;
                var bytes_written: usize = 0;
                try checkI2sNative(native.espz_es8311_audio_write_raw(data.ptr, data.len, &bytes_written));
                return bytes_written;
            }

            pub fn read(_: *NativeI2s, buf: []u8) embed.drivers.I2s.Error!usize {
                if (buf.len == 0) return 0;
                var bytes_read: usize = 0;
                try checkI2sNative(native.espz_es8311_audio_read_raw(buf.ptr, buf.len, &bytes_read));
                return bytes_read;
            }
        };

        fn nativeConfig() native.Config {
            return .{
                .i2s_port = options.i2s.port,
                .sample_rate_hz = options.sample_rate,
                .mclk_gpio = options.i2s.mclk_gpio,
                .bclk_gpio = options.i2s.bclk_gpio,
                .ws_gpio = options.i2s.ws_gpio,
                .dout_gpio = options.i2s.dout_gpio,
                .din_gpio = options.i2s.din_gpio,
                .mono_chunk_samples = options.frame_samples_per_channel,
                .rx_channel_count = options.capture.raw_channel_count,
                .mic_lane = options.capture.mic_lane,
                .ref_lane = options.capture.ref_lane,
            };
        }

        fn micChannel(channel: I2sMicChannelConfig) Mic.I2s.Channel {
            return .{
                .slot = channel.slot,
                .sample_align = micSampleAlign(channel.sample_align),
            };
        }

        fn speakerSlots() [options.i2s_adapters.tx.speaker_slots.len]Speaker.I2s.Slot {
            var slots: [options.i2s_adapters.tx.speaker_slots.len]Speaker.I2s.Slot = undefined;
            for (options.i2s_adapters.tx.speaker_slots, 0..) |slot, index| {
                slots[index] = .{
                    .index = slot.index,
                    .sample_align = speakerSampleAlign(slot.sample_align),
                };
            }
            return slots;
        }

        fn micSampleAlign(sample_align: MicI2sSampleAlign) Mic.I2s.SampleAlign {
            return switch (sample_align) {
                .lsb => .lsb,
                .msb => .msb,
            };
        }

        fn speakerSampleAlign(sample_align: SpeakerI2sSampleAlign) Speaker.I2s.SampleAlign {
            return switch (sample_align) {
                .lsb => .lsb,
                .msb => .msb,
            };
        }

        fn speakerDeinit(ptr: *anyopaque) void {
            const self: *SpeakerDevice = @ptrCast(@alignCast(ptr));
            self.deinit();
        }

        fn speakerSampleRate(ptr: *anyopaque) u32 {
            const self: *SpeakerDevice = @ptrCast(@alignCast(ptr));
            return self.sampleRate();
        }

        fn speakerWrite(ptr: *anyopaque, frame: []const i16) embed.audio.AudioSystem.Error!usize {
            const self: *SpeakerDevice = @ptrCast(@alignCast(ptr));
            return self.write(frame);
        }

        fn speakerGain(ptr: *anyopaque) ?i8 {
            const self: *SpeakerDevice = @ptrCast(@alignCast(ptr));
            return self.gain();
        }

        fn speakerSetGain(ptr: *anyopaque, gain_db: i8) embed.audio.AudioSystem.Error!void {
            const self: *SpeakerDevice = @ptrCast(@alignCast(ptr));
            return self.setGain(gain_db);
        }

        fn speakerEnable(ptr: *anyopaque) embed.audio.AudioSystem.Error!void {
            const self: *SpeakerDevice = @ptrCast(@alignCast(ptr));
            return self.enable();
        }

        fn speakerDisable(ptr: *anyopaque) embed.audio.AudioSystem.Error!void {
            const self: *SpeakerDevice = @ptrCast(@alignCast(ptr));
            return self.disable();
        }

        fn checkNative(name: []const u8, rc: c_int) embed.audio.AudioSystem.Error!void {
            if (rc == native.esp_ok) return;
            log.err("{s} failed with rc={d}", .{ name, rc });
            return error.Unexpected;
        }

        fn checkI2sNative(rc: c_int) embed.drivers.I2s.Error!void {
            if (rc == native.esp_ok) return;
            return error.BusError;
        }

        fn fail(name: []const u8, err: anyerror) embed.audio.AudioSystem.Error {
            log.err("{s} failed: {s}", .{ name, @errorName(err) });
            return error.Unexpected;
        }
    };
}
