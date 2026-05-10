const embed = @import("embed");
const esp = @import("esp");
const binding = @import("bindings/common.zig");

pub fn make(comptime BoardType: type) type {
    return struct {
        const Audio = @This();
        const log = esp.grt.std.log.scoped(.szp_audio_system);

        pub const sample_rate = 16_000;
        pub const mic_count = 2;
        pub const frame_samples_per_channel = 256;
        pub const Mic = embed.audio.Mic.make(esp.grt, mic_count, frame_samples_per_channel);
        pub const Speaker = embed.audio.Speaker.make(esp.grt, frame_samples_per_channel);
        pub const Type = blk: {
            var builder = embed.audio.AudioSystem.Builder(esp.grt).init();
            builder.configMic(mic_count, frame_samples_per_channel);
            builder.configSpeaker(frame_samples_per_channel);
            builder.setProcessor(&Processor.process);
            break :blk builder.build();
        };

        pub const MicDevice = struct {
            board: ?*BoardType = null,
            gains_db: Mic.Gains = .{ null, null },
            raw_ref: [frame_samples_per_channel]i16 = undefined,

            pub fn bind(self: *MicDevice, board: *BoardType) void {
                self.board = board;
            }

            pub fn driver(self: *MicDevice) Mic {
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
                const board = self.board orelse return error.InvalidState;
                var offset: usize = 0;
                while (offset < frame.mic[0].len) {
                    const n = board.readMicrophoneFrame(frame.mic[0][offset..], frame.mic[1][offset..], self.raw_ref[offset..]) catch |err| {
                        return fail("mic read", err);
                    };
                    if (n == 0 or n > frame.mic[0].len - offset) return fail("mic short read", error.ShortMicRead);
                    offset += n;
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
                    const board = self.board orelse return error.InvalidState;
                    board.setMicrophoneGain(gain_db) catch |err| return fail("mic set gain", err);
                }
            }

            fn enable(self: *MicDevice) embed.audio.AudioSystem.Error!void {
                const board = self.board orelse return error.InvalidState;
                board.startMicrophoneCapture() catch |err| return fail("mic enable", err);
            }

            fn disable(self: *MicDevice) embed.audio.AudioSystem.Error!void {
                const board = self.board orelse return error.InvalidState;
                board.stopMicrophoneCapture();
            }
        };

        pub const SpeakerDevice = struct {
            board: ?*BoardType = null,
            gain_db: ?i8 = null,

            pub fn bind(self: *SpeakerDevice, board: *BoardType) void {
                self.board = board;
            }

            pub fn driver(self: *SpeakerDevice) Speaker {
                return Speaker.init(self, &speaker_vtable);
            }

            fn deinit(_: *SpeakerDevice) void {}

            fn sampleRate(_: *SpeakerDevice) u32 {
                return sample_rate;
            }

            fn write(self: *SpeakerDevice, frame: []const i16) embed.audio.AudioSystem.Error!usize {
                if (frame.len == 0) return 0;
                const board = self.board orelse return error.InvalidState;
                board.writePcm(frame) catch |err| return fail("speaker write", err);
                return frame.len;
            }

            fn gain(self: *SpeakerDevice) ?i8 {
                return self.gain_db;
            }

            fn setGain(self: *SpeakerDevice, gain_db: i8) embed.audio.AudioSystem.Error!void {
                const board = self.board orelse return error.InvalidState;
                board.setVolume(gainDbToVolume(gain_db)) catch |err| return fail("speaker set gain", err);
                self.gain_db = gain_db;
            }

            fn enable(self: *SpeakerDevice) embed.audio.AudioSystem.Error!void {
                const board = self.board orelse return error.InvalidState;
                board.setSpeakerEnabled(true) catch |err| return fail("speaker enable", err);
            }

            fn disable(self: *SpeakerDevice) embed.audio.AudioSystem.Error!void {
                const board = self.board orelse return error.InvalidState;
                board.setSpeakerEnabled(false) catch |err| return fail("speaker disable", err);
            }
        };

        const Processor = struct {
            pub fn process(frame: Mic.Frame, out: []i16) embed.audio.AudioSystem.Error!usize {
                const ref = frame.ref orelse return error.InvalidState;
                var out_count: usize = 0;
                try check(
                    "szp_audio_afe_process_i16",
                    binding.szp_audio_afe_process_i16(frame.mic[0][0..].ptr, frame.mic[1][0..].ptr, ref[0..].ptr, frame.mic[0].len, out.ptr, out.len, &out_count),
                );
                applyMonitorGain(out[0..out_count]);
                return out_count;
            }
        };

        const mic_vtable = Mic.VTable{
            .deinit = micDeinit,
            .sampleRate = micSampleRate,
            .micCount = micCount,
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

        fn micDeinit(ptr: *anyopaque) void {
            const self: *MicDevice = @ptrCast(@alignCast(ptr));
            self.deinit();
        }

        fn micSampleRate(ptr: *anyopaque) u32 {
            const self: *MicDevice = @ptrCast(@alignCast(ptr));
            return self.sampleRate();
        }

        fn micCount(ptr: *anyopaque) u8 {
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

        fn check(name: []const u8, rc: c_int) embed.audio.AudioSystem.Error!void {
            if (rc == binding.esp_ok) return;
            log.err("{s} failed with rc={d}", .{ name, rc });
            return error.Unexpected;
        }

        fn fail(name: []const u8, err: anyerror) embed.audio.AudioSystem.Error {
            log.err("{s} failed: {s}", .{ name, @errorName(err) });
            return error.Unexpected;
        }

        fn applyMonitorGain(samples: []i16) void {
            for (samples) |*sample| {
                const value = (@as(i32, sample.*) * 3);
                sample.* = if (value > 32767)
                    32767
                else if (value < -32768)
                    -32768
                else
                    @intCast(value);
            }
        }

        fn gainDbToVolume(gain_db: i8) u8 {
            const scaled: i16 = (@as(i16, gain_db) + 96) * 2;
            if (scaled <= 0) return 0;
            if (scaled >= 255) return 255;
            return @intCast(scaled);
        }
    };
}
