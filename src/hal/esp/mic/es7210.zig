const std = @import("std");
const hal_mic = @import("hal").mic;
const hal_i2c = @import("hal").i2c;
const hal_i2s = @import("hal").i2s;
const es7210_drv = @import("es7210_driver");
const esp_i2c = @import("../i2c.zig");
const esp_i2s = @import("../i2s.zig");

const max_mics: usize = 4;
const max_frame_samples: usize = 1024;
const max_frame_bytes: usize = max_mics * max_frame_samples * @sizeOf(i16);

const I2cBus = struct {
    driver: *esp_i2c.Driver,
    device: esp_i2c.Driver.DeviceHandle,

    pub fn write(self: *const I2cBus, _: u7, data: []const u8) !void {
        try self.driver.write(self.device, data);
    }

    pub fn writeRead(self: *const I2cBus, _: u7, write_data: []const u8, read_data: []u8) !void {
        try self.driver.writeRead(self.device, write_data, read_data);
    }
};

const Codec = es7210_drv.Es7210(I2cBus);

pub const ChannelGain = struct {
    channel: u8,
    gain_db: i8,
};

pub const Config = struct {
    pub const MicConfig = struct {
        enabled: bool = false,
        gain_db: ?i8 = null,
        is_ref: bool = false,
    };

    codec: es7210_drv.Config = .{},
    mics: [max_mics]MicConfig = .{ .{}, .{}, .{}, .{} },
    frame_samples: u16 = 160,
    codec_address: u7 = es7210_drv.DEFAULT_ADDRESS,
    i2c_timeout_ms: u32 = 1000,
};

pub const Driver = struct {
    cfg: Config,
    codec: Codec,
    i2c_driver: *esp_i2c.Driver,
    i2c_device: esp_i2c.Driver.DeviceHandle,
    i2s_driver: *esp_i2s.Driver,
    i2s_handle: esp_i2s.EndpointHandle,
    mic_count: usize,
    ref_slot: ?usize,
    matrix_count: usize,
    frame_samples: usize,
    slot_to_mic: [max_mics]u8 = .{ 0, 0, 0, 0 },

    interleaved: [max_mics * max_frame_samples]i16 = undefined,
    mic_buffers: [max_mics][max_frame_samples]i16 = undefined,
    mic_views: [max_mics][]const i16 = undefined,
    pending_bytes: usize = 0,

    pub fn init(
        i2c_driver: *esp_i2c.Driver,
        i2s_driver: *esp_i2s.Driver,
        i2s_handle: esp_i2s.EndpointHandle,
        cfg: Config,
    ) hal_mic.Error!Driver {
        if (cfg.frame_samples == 0 or cfg.frame_samples > max_frame_samples) {
            return error.InvalidState;
        }

        const parsed = parseMicConfigs(cfg.mics) catch return error.InvalidState;
        const mic_count_u8 = parsed.mic_count;
        if (mic_count_u8 == 0 or mic_count_u8 > max_mics) {
            return error.InvalidState;
        }
        const matrix_count = mic_count_u8 - @as(u8, if (parsed.ref_slot != null) 1 else 0);
        if (matrix_count == 0) return error.InvalidState;

        const i2c_device = i2c_driver.registerDevice(.{
            .address = cfg.codec_address,
            .timeout_ms = cfg.i2c_timeout_ms,
        }) catch return error.MicError;
        errdefer i2c_driver.unregisterDevice(i2c_device) catch {};

        var codec_cfg = cfg.codec;
        codec_cfg.mic_select = parsed.mic_select;

        var codec = Codec.init(.{
            .driver = i2c_driver,
            .device = i2c_device,
        }, codec_cfg);

        codec.open() catch |err| return mapCodecError(err);
        errdefer codec.close() catch {};

        codec.setSampleRate(16000) catch |err| return mapCodecError(err);
        try applyInitChannelGains(&codec, parsed.slot_to_mic, parsed.gains_db, parsed.mic_count);

        var driver = Driver{
            .cfg = cfg,
            .codec = codec,
            .i2c_driver = i2c_driver,
            .i2c_device = i2c_device,
            .i2s_driver = i2s_driver,
            .i2s_handle = i2s_handle,
            .mic_count = mic_count_u8,
            .ref_slot = parsed.ref_slot,
            .matrix_count = matrix_count,
            .frame_samples = cfg.frame_samples,
            .slot_to_mic = parsed.slot_to_mic,
        };
        for (0..max_mics) |i| driver.mic_views[i] = &.{};
        return driver;
    }

    pub fn deinit(self: *Driver) void {
        self.stop() catch {};
        self.codec.close() catch {};
        self.i2c_driver.unregisterDevice(self.i2c_device) catch {};
    }

    pub fn read(self: *Driver, buffer: []i16) hal_mic.Error!usize {
        if (buffer.len == 0) return 0;
        if (self.mic_count == 1) {
            const bytes = std.mem.sliceAsBytes(buffer);
            const n_bytes = self.i2s_driver.read(self.i2s_handle, bytes) catch |err| return mapI2sError(err);
            if (n_bytes == 0) return error.WouldBlock;
            return n_bytes / @sizeOf(i16);
        }

        const frame = try self.readFrame() orelse return error.WouldBlock;
        if (frame.mic_matrix.len == 0) return error.WouldBlock;
        const src = frame.mic_matrix[0];
        const n = @min(src.len, buffer.len);
        @memcpy(buffer[0..n], src[0..n]);
        return n;
    }

    pub fn readFrame(self: *Driver) hal_mic.Error!?hal_mic.Frame {
        const frame_total_samples = self.frame_samples * self.mic_count;
        const frame_bytes = frame_total_samples * @sizeOf(i16);
        if (frame_bytes > max_frame_bytes) return error.InvalidState;
        const read_buf = std.mem.sliceAsBytes(self.interleaved[0..frame_total_samples]);

        if (self.pending_bytes < frame_bytes) {
            const need = frame_bytes - self.pending_bytes;
            const n_bytes = self.i2s_driver.read(self.i2s_handle, read_buf[self.pending_bytes .. self.pending_bytes + need]) catch |err| {
                if (err == error.Timeout) return null;
                return mapI2sError(err);
            };
            if (n_bytes == 0) return null;
            self.pending_bytes += n_bytes;
        }

        if (self.pending_bytes < frame_bytes) return null;
        if (self.pending_bytes > frame_bytes) return error.MicError;
        self.pending_bytes = 0;

        var sample_idx: usize = 0;
        while (sample_idx < self.frame_samples) : (sample_idx += 1) {
            var ch: usize = 0;
            while (ch < self.mic_count) : (ch += 1) {
                const src_idx = sample_idx * self.mic_count + ch;
                self.mic_buffers[ch][sample_idx] = self.interleaved[src_idx];
            }
        }

        var matrix_idx: usize = 0;
        for (0..self.mic_count) |slot| {
            if (self.ref_slot != null and slot == self.ref_slot.?) continue;
            self.mic_views[matrix_idx] = self.mic_buffers[slot][0..self.frame_samples];
            matrix_idx += 1;
        }

        const ref: ?[]const i16 = if (self.ref_slot) |slot|
            self.mic_buffers[slot][0..self.frame_samples]
        else
            null;

        return .{
            .mic_matrix = self.mic_views[0..self.matrix_count],
            .ref = ref,
        };
    }

    pub fn setGain(self: *Driver, gain_db: i8) hal_mic.Error!void {
        const gain = es7210_drv.Gain.fromDb(@as(f32, @floatFromInt(gain_db)));
        self.codec.setGainAll(gain) catch |err| return mapCodecError(err);
    }

    pub fn setChannelGain(self: *Driver, channel: u8, gain_db: i8) hal_mic.Error!void {
        if (channel >= max_mics or !self.hasMicChannel(channel)) return error.InvalidState;
        const gain = es7210_drv.Gain.fromDb(@as(f32, @floatFromInt(gain_db)));
        self.codec.setChannelGain(@intCast(channel), gain) catch |err| return mapCodecError(err);
    }

    pub fn setChannelGains(self: *Driver, updates: []const ChannelGain) hal_mic.Error!void {
        for (updates) |u| {
            try self.setChannelGain(u.channel, u.gain_db);
        }
    }

    pub fn start(self: *Driver) hal_mic.Error!void {
        self.pending_bytes = 0;
        self.codec.enable(true) catch |err| return mapCodecError(err);
    }

    pub fn stop(self: *Driver) hal_mic.Error!void {
        self.codec.enable(false) catch |err| return mapCodecError(err);
        self.pending_bytes = 0;
    }

    fn hasMicChannel(self: *const Driver, channel: u8) bool {
        for (self.slot_to_mic[0..self.mic_count]) |mic_idx| {
            if (mic_idx == channel) return true;
        }
        return false;
    }
};

