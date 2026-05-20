const embed = @import("embed_core");
const esp = @import("esp");
const binding = @import("bindings/common.zig");
const Audio = @import("Audio.zig").make(Self);
const BtHost = esp.embed.BtHost;
const Display = @import("Display.zig");
const Imu = @import("Imu.zig");
const PowerButton = @import("PowerButton.zig");
const Touch = @import("Touch.zig");
const Wifi = esp.embed.Wifi;

const Self = @This();
const Es7210 = embed.drivers.audio.Es7210;
const Es8311 = embed.drivers.audio.Es8311;
const log = esp.grt.std.log.scoped(.szp_board);

pub const Board = Self;
pub const metadata = embed.board.Metadata{
    .name = "szp",
    .description = "LCKFB SZP ESP32-S3 board with LCD, touch, audio, boot button, Wi-Fi, IMU, camera, and storage.",
    .vendor = "LCKFB",
    .model = "Shi Zhan Pai ESP32-S3",
    .chip = "esp32s3",
};
pub const Spec = embed.board.Spec{
    .Mic = Audio.Mic,
    .Speaker = Audio.Speaker,
    .AudioSystem = Audio.Type,
};
pub const Type = embed.board.Board.make(esp.grt, Spec);
pub const InitConfig = struct {
    audio_allocator: ?esp.grt.std.mem.Allocator = null,
    audio_system_config: Audio.Type.Config = .{},
    bt_allocator: ?esp.grt.std.mem.Allocator = null,
};

pub const audio_sample_rate = Audio.sample_rate;
pub const AudioSystem = Audio.Type;
pub const StorageInfo = struct {
    total: usize,
    used: usize,
};

const es7210_address = @intFromEnum(Es7210.Address.ad1_ad0_01);
const es8311_address = @intFromEnum(Es8311.Address.ad0_low);
const default_volume: u8 = 0xb0;
const es7210_ref_channel: u2 = 2;

power_button: PowerButton = .{},
display_device: Display = .{},
imu_device: Imu = .{},
touch_device: Touch = .{},
wifi_sta: Wifi.Sta = .{},
bt_host: ?BtHost = null,
audio_adc: ?Es7210 = null,
audio_codec: ?Es8311 = null,
audio_mic: Audio.MicDevice = .{},
audio_speaker: Audio.SpeakerDevice = .{},
audio_system: ?Audio.Type = null,
audio_allocator: ?esp.grt.std.mem.Allocator = null,
audio_system_config: Audio.Type.Config = .{},
bt_allocator: ?esp.grt.std.mem.Allocator = null,
audio_ready: bool = false,
state_value: embed.board.State = .uninitialized,

pub fn init(config: InitConfig) !Self {
    return .{
        .audio_allocator = config.audio_allocator,
        .audio_system_config = config.audio_system_config,
        .bt_allocator = config.bt_allocator,
    };
}

pub fn deinit(self: *Self) void {
    if (self.bt_host) |*bt_host| {
        bt_host.deinit();
    }
    if (self.audio_system) |*audio_system| {
        audio_system.deinit();
    }
    self.wifi_sta.deinit();
    self.display_device.deinit();
    self.* = undefined;
}

pub fn asBoard(self: *Self) Type {
    return Type.init(Self, self);
}

pub fn state(self: *Self) embed.board.State {
    return self.state_value;
}

pub fn powerOn(self: *Self) !void {
    try check("szp_board_init", binding.szp_board_init());
    try self.touch_device.init();
    self.state_value = .powered_on;
}

pub fn start(self: *Self) !void {
    if (self.state_value != .powered_on and self.state_value != .started) return error.InvalidState;
    self.state_value = .started;
}

pub fn initNvs(self: *Self) !void {
    _ = self;
    try check("szp_storage_init_nvs", binding.szp_storage_init_nvs());
}

pub fn mountStorage(self: *Self) !void {
    _ = self;
    try check("szp_storage_mount", binding.szp_storage_mount());
}

pub fn unmountStorage(self: *Self) void {
    _ = self;
    check("szp_storage_unmount", binding.szp_storage_unmount()) catch |err| {
        log.warn("storage unmount failed: {s}", .{@errorName(err)});
    };
}

pub fn storageInfo(self: *Self) !StorageInfo {
    _ = self;
    var total: usize = 0;
    var used: usize = 0;
    try check("szp_storage_info", binding.szp_storage_info(&total, &used));
    return .{ .total = total, .used = used };
}

pub fn initDisplay(self: *Self) !void {
    try self.display_device.init();
    try self.touch_device.init();
}

pub fn display(self: *Self, label: []const u8) !embed.drivers.Display {
    if (!esp.grt.std.mem.eql(u8, label, "display")) return error.NotFound;
    switch (self.state_value) {
        .powered_on, .started => {},
        else => return error.InvalidState,
    }
    try self.display_device.init();
    return self.display_device.handle();
}

pub fn singleButton(self: *Self, label: []const u8) !embed.drivers.button.Single {
    if (!esp.grt.std.mem.eql(u8, label, "button")) return error.NotFound;
    switch (self.state_value) {
        .powered_on, .started => {},
        else => return error.InvalidState,
    }
    return embed.drivers.button.Single.init(PowerButton, &self.power_button);
}

pub fn touch(self: *Self, label: []const u8) !embed.drivers.Touch {
    if (!esp.grt.std.mem.eql(u8, label, "touch")) return error.NotFound;
    switch (self.state_value) {
        .powered_on, .started => {},
        else => return error.InvalidState,
    }
    try self.touch_device.init();
    return self.touch_device.handle();
}

