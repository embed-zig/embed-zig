//! I2S-backed audio.Mic adapter.

const drivers = @import("drivers");
const AudioSystem = @import("../AudioSystem.zig");

pub fn make(comptime grt: type, comptime mic_count: usize, comptime samples_per_channel: usize, comptime MicRole: type) type {
    _ = grt;

    return struct {
        const Self = @This();

        pub const Frame = MicRole.Frame;
        pub const Gains = MicRole.Gains;

        pub const SampleAlign = enum {
            /// Read the i16 sample from the low bits of the hardware slot.
            lsb,
            /// Read the i16 sample from the high bits of the hardware slot.
            msb,
        };

        pub const Channel = struct {
            /// Hardware slot index inside one I2S frame.
            slot: usize,
            /// Where the i16 logical sample sits inside that hardware slot.
            sample_align: SampleAlign = .lsb,
        };

        pub const Config = struct {
            stream: *drivers.I2s,
            sample_rate: u32,
            mic_channels: [mic_count]Channel,
            ref_channel: ?Channel = null,
            gains_db: Gains = [_]?i8{null} ** mic_count,
        };

        stream: *drivers.I2s,
        sample_rate: u32,
        mic_channels: [mic_count]Channel,
        ref_channel: ?Channel,
        gains_db: Gains,
        enabled: bool = false,
        ref_samples: [samples_per_channel]i16 = undefined,

        pub fn init(config: Config) Self {
            return .{
                .stream = config.stream,
                .sample_rate = config.sample_rate,
                .mic_channels = config.mic_channels,
                .ref_channel = config.ref_channel,
                .gains_db = config.gains_db,
            };
        }

        pub fn mic(self: *Self) MicRole {
            return MicRole.init(self, &vtable);
        }

        fn deinit(_: *Self) void {}

        fn sampleRate(self: *Self) u32 {
            return self.sample_rate;
        }

        fn micCount(_: *Self) u8 {
            return @intCast(mic_count);
        }

        fn read(self: *Self, frame: *Frame) AudioSystem.Error!void {
            if (!self.enabled) return error.InvalidState;
            if (samples_per_channel == 0) {
                frame.ref = null;
                return;
            }

            const max_frames = self.stream.bufferFrameCount();
            if (max_frames == 0) return error.InvalidState;

            var offset: usize = 0;
            while (offset < samples_per_channel) {
                const read_frames = @min(samples_per_channel - offset, max_frames);
                const view = self.stream.readFrames(read_frames) catch |err| {
                    return mapI2sError(err);
                };
                if (view.frames == 0) return error.Unexpected;

                for (0..view.frames) |frame_index| {
                    if (self.ref_channel) |ref_channel| {
                        const slot = view.slot(frame_index, ref_channel.slot) catch |err| {
                            return mapI2sError(err);
                        };
                        self.ref_samples[offset + frame_index] = try readSampleFromSlot(slot, ref_channel.sample_align);
                    }

                    for (self.mic_channels, 0..) |mic_channel, mic_index| {
                        const slot = view.slot(frame_index, mic_channel.slot) catch |err| {
                            return mapI2sError(err);
                        };
                        frame.mic[mic_index][offset + frame_index] = try readSampleFromSlot(slot, mic_channel.sample_align);
                    }
                }
                offset += view.frames;
            }

            frame.ref = if (self.ref_channel == null) null else self.ref_samples;
        }

        fn gains(self: *Self) Gains {
            return self.gains_db;
        }

        fn setGains(self: *Self, gains_db: []const ?i8) AudioSystem.Error!void {
            if (gains_db.len > mic_count) return error.Unsupported;
            for (gains_db, 0..) |gain_db, index| {
                if (gain_db) |value| {
                    self.gains_db[index] = value;
                }
            }
        }

        fn enable(self: *Self) AudioSystem.Error!void {
            self.enabled = true;
        }

        fn disable(self: *Self) AudioSystem.Error!void {
            self.enabled = false;
        }

        fn mapI2sError(err: drivers.I2s.Error) AudioSystem.Error {
            return switch (err) {
                error.Timeout => error.Timeout,
                error.NotStarted, error.InvalidFrameSize, error.InvalidLane => error.InvalidState,
                error.Unsupported => error.Unsupported,
                error.OutOfMemory => error.Unexpected,
                error.BusError, error.Unexpected => error.Unexpected,
            };
        }

        fn readSampleFromSlot(slot: []const u8, sample_align: SampleAlign) AudioSystem.Error!i16 {
            if (slot.len < @sizeOf(i16) or slot.len > @sizeOf(u64)) return error.Unsupported;
            const shift_bits = try sampleShiftBits(slot.len, sample_align);

            var raw: u64 = 0;
            for (slot, 0..) |byte, index| {
                raw |= @as(u64, byte) << @intCast(index * 8);
            }

            const sample_bits: u16 = @truncate(raw >> shift_bits);
            return @bitCast(sample_bits);
        }

        fn sampleShiftBits(slot_size_bytes: usize, sample_align: SampleAlign) AudioSystem.Error!u6 {
            if (slot_size_bytes < @sizeOf(i16) or slot_size_bytes > @sizeOf(u64)) return error.Unsupported;
            return switch (sample_align) {
                .lsb => 0,
                .msb => @intCast(slot_size_bytes * 8 - @bitSizeOf(i16)),
            };
        }

        fn i2sDeinit(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.deinit();
        }

        fn i2sSampleRate(ptr: *anyopaque) u32 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.sampleRate();
        }

        fn i2sMicCount(ptr: *anyopaque) u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.micCount();
        }

        fn i2sHasRef(ptr: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.ref_channel != null;
        }

        fn i2sRead(ptr: *anyopaque, frame: *Frame) AudioSystem.Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.read(frame);
        }

        fn i2sGains(ptr: *anyopaque) Gains {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.gains();
        }

        fn i2sSetGains(ptr: *anyopaque, gains_db: []const ?i8) AudioSystem.Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.setGains(gains_db);
        }

        fn i2sEnable(ptr: *anyopaque) AudioSystem.Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.enable();
        }

        fn i2sDisable(ptr: *anyopaque) AudioSystem.Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.disable();
        }

        const vtable = MicRole.VTable{
            .deinit = i2sDeinit,
            .sampleRate = i2sSampleRate,
            .micCount = i2sMicCount,
            .hasRef = i2sHasRef,
            .read = i2sRead,
            .gains = i2sGains,
            .setGains = i2sSetGains,
            .enable = i2sEnable,
            .disable = i2sDisable,
        };
    };
}
