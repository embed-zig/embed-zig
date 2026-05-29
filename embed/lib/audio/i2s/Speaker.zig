//! I2S-backed audio.Speaker adapter.

const drivers = @import("drivers");
const glib = @import("glib");
const AudioSystem = @import("../AudioSystem.zig");

pub fn make(comptime grt: type, comptime samples_per_channel: usize, comptime SpeakerRole: type) type {
    _ = grt;
    _ = samples_per_channel;

    return struct {
        const Self = @This();

        pub const SampleAlign = enum {
            /// Store the i16 sample in the low bits of the hardware slot.
            lsb,
            /// Store the i16 sample in the high bits of the hardware slot.
            msb,
        };

        pub const Slot = struct {
            /// Hardware slot index inside one I2S frame.
            index: usize,
            /// Where the i16 logical sample sits inside that hardware slot.
            sample_align: SampleAlign = .lsb,
        };

        pub const Channel = struct {
            /// Hardware slots that receive this one logical speaker channel.
            ///
            /// A mono logical speaker can duplicate each sample to two slots
            /// by listing both left and right hardware slot indexes here.
            slots: []const Slot,
        };

        pub const Config = struct {
            stream: *drivers.I2s,
            sample_rate: u32,
            channels: []const Channel,
            gain_db: ?i8 = null,
        };

        stream: *drivers.I2s,
        sample_rate: u32,
        channels: []const Channel,
        gain_db: ?i8,
        enabled: bool = false,

        pub fn init(config: Config) Self {
            return .{
                .stream = config.stream,
                .sample_rate = config.sample_rate,
                .channels = config.channels,
                .gain_db = config.gain_db,
            };
        }

        pub fn speaker(self: *Self) SpeakerRole {
            return SpeakerRole.init(self, &vtable);
        }

        fn deinit(_: *Self) void {}

        fn sampleRate(self: *Self) u32 {
            return self.sample_rate;
        }

        fn write(self: *Self, samples: []const i16) AudioSystem.Error!usize {
            if (!self.enabled) return error.InvalidState;
            if (self.channels.len == 0) return error.InvalidState;
            if (samples.len < self.channels.len) return 0;

            var total_samples: usize = 0;
            while (total_samples + self.channels.len <= samples.len) {
                const complete_frames = (samples.len - total_samples) / self.channels.len;
                const frame_count = @min(complete_frames, self.stream.bufferFrameCount());
                if (frame_count == 0) break;

                const view = self.stream.writeView(frame_count) catch |err| {
                    return mapI2sError(err);
                };

                for (0..frame_count) |frame_index| {
                    for (self.channels, 0..) |channel, channel_index| {
                        const sample = samples[total_samples + frame_index * self.channels.len + channel_index];
                        for (channel.slots) |slot_config| {
                            const slot = view.slot(frame_index, slot_config.index) catch |err| {
                                return mapI2sError(err);
                            };
                            try writeSampleToSlot(slot, sample, slot_config.sample_align);
                        }
                    }
                }

                const frames_written = self.stream.flush() catch |err| {
                    return mapI2sError(err);
                };
                total_samples += frames_written * self.channels.len;
                if (frames_written < frame_count) break;
            }

            return total_samples;
        }

        fn gain(self: *Self) ?i8 {
            return self.gain_db;
        }

        fn setGain(self: *Self, gain_db: i8) AudioSystem.Error!void {
            self.gain_db = gain_db;
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

        fn writeSampleToSlot(slot: []u8, sample: i16, sample_align: SampleAlign) AudioSystem.Error!void {
            if (slot.len < @sizeOf(i16) or slot.len > @sizeOf(u64)) return error.Unsupported;
            const shift_bits = try sampleShiftBits(slot.len, sample_align);
            const sample_bits: u16 = @bitCast(sample);
            const raw = @as(u64, sample_bits) << shift_bits;
            const bytes = glib.std.mem.asBytes(&raw);
            @memcpy(slot, bytes[0..slot.len]);
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

        fn i2sWrite(ptr: *anyopaque, samples: []const i16) AudioSystem.Error!usize {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.write(samples);
        }

        fn i2sGain(ptr: *anyopaque) ?i8 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.gain();
        }

        fn i2sSetGain(ptr: *anyopaque, gain_db: i8) AudioSystem.Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.setGain(gain_db);
        }

        fn i2sEnable(ptr: *anyopaque) AudioSystem.Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.enable();
        }

        fn i2sDisable(ptr: *anyopaque) AudioSystem.Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.disable();
        }

        const vtable = SpeakerRole.VTable{
            .deinit = i2sDeinit,
            .sampleRate = i2sSampleRate,
            .write = i2sWrite,
            .gain = i2sGain,
            .setGain = i2sSetGain,
            .enable = i2sEnable,
            .disable = i2sDisable,
        };
    };
}
