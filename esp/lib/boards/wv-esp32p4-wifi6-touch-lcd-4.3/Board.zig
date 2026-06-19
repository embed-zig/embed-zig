const embed = @import("embed_core");
const esp = @import("esp");
const binding = @import("bindings/common.zig");
const BtHost = esp.embed.bt.Remote;
const Display = @import("Display.zig");
const HostedCopro = esp.embed.HostedCopro;
const PowerButton = @import("PowerButton.zig");
const Touch = @import("Touch.zig");
const Wifi = esp.embed.wifi.Remote;

const Self = @This();
const Es7210 = embed.drivers.audio.Es7210;
const Es8311 = embed.drivers.audio.Es8311;
const log = esp.grt.std.log.scoped(.wv_p4_board);
const audio_read_task_stack_size = 16 * 1024;
const audio_processor_task_stack_size = 24 * 1024;
const audio_write_task_stack_size = 8 * 1024;
const Audio = esp.embed.audio_adapter.Es8311Es7210System.make(.{
    .sample_rate = 16_000,
    .frame_samples_per_channel = 256,
    .mic_count = 2,
    .i2c = .{
        .port = 0,
        .sda_io_num = 7,
        .scl_io_num = 8,
        .scl_speed_hz = 200_000,
    },
    .i2s = .{
        .port = 0,
        .mclk_gpio = 13,
        .bclk_gpio = 12,
        .ws_gpio = 10,
        .dout_gpio = 9,
        .din_gpio = 11,
    },
    .i2s_data_bit_width = .@"32bit",
    .i2s_slot_mode = .stereo,
    .es8311 = .{ .address = @intFromEnum(Es8311.Address.ad0_low) },
    .es7210 = .{
        .address = @intFromEnum(Es7210.Address.ad1_ad0_00),
        .mic_select = .{ .mic1 = true, .mic2 = true, .mic3 = true },
        .ref_channel = 2,
    },
    .capture = .{
        .raw_channel_count = 4,
        .ref_lane = 0,
        .mic_lanes = .{ 1, 3 },
    },
    .default_volume = 0xb0,
    .default_mic_gain_db = 24,
    .esp_sr = .{
        .monitor_gain = 3,
        .speech_enhancement = true,
    },
    .use_i2s_adapters = true,
    .i2s_adapters = .{
        .rx = .{
            .slots_per_frame = 4,
            .bytes_per_slot = @sizeOf(i16),
            .ref_channel = .{ .slot = 0 },
            .mic_channels = .{
                .{ .slot = 1 },
                .{ .slot = 3 },
            },
        },
        .tx = .{
            .slots_per_frame = 2,
            .bytes_per_slot = @sizeOf(i32),
            .speaker_slots = &.{
                .{ .index = 0, .sample_align = .msb },
                .{ .index = 1, .sample_align = .msb },
            },
        },
    },
});
const hosted_copro_config = HostedCopro.Config{
    .partition_label = "slave_fw",
    .expected_version = .{
        .major = 2,
        .minor = 12,
        .patch = 8,
    },
};

pub const Board = Self;
pub const metadata = embed.board.Metadata{
    .name = "wv-esp32p4-wifi6-touch-lcd-4.3",
    .description = "Waveshare ESP32-P4 WIFI6 Touch LCD 4.3 board with MIPI DSI display, ES8311 audio, BOOT button, Wi-Fi, and BT.",
    .vendor = "Waveshare",
    .model = "ESP32-P4-WIFI6-Touch-LCD-4.3",
    .chip = "esp32p4",
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

power_button: PowerButton = .{},
display_device: Display = .{},
touch_device: Touch = .{},
wifi_sta: Wifi.Sta = .{},
bt_host: ?BtHost = null,
audio: ?Audio = null,
audio_allocator: ?esp.grt.std.mem.Allocator = null,
audio_system_config: Audio.Type.Config = .{},
bt_allocator: ?esp.grt.std.mem.Allocator = null,
state_value: embed.board.State = .uninitialized,

pub fn init(config: InitConfig) !Self {
    var audio_system_config = config.audio_system_config;
    applyDefaultAudioTaskOptions(&audio_system_config);

    return .{
        .audio_allocator = config.audio_allocator,
        .audio_system_config = audio_system_config,
        .bt_allocator = config.bt_allocator,
    };
}

pub fn deinit(self: *Self) void {
    if (self.bt_host) |*bt_host| {
        bt_host.deinit();
    }
    if (self.audio) |*audio| {
        audio.deinit();
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
    try check("wv_p4_board_init", binding.wv_p4_board_init());
    try check("wv_p4_power_button_init", binding.wv_p4_power_button_init());
    try check("wv_p4_audio_set_pa", binding.wv_p4_audio_set_pa(true));
    self.state_value = .powered_on;
}

pub fn start(self: *Self) !void {
    if (self.state_value != .powered_on and self.state_value != .started) return error.InvalidState;
    try HostedCopro.ensureReady(hosted_copro_config);
    self.state_value = .started;
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
    if (!esp.grt.std.mem.eql(u8, label, "boot")) return error.NotFound;
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

fn ensureAudioSystem(self: *Self) !*Audio.Type {
    if (self.audio == null) {
        const allocator = self.audio_allocator orelse return error.InvalidState;
        self.audio = try Audio.init(allocator, self.audio_system_config);
    }
    if (self.audio) |*audio| return audio.system();
    return error.InvalidState;
}

fn applyDefaultAudioTaskOptions(config: *Audio.Type.Config) void {
    if (config.read_task.min_stack_size == 0) {
        config.read_task.min_stack_size = audio_read_task_stack_size;
    }
    if (config.processor_task.min_stack_size == 0) {
        config.processor_task.min_stack_size = audio_processor_task_stack_size;
    }
    if (config.write_task.min_stack_size == 0) {
        config.write_task.min_stack_size = audio_write_task_stack_size;
    }
}

fn check(call_name: []const u8, rc: c_int) !void {
    if (rc == binding.esp_ok) return;
    log.err("{s} failed with rc={d}", .{ call_name, rc });
    return error.BoardCallFailed;
}
