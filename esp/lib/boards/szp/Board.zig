const embed = @import("embed_core");
const esp = @import("esp");
const binding = @import("bindings/common.zig");
const Audio = @import("Audio.zig").Type;
const BtHost = esp.embed.bt.Local;
const Display = @import("Display.zig");
const Imu = @import("Imu.zig");
const PowerButton = @import("PowerButton.zig");
const Touch = @import("Touch.zig");
const Wifi = esp.embed.wifi.Local;

const Self = @This();
const log = esp.grt.std.log.scoped(.szp_board);
const audio_read_task_stack_size = 16 * 1024;
const audio_processor_task_stack_size = 24 * 1024;
const audio_write_task_stack_size = 8 * 1024;

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

power_button: PowerButton = .{},
display_device: Display = .{},
imu_device: Imu = .{},
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
    try check("szp_board_init", binding.szp_board_init());
    try check("szp_audio_set_pa", binding.szp_audio_set_pa(true));
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

fn check(name: []const u8, rc: c_int) !void {
    if (rc == binding.esp_ok) return;
    log.err("{s} failed with rc={d}", .{ name, rc });
    return error.BoardCallFailed;
}
