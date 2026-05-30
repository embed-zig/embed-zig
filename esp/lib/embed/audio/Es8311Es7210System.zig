const embed = @import("embed_core");
const esp = @import("esp");
const EspAudio = @import("../audio.zig");
const EspSrAfe = @import("EspSrAfe.zig");
const native = @import("es8311_es7210_binding.zig");

const Es7210 = embed.drivers.audio.Es7210;
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

pub const I2sDataBitWidth = enum(i32) {
    @"16bit" = 16,
    @"32bit" = 32,
};

pub const I2sSlotMode = enum(i32) {
    mono = 1,
    stereo = 2,
};

pub const CodecConfig = struct {
    address: u7 = @intFromEnum(Es8311.Address.ad0_low),
};

pub const AdcConfig = struct {
    address: u7 = @intFromEnum(Es7210.Address.ad1_ad0_00),
    mic_select: Es7210.MicSelect = .{ .mic1 = true, .mic2 = true, .mic3 = true, .mic4 = true },
    ref_channel: ?u2 = 0,
};

pub const CaptureConfig = struct {
    raw_channel_count: usize = 4,
    ref_lane: ?u8 = 0,
    mic_lanes: [2]u8 = .{ 1, 3 },
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

pub const I2sSpeakerChannelConfig = struct {
    slots: []const I2sSpeakerSlotConfig,
};

pub const SpeakerI2sSampleAlign = enum {
    lsb,
    msb,
};

pub const I2sAdapterConfig = struct {
    pub const Rx = struct {
        slots_per_frame: usize = 4,
        bytes_per_slot: usize = @sizeOf(i16),
        mic_channels: [2]I2sMicChannelConfig = .{
            .{ .slot = 1 },
            .{ .slot = 3 },
        },
        ref_channel: ?I2sMicChannelConfig = .{ .slot = 0 },
    };

    pub const Tx = struct {
        slots_per_frame: usize = 2,
        bytes_per_slot: usize = @sizeOf(i32),
        speaker_slots: []const I2sSpeakerSlotConfig = &defaultTxSlots,
    };

    rx: Rx = .{},
    tx: Tx = .{},
};

const defaultTxSlots = [_]I2sSpeakerSlotConfig{
    .{ .index = 0, .sample_align = .msb },
    .{ .index = 1, .sample_align = .msb },
};

pub const Options = struct {
    sample_rate: u32 = 16_000,
    frame_samples_per_channel: usize = 256,
    mic_count: usize,
    i2c: I2c.Config,
    i2s: I2sConfig,
    i2s_data_bit_width: I2sDataBitWidth = .@"32bit",
    i2s_slot_mode: I2sSlotMode = .stereo,
    es8311: CodecConfig = .{},
    es7210: AdcConfig = .{},
    capture: CaptureConfig,
    default_volume: u8 = 0xb0,
    default_mic_gain_db: i8 = 24,
    speaker_gain_table_func: ?GainTableFunc = null,
    mic_gain_table_func: ?GainTableFunc = null,
    esp_sr: EspSrAfe.Options = .{},
    use_i2s_adapters: bool = false,
    i2s_adapters: I2sAdapterConfig = .{},
};

pub fn make(comptime options: Options) type {
    if (options.mic_count == 0 or options.mic_count > 2) {
        @compileError("Es8311Es7210System supports one or two AFE mic channels");
    }
    if (options.frame_samples_per_channel == 0) {
        @compileError("Es8311Es7210System requires non-zero frame_samples_per_channel");
    }
    if (options.capture.raw_channel_count == 0) {
        @compileError("Es8311Es7210System requires non-zero raw_channel_count");
    }
    if (options.capture.mic_lanes[0] >= options.capture.raw_channel_count) {
        @compileError("Es8311Es7210System mic0 lane must fit raw_channel_count");
    }
    if (options.mic_count > 1 and options.capture.mic_lanes[1] >= options.capture.raw_channel_count) {
        @compileError("Es8311Es7210System mic1 lane must fit raw_channel_count");
    }
    if (options.capture.ref_lane) |lane| {
        if (lane >= options.capture.raw_channel_count) {
            @compileError("Es8311Es7210System ref lane must fit raw_channel_count");
        }
    }
    if (options.use_i2s_adapters) {
        if (options.i2s_adapters.rx.slots_per_frame == 0) {
            @compileError("Es8311Es7210System requires non-zero rx slots_per_frame");
        }
        if (options.i2s_adapters.rx.bytes_per_slot == 0) {
            @compileError("Es8311Es7210System requires non-zero rx bytes_per_slot");
        }
        if (options.i2s_adapters.tx.slots_per_frame == 0) {
            @compileError("Es8311Es7210System requires non-zero tx slots_per_frame");
        }
        if (options.i2s_adapters.tx.bytes_per_slot == 0) {
            @compileError("Es8311Es7210System requires non-zero tx bytes_per_slot");
        }
        if (options.i2s_adapters.rx.mic_channels[0].slot >= options.i2s_adapters.rx.slots_per_frame) {
            @compileError("Es8311Es7210System mic0 slot must fit rx slots_per_frame");
        }
        if (options.mic_count > 1 and options.i2s_adapters.rx.mic_channels[1].slot >= options.i2s_adapters.rx.slots_per_frame) {
            @compileError("Es8311Es7210System mic1 slot must fit rx slots_per_frame");
        }
        if (options.i2s_adapters.rx.ref_channel) |channel| {
            if (channel.slot >= options.i2s_adapters.rx.slots_per_frame) {
                @compileError("Es8311Es7210System ref slot must fit rx slots_per_frame");
            }
        }
        if (options.i2s_adapters.tx.speaker_slots.len == 0) {
            @compileError("Es8311Es7210System requires at least one speaker slot");
        }
        for (options.i2s_adapters.tx.speaker_slots) |slot| {
            if (slot.index >= options.i2s_adapters.tx.slots_per_frame) {
                @compileError("Es8311Es7210System speaker slot must fit tx slots_per_frame");
            }
        }
    }

    return struct {
        const Self = @This();
        const log = esp.grt.std.log.scoped(.esp_es8311_es7210_audio_system);

        pub const sample_rate = options.sample_rate;
        pub const mic_count = options.mic_count;
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
            if (options.use_i2s_adapters) {
                try state.ensureI2sAdapters(allocator);
                var mic = state.i2s_mic.?.mic();
                mic.setGainTableFunc(options.mic_gain_table_func);
                try core.setMic(mic);
                var speaker = state.speaker_device.driver();
                speaker.setGainTableFunc(options.speaker_gain_table_func);
                try core.setSpeaker(speaker);
            } else {
                var mic = state.mic_device.driver();
                mic.setGainTableFunc(options.mic_gain_table_func);
                try core.setMic(mic);
                var speaker = state.speaker_device.driver();
                speaker.setGainTableFunc(options.speaker_gain_table_func);
                try core.setSpeaker(speaker);
            }

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
            adc: ?Es7210 = null,
            initialized: bool = false,
            native_i2s: NativeI2s = .{},
            rx_stream: ?embed.drivers.I2s = null,
            tx_stream: ?embed.drivers.I2s = null,
            i2s_mic: ?Mic.I2s = null,
            i2s_speaker: ?Speaker.I2s = null,
            mic_device: MicDevice = .{},
            speaker_device: SpeakerDevice = .{},

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
                if (self.adc) |*adc| {
                    adc.close() catch |err| log.warn("es7210 close failed: {s}", .{@errorName(err)});
                }
                if (self.codec) |*codec| {
                    codec.close() catch |err| log.warn("es8311 close failed: {s}", .{@errorName(err)});
                }
                Processor.deinit();
                native.espz_es8311_es7210_audio_deinit();
                self.bus.deinit();
                self.* = undefined;
            }

            fn ensureInitialized(self: *State) embed.audio.AudioSystem.Error!void {
                if (self.initialized) return;

                const native_config = nativeConfig();
                try checkNative("espz_es8311_es7210_audio_configure", native.espz_es8311_es7210_audio_configure(&native_config));
                try checkNative("espz_es8311_es7210_audio_init", native.espz_es8311_es7210_audio_init());

                self.bus.open() catch |err| return fail("i2c open", err);

                const codec_i2c = self.bus.device(options.es8311.address) catch |err| return fail("es8311 i2c device", err);
                var codec = Es8311.init(codec_i2c, .{
                    .address = options.es8311.address,
                    .codec_mode = .dac_only,
                });
                codec.open() catch |err| return fail("es8311 open", err);
                const chip_id = codec.readChipId() catch |err| return fail("es8311 read chip id", err);
                log.info("es8311 chip_id=0x{x}", .{chip_id});
                codec.setSampleRate(sample_rate) catch |err| return fail("es8311 sample rate", err);
                codec.setBitsPerSample(.@"16bit") catch |err| return fail("es8311 bits", err);
                codec.setFormat(.i2s) catch |err| return fail("es8311 format", err);
                codec.enable(true) catch |err| return fail("es8311 enable", err);
                codec.setVolume(options.default_volume) catch |err| return fail("es8311 volume", err);
                codec.setMute(false) catch |err| return fail("es8311 unmute", err);

                const adc_i2c = self.bus.device(options.es7210.address) catch |err| return fail("es7210 i2c device", err);
                var adc = Es7210.init(adc_i2c, .{
                    .address = options.es7210.address,
                    .mic_select = options.es7210.mic_select,
                });
                adc.open() catch |err| return fail("es7210 open", err);
                adc.enable(true) catch |err| return fail("es7210 enable", err);
                adc.setGainAll(microphoneGainFromDb(options.default_mic_gain_db)) catch |err| return fail("es7210 gain", err);
                if (options.es7210.ref_channel) |ref_channel| {
                    adc.setChannelGain(ref_channel, .@"0dB") catch |err| return fail("es7210 ref gain", err);
                }

                self.codec = codec;
                self.adc = adc;
                try Processor.init();
                try checkNative("espz_es8311_es7210_audio_mic_capture_start", native.espz_es8311_es7210_audio_mic_capture_start());
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
                    .mic_channels = micChannels(),
                    .ref_channel = i2sRefChannel(),
                    .gains_db = [_]?i8{options.default_mic_gain_db} ** mic_count,
                });
                self.i2s_speaker = Speaker.i2s(.{
                    .stream = &self.tx_stream.?,
                    .sample_rate = sample_rate,
                    .channels = &tx_channels,
                });
            }

            fn writePcm(self: *State, samples: []const i16) embed.audio.AudioSystem.Error!void {
                if (samples.len == 0) return;
                try self.ensureInitialized();
                try checkNative("espz_es8311_es7210_audio_write_i16", native.espz_es8311_es7210_audio_write_i16(samples.ptr, samples.len));
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
                if (self.adc) |*adc| {
                    adc.setGainAll(microphoneGainFromDb(gain_db)) catch |err| return fail("es7210 gain", err);
                    if (options.es7210.ref_channel) |ref_channel| {
                        adc.setChannelGain(ref_channel, .@"0dB") catch |err| return fail("es7210 ref gain", err);
                    }
                    return;
                }
                return error.InvalidState;
            }
        };

        const NativeI2s = struct {
            pub fn write(_: *NativeI2s, data: []const u8) embed.drivers.I2s.Error!usize {
                if (data.len == 0) return 0;
                var bytes_written: usize = 0;
                try checkI2sNative(native.espz_es8311_es7210_audio_write_raw(data.ptr, data.len, &bytes_written));
                return bytes_written;
            }

            pub fn read(_: *NativeI2s, buf: []u8) embed.drivers.I2s.Error!usize {
                if (buf.len == 0) return 0;
                var bytes_read: usize = 0;
                try checkI2sNative(native.espz_es8311_es7210_audio_read_raw(buf.ptr, buf.len, &bytes_read));
                return bytes_read;
            }
        };

        const MicDevice = struct {
            gains_db: Mic.Gains = [_]?i8{null} ** mic_count,
            raw_ref: [frame_samples_per_channel]i16 = undefined,

            fn driver(self: *MicDevice) Mic {
                return Mic.init(self, &mic_vtable);
            }

            fn deinit(_: *MicDevice) void {}

            fn sampleRate(_: *MicDevice) u32 {
                return sample_rate;
            }

            fn micCount(_: *MicDevice) u8 {
                return mic_count;
            }

            fn read(self: *MicDevice, frame: *Mic.Frame) embed.audio.AudioSystem.Error!void {
                var offset: usize = 0;
                while (offset < frame.mic[0].len) {
                    const mic1 = if (mic_count > 1) frame.mic[1][offset..].ptr else null;
                    var sample_count: usize = 0;
                    try checkNative(
                        "espz_es8311_es7210_audio_mic_read_i16",
                        native.espz_es8311_es7210_audio_mic_read_i16(
                            frame.mic[0][offset..].ptr,
                            mic1,
                            self.raw_ref[offset..].ptr,
                            frame.mic[0].len - offset,
                            &sample_count,
                        ),
                    );
                    if (sample_count == 0 or sample_count > frame.mic[0].len - offset) {
                        return fail("mic short read", error.ShortMicRead);
                    }
                    offset += sample_count;
                }
                frame.ref = self.raw_ref;
            }

            fn gains(self: *MicDevice) Mic.Gains {
                return self.gains_db;
            }

            fn setGains(self: *MicDevice, gains_db: []const ?i8) embed.audio.AudioSystem.Error!void {
                if (gains_db.len > mic_count) return error.Unsupported;
                if (gains_db.len == 0) return;

                var applied: ?i8 = null;
                for (gains_db, 0..) |gain_db, index| {
                    if (gain_db) |value| {
                        self.gains_db[index] = value;
                        applied = value;
                    }
                }

                if (applied) |gain_db| {
                    const state = ownerState(self);
                    try state.setMicrophoneGain(gain_db);
                }
            }

            fn enable(self: *MicDevice) embed.audio.AudioSystem.Error!void {
                try ownerState(self).ensureInitialized();
            }

            fn disable(_: *MicDevice) embed.audio.AudioSystem.Error!void {}
        };

        const SpeakerDevice = struct {
            gain_db: ?i8 = null,

            fn driver(self: *SpeakerDevice) Speaker {
                return Speaker.init(self, &speaker_vtable);
            }

            fn deinit(_: *SpeakerDevice) void {}

            fn sampleRate(self: *SpeakerDevice) u32 {
                const state = ownerState(self);
                if (state.i2s_speaker) |*i2s_speaker| {
                    return i2s_speaker.speaker().sampleRate();
                }
                return sample_rate;
            }

            fn write(self: *SpeakerDevice, frame: []const i16) embed.audio.AudioSystem.Error!usize {
                if (frame.len == 0) return 0;
                const state = ownerState(self);
                if (state.i2s_speaker) |*i2s_speaker| {
                    return i2s_speaker.speaker().write(frame);
                }
                try state.writePcm(frame);
                return frame.len;
            }

            fn gain(self: *SpeakerDevice) ?i8 {
                return self.gain_db;
            }

            fn setGain(self: *SpeakerDevice, gain_db: i8) embed.audio.AudioSystem.Error!void {
                try ownerState(self).setVolume(EspAudio.gainDbToVolume(gain_db));
                self.gain_db = gain_db;
            }

            fn enable(self: *SpeakerDevice) embed.audio.AudioSystem.Error!void {
                const state = ownerState(self);
                if (state.i2s_speaker) |*i2s_speaker| {
                    return i2s_speaker.speaker().enable();
                }
                try state.ensureInitialized();
            }

            fn disable(self: *SpeakerDevice) embed.audio.AudioSystem.Error!void {
                const state = ownerState(self);
                if (state.i2s_speaker) |*i2s_speaker| {
                    return i2s_speaker.speaker().disable();
                }
            }
        };

        const mic_vtable = Mic.VTable{
            .deinit = micDeinit,
            .sampleRate = micSampleRate,
            .micCount = micCountFn,
            .read = micRead,
            .gains = micGains,
            .setGains = micSetGains,
            .enable = micEnable,
            .disable = micDisable,
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

        fn nativeConfig() native.Config {
            return .{
                .i2s_port = options.i2s.port,
                .sample_rate_hz = options.sample_rate,
                .mclk_gpio = options.i2s.mclk_gpio,
                .bclk_gpio = options.i2s.bclk_gpio,
                .ws_gpio = options.i2s.ws_gpio,
                .dout_gpio = options.i2s.dout_gpio,
                .din_gpio = options.i2s.din_gpio,
                .i2s_data_bit_width = @intFromEnum(options.i2s_data_bit_width),
                .i2s_slot_mode = @intFromEnum(options.i2s_slot_mode),
                .mono_chunk_samples = options.frame_samples_per_channel,
                .rx_channel_count = options.capture.raw_channel_count,
                .mic_count = options.mic_count,
                .mic0_lane = options.capture.mic_lanes[0],
                .mic1_lane = if (options.mic_count > 1) options.capture.mic_lanes[1] else -1,
                .ref_lane = if (options.capture.ref_lane) |lane| lane else -1,
            };
        }

        fn micChannels() [mic_count]Mic.I2s.Channel {
            var channels: [mic_count]Mic.I2s.Channel = undefined;
            channels[0] = micChannel(options.i2s_adapters.rx.mic_channels[0]);
            if (mic_count > 1) {
                channels[1] = micChannel(options.i2s_adapters.rx.mic_channels[1]);
            }
            return channels;
        }

        fn i2sRefChannel() ?Mic.I2s.Channel {
            return if (options.i2s_adapters.rx.ref_channel) |channel|
                micChannel(channel)
            else
                null;
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

        fn ownerState(device: anytype) *State {
            const Device = @TypeOf(device.*);
            const field_name = if (Device == MicDevice) "mic_device" else "speaker_device";
            return @alignCast(@fieldParentPtr(field_name, device));
        }

        fn micDeinit(ptr: *anyopaque) void {
            const self: *MicDevice = @ptrCast(@alignCast(ptr));
            self.deinit();
        }

        fn micSampleRate(ptr: *anyopaque) u32 {
            const self: *MicDevice = @ptrCast(@alignCast(ptr));
            return self.sampleRate();
        }

        fn micCountFn(ptr: *anyopaque) u8 {
            const self: *MicDevice = @ptrCast(@alignCast(ptr));
            return self.micCount();
        }

        fn micRead(ptr: *anyopaque, frame: *Mic.Frame) embed.audio.AudioSystem.Error!void {
            const self: *MicDevice = @ptrCast(@alignCast(ptr));
            return self.read(frame);
        }

        fn micGains(ptr: *anyopaque) Mic.Gains {
            const self: *MicDevice = @ptrCast(@alignCast(ptr));
            return self.gains();
        }

        fn micSetGains(ptr: *anyopaque, gains_db: []const ?i8) embed.audio.AudioSystem.Error!void {
            const self: *MicDevice = @ptrCast(@alignCast(ptr));
            return self.setGains(gains_db);
        }

        fn micEnable(ptr: *anyopaque) embed.audio.AudioSystem.Error!void {
            const self: *MicDevice = @ptrCast(@alignCast(ptr));
            return self.enable();
        }

        fn micDisable(ptr: *anyopaque) embed.audio.AudioSystem.Error!void {
            const self: *MicDevice = @ptrCast(@alignCast(ptr));
            return self.disable();
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

        fn microphoneGainFromDb(gain_db: i8) Es7210.Gain {
            if (gain_db < 3) return .@"0dB";
            if (gain_db < 6) return .@"3dB";
            if (gain_db < 9) return .@"6dB";
            if (gain_db < 12) return .@"9dB";
            if (gain_db < 15) return .@"12dB";
            if (gain_db < 18) return .@"15dB";
            if (gain_db < 21) return .@"18dB";
            if (gain_db < 24) return .@"21dB";
            if (gain_db < 27) return .@"24dB";
            if (gain_db < 30) return .@"27dB";
            if (gain_db < 33) return .@"30dB";
            if (gain_db < 34) return .@"33dB";
            if (gain_db < 36) return .@"34.5dB";
            if (gain_db < 37) return .@"36dB";
            return .@"37.5dB";
        }
    };
}