pub fn imu(self: *Self, label: []const u8) !embed.drivers.imu {
    if (!esp.grt.std.mem.eql(u8, label, "imu")) return error.NotFound;
    switch (self.state_value) {
        .powered_on, .started => {},
        else => return error.InvalidState,
    }
    try self.imu_device.init();
    return self.imu_device.handle();
}

pub fn wifiSta(self: *Self, label: []const u8) !embed.drivers.wifi.Sta {
    if (!esp.grt.std.mem.eql(u8, label, "wifi")) return error.NotFound;
    switch (self.state_value) {
        .powered_on, .started => {},
        else => return error.InvalidState,
    }
    try self.wifi_sta.init();
    return self.wifi_sta.handle();
}

pub fn btHost(self: *Self, label: []const u8) !embed.bt.Host {
    if (!esp.grt.std.mem.eql(u8, label, "bt")) return error.NotFound;
    switch (self.state_value) {
        .powered_on, .started => {},
        else => return error.InvalidState,
    }
    if (self.bt_host == null) {
        const allocator = self.bt_allocator orelse return error.InvalidState;
        self.bt_host = try BtHost.init(.{ .allocator = allocator, .source_id = 1 });
    }
    return self.bt_host.?.handle();
}

pub fn audioSystem(self: *Self, label: []const u8) !*Audio.Type {
    if (!esp.grt.std.mem.eql(u8, label, "audio")) return error.NotFound;
    switch (self.state_value) {
        .powered_on, .started => {},
        else => return error.InvalidState,
    }
    return self.ensureAudioSystem();
}

pub fn initAudio(self: *Self) !void {
    if (self.audio_ready) return;

    try check("szp_audio_init", binding.szp_audio_init());

    const i2c = try binding.i2cDevice(es8311_address);
    var codec = Es8311.init(i2c, .{
        .address = es8311_address,
        .codec_mode = .dac_only,
    });

    try codec.open();
    const chip_id = try codec.readChipId();
    log.info("es8311 chip_id=0x{x}", .{chip_id});
    try codec.setSampleRate(audio_sample_rate);
    try codec.setBitsPerSample(.@"16bit");
    try codec.setFormat(.i2s);
    try codec.enable(true);
    try codec.setVolume(default_volume);
    try codec.setMute(false);

    const adc_i2c = try binding.i2cDevice(es7210_address);
    var adc = Es7210.init(adc_i2c, .{
        .address = es7210_address,
        .mic_select = .{ .mic1 = true, .mic2 = true, .mic3 = true, .mic4 = true },
    });
    try adc.open();
    try adc.enable(true);
    try adc.setChannelGain(es7210_ref_channel, .@"0dB");

    self.audio_adc = adc;
    self.audio_codec = codec;
    try check("szp_audio_set_pa", binding.szp_audio_set_pa(true));
    self.audio_ready = true;
}

pub fn writePcm(self: *Self, samples: []const i16) !void {
    if (samples.len == 0) return;
    try self.initAudio();
    try check("szp_audio_write_i16", binding.szp_audio_write_i16(samples.ptr, samples.len));
}

pub fn startMicrophoneCapture(self: *Self) !void {
    try self.initAudio();
    try check("szp_audio_mic_capture_start", binding.szp_audio_mic_capture_start());
}

pub fn readMicrophoneFrame(self: *Self, mic0: []i16, mic1: []i16, ref: []i16) !usize {
    _ = self;
    if (mic0.len == 0) return 0;
    if (mic1.len < mic0.len or ref.len < mic0.len) return error.BoardCallFailed;
    var sample_count: usize = 0;
    try check("szp_audio_mic_read_i16", binding.szp_audio_mic_read_i16(mic0.ptr, mic1.ptr, ref.ptr, mic0.len, &sample_count));
    return sample_count;
}

pub fn stopMicrophoneCapture(self: *Self) void {
    _ = self;
    check("szp_audio_mic_capture_stop", binding.szp_audio_mic_capture_stop()) catch |err| {
        log.warn("mic capture stop failed: {s}", .{@errorName(err)});
    };
}

pub fn setVolume(self: *Self, volume: u8) !void {
    if (self.audio_codec == null) try self.initAudio();
    if (self.audio_codec) |*codec| {
        try codec.setVolume(volume);
        return;
    }
    return error.BoardCallFailed;
}

pub fn setSpeakerEnabled(self: *Self, enabled: bool) !void {
    if (enabled) try self.initAudio();
    if (!self.audio_ready and !enabled) return;
    try check("szp_audio_set_pa", binding.szp_audio_set_pa(enabled));
}

pub fn setMicrophoneGain(self: *Self, gain_db: i8) !void {
    if (self.audio_adc == null) try self.initAudio();
    if (self.audio_adc) |*adc| {
        try adc.setGainAll(microphoneGainFromDb(gain_db));
        try adc.setChannelGain(es7210_ref_channel, .@"0dB");
        return;
    }
    return error.BoardCallFailed;
}

fn ensureAudioSystem(self: *Self) !*Audio.Type {
    if (self.audio_system == null) {
        const allocator = self.audio_allocator orelse return error.InvalidState;
        var audio_system = try Audio.Type.init(allocator, self.audio_system_config);
        errdefer audio_system.deinit();

        self.audio_mic.bind(self);
        self.audio_speaker.bind(self);
        try audio_system.setMic(self.audio_mic.driver());
        try audio_system.setSpeaker(self.audio_speaker.driver());
        self.audio_system = audio_system;
    }
    return &(self.audio_system orelse unreachable);
}

fn check(name: []const u8, rc: c_int) !void {
    if (rc == binding.esp_ok) return;
    log.err("{s} failed with rc={d}", .{ name, rc });
    return error.BoardCallFailed;
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
