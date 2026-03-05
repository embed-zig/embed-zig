const hal_speaker = @import("hal").speaker;
const hal_i2c = @import("hal").i2c;
const es8311_drv = @import("es8311_driver");
const esp_i2c = @import("../i2c.zig");
const esp_i2s = @import("../i2s.zig");

const max_write_chunk: usize = 256;

const I2cSpec = struct {
    pub const Driver = esp_i2c.Driver;
    pub const meta = .{ .id = "esp.i2c" };
};

const Codec = es8311_drv.Es8311(I2cSpec);

pub const Config = struct {
    codec: es8311_drv.Config = .{ .codec_mode = .dac_only },
    codec_address: u7 = es8311_drv.DEFAULT_ADDRESS,
    i2c_timeout_ms: u32 = 1000,
    initial_volume: ?u8 = null,
    initial_mute: bool = false,
    duplicate_mono_to_stereo: bool = true,
    slot_mode: SlotMode = .mono,
    tx_timeout_ms: u32 = 20,
};

const SlotMode = enum { mono, stereo };

pub const Driver = struct {
    cfg: Config,
    codec: Codec,
    i2c_driver: *esp_i2c.Driver,
    i2s_driver: *esp_i2s.Driver,
    i2s_handle: esp_i2s.EndpointHandle,

    pub fn init(
        i2c_driver: *esp_i2c.Driver,
        i2s_driver: *esp_i2s.Driver,
        i2s_handle: esp_i2s.EndpointHandle,
        cfg: Config,
    ) hal_speaker.Error!Driver {
        var codec = Codec.init(i2c_driver, cfg.codec);
        codec.open() catch |err| return mapCodecError(err);
        errdefer codec.close() catch {};

        codec.setSampleRate(16000) catch |err| return mapCodecError(err);
        codec.setBitsPerSample(.@"16bit") catch |err| return mapCodecError(err);
        codec.setFormat(.i2s) catch |err| return mapCodecError(err);

        codec.enable(true) catch |err| return mapCodecError(err);
        errdefer codec.enable(false) catch {};

        if (cfg.initial_volume) |vol| {
            codec.setVolume(vol) catch |err| return mapCodecError(err);
        }
        codec.setMute(cfg.initial_mute) catch |err| return mapCodecError(err);

        return .{
            .cfg = cfg,
            .codec = codec,
            .i2c_driver = i2c_driver,
            .i2s_driver = i2s_driver,
            .i2s_handle = i2s_handle,
        };
    }

    pub fn deinit(self: *Driver) void {
        self.codec.enable(false) catch {};
        self.codec.close() catch {};
    }

    pub fn write(self: *Driver, buffer: []const i16) hal_speaker.Error!usize {
        if (buffer.len == 0) return 0;
        if (self.cfg.duplicate_mono_to_stereo and self.cfg.slot_mode == .stereo) {
            return self.writeStereoDuplicated(buffer);
        }

        const bytes = @import("std").mem.sliceAsBytes(buffer);
        const n_bytes = self.i2s_driver.write(self.i2s_handle, bytes) catch |err| return mapI2sError(err);
        if (n_bytes == 0) return error.WouldBlock;
        return n_bytes / @sizeOf(i16);
    }

    pub fn setVolume(self: *Driver, volume: u8) hal_speaker.Error!void {
        self.codec.setVolume(volume) catch |err| return mapCodecError(err);
    }

    pub fn setMute(self: *Driver, mute: bool) hal_speaker.Error!void {
        self.codec.setMute(mute) catch |err| return mapCodecError(err);
    }

    fn writeStereoDuplicated(self: *Driver, mono: []const i16) hal_speaker.Error!usize {
        const mem = @import("std").mem;
        var total_written: usize = 0;
        var scratch: [max_write_chunk * 2]i16 = undefined;

        while (total_written < mono.len) {
            const chunk = @min(max_write_chunk, mono.len - total_written);
            for (0..chunk) |i| {
                const s = mono[total_written + i];
                scratch[i * 2] = s;
                scratch[i * 2 + 1] = s;
            }

            const stereo_bytes = mem.sliceAsBytes(scratch[0 .. chunk * 2]);
            const written_bytes = self.i2s_driver.write(self.i2s_handle, stereo_bytes) catch |err| return mapI2sError(err);
            if (written_bytes == 0) {
                if (total_written == 0) return error.WouldBlock;
                break;
            }

            const stereo_written = written_bytes / @sizeOf(i16);
            const mono_written = stereo_written / 2;
            if (mono_written == 0) break;
            total_written += mono_written;
            if (mono_written < chunk) break;
        }

        return total_written;
    }
};

fn mapI2sError(err: anyerror) hal_speaker.Error {
    return switch (err) {
        error.Timeout => error.Timeout,
        error.InvalidParam, error.InvalidDirection => error.InvalidState,
        else => error.SpeakerError,
    };
}

fn mapCodecError(err: anyerror) hal_speaker.Error {
    return switch (err) {
        error.Timeout => error.Timeout,
        error.NotOpen, error.UnsupportedSampleRate => error.InvalidState,
        else => error.SpeakerError,
    };
}
