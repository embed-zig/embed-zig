const embed = @import("embed_core");
const esp = @import("esp");
const binding = @import("bindings/common.zig");
const Audio = @import("Audio.zig").make(Self);
const BtHost = esp.embed.BtHost;
const Display = @import("Display.zig");
const PowerButton = @import("PowerButton.zig");
const Touch = @import("Touch.zig");
const WifiSta = @import("WifiSta.zig");

const Self = @This();
const Es8311 = embed.drivers.audio.Es8311;
const log = esp.grt.std.log.scoped(.wv_board);

pub const Board = Self;
pub const metadata = embed.board.Metadata{
    .name = "wv-esp32s3-touch-amoled-1.8",
    .description = "Waveshare ESP32-S3 Touch AMOLED 1.8 board with AMOLED display, touch, ES8311 audio, BOOT button, and Wi-Fi.",
    .vendor = "Waveshare",
    .model = "ESP32-S3-Touch-AMOLED-1.8",
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

const es8311_address = @intFromEnum(Es8311.Address.ad0_low);
const default_volume: u8 = 0xb0;
const default_mic_gain_db: i8 = 24;

power_button: PowerButton = .{},
display_device: Display = .{},
touch_device: Touch = .{},
wifi_sta: WifiSta = .{},
bt_host: ?BtHost = null,
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
    binding.boardInit() catch |err| {
        binding.logError("wv_board_init", err);
        return error.BoardCallFailed;
    };
    try check("wv_power_button_init", binding.wv_power_button_init());
    self.state_value = .powered_on;
}

pub fn start(self: *Self) !void {
    if (self.state_value != .powered_on and self.state_value != .started) return error.InvalidState;
    self.state_value = .started;
}

pub fn initNvs(self: *Self) !void {
    _ = self;
    try check("wv_storage_init_nvs", binding.wv_storage_init_nvs());
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

    try check("wv_audio_init", binding.wv_audio_init());

    const i2c = try binding.i2cDevice(es8311_address);
    var codec = Es8311.init(i2c, .{
        .address = es8311_address,
        .codec_mode = .both,
        .no_dac_ref = true,
    });

    try codec.open();
    const chip_id = try codec.readChipId();
    log.info("es8311 chip_id=0x{x}", .{chip_id});
    try codec.setSampleRate(audio_sample_rate);
    try codec.setBitsPerSample(.@"16bit");
    try codec.setFormat(.i2s);
    try codec.setMicGainDb(default_mic_gain_db);
    try codec.enable(true);
    try codec.setVolume(default_volume);
    try codec.setMute(false);

    self.audio_codec = codec;
    try check("wv_audio_set_pa", binding.wv_audio_set_pa(true));
    self.audio_ready = true;
}

pub fn writePcm(self: *Self, samples: []const i16) !void {
    if (samples.len == 0) return;
    try self.initAudio();
    try check("wv_audio_write_i16", binding.wv_audio_write_i16(samples.ptr, samples.len));
}

pub fn startMicrophoneCapture(self: *Self) !void {
    try self.initAudio();
    try check("wv_audio_mic_capture_start", binding.wv_audio_mic_capture_start());
}

pub fn readMicrophoneFrame(self: *Self, mic0: []i16) !usize {
    _ = self;
    if (mic0.len == 0) return 0;
    var sample_count: usize = 0;
    try check("wv_audio_mic_read_i16", binding.wv_audio_mic_read_i16(mic0.ptr, mic0.len, &sample_count));
    return sample_count;
}

pub fn stopMicrophoneCapture(self: *Self) void {
    _ = self;
    check("wv_audio_mic_capture_stop", binding.wv_audio_mic_capture_stop()) catch |err| {
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
    try check("wv_audio_set_pa", binding.wv_audio_set_pa(enabled));
}

pub fn setMicrophoneGain(self: *Self, gain_db: i8) !void {
    if (self.audio_codec == null) try self.initAudio();
    if (self.audio_codec) |*codec| {
        try codec.setMicGainDb(gain_db);
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