fn mapI2sError(err: anyerror) hal_mic.Error {
    return switch (err) {
        error.Timeout => error.Timeout,
        error.InvalidParam, error.InvalidDirection => error.InvalidState,
        else => error.MicError,
    };
}

fn mapCodecError(err: anyerror) hal_mic.Error {
    return switch (err) {
        error.Timeout => error.Timeout,
        error.NotOpen, error.UnsupportedSampleRate => error.InvalidState,
        else => error.MicError,
    };
}

const ParsedMicLayout = struct {
    mic_select: es7210_drv.MicSelect,
    mic_count: u8,
    ref_slot: ?usize,
    tdm_slot_mask: u32,
    slot_to_mic: [max_mics]u8,
    gains_db: [max_mics]?i8,
};

fn parseMicConfigs(mics: [max_mics]Config.MicConfig) !ParsedMicLayout {
    var out = ParsedMicLayout{
        .mic_select = .{},
        .mic_count = 0,
        .ref_slot = null,
        .tdm_slot_mask = 0,
        .slot_to_mic = .{ 0, 0, 0, 0 },
        .gains_db = .{ null, null, null, null },
    };

    for (mics, 0..) |m, mic_idx| {
        if (!m.enabled) {
            if (m.is_ref) return error.InvalidState;
            continue;
        }

        const slot = out.mic_count;
        out.slot_to_mic[slot] = @intCast(mic_idx);
        out.gains_db[slot] = m.gain_db;
        out.tdm_slot_mask |= (@as(u32, 1) << @intCast(mic_idx));

        switch (mic_idx) {
            0 => out.mic_select.mic1 = true,
            1 => out.mic_select.mic2 = true,
            2 => out.mic_select.mic3 = true,
            3 => out.mic_select.mic4 = true,
            else => unreachable,
        }

        if (m.is_ref) {
            if (out.ref_slot != null) return error.InvalidState;
            out.ref_slot = slot;
        }

        out.mic_count += 1;
    }

    return out;
}

fn applyInitChannelGains(codec: *Codec, slot_to_mic: [max_mics]u8, gains_db: [max_mics]?i8, mic_count: u8) hal_mic.Error!void {
    var slot: u8 = 0;
    while (slot < mic_count) : (slot += 1) {
        if (gains_db[slot]) |db| {
            const gain = es7210_drv.Gain.fromDb(@as(f32, @floatFromInt(db)));
            codec.setChannelGain(@intCast(slot_to_mic[slot]), gain) catch |err| return mapCodecError(err);
        }
    }
}
