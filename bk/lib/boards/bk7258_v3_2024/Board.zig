const Def = @import("Definition.zig").Board(@import("bk_armino"));
const bk = @import("../../bk.zig");
const embed = @import("embed_core");
const Audio = @import("Audio.zig").Type;
const BtHost = bk.embed.bt.Local;
const Display = @import("Display.zig");
const Touch = bk.embed.touch.ArminoTouch;
const GpioPin = bk.embed.gpio.Pin;

const Board = @This();

pub const name = Def.name;
pub const chip = Def.chip;

pub const flashdb_kv_offset = Def.flashdb_kv_offset;
pub const flashdb_kv_size = Def.flashdb_kv_size;
pub const littlefs_offset = Def.littlefs_offset;
pub const littlefs_size_bytes = Def.littlefs_size_bytes;
pub const littlefs_size = Def.littlefs_size;
pub const littlefs_mount_path = Def.littlefs_mount_path;
pub const littlefs_source_dir = Def.littlefs_source_dir;

pub const AudioSystem = Audio.Type;
pub const ap = Def.ap;
pub const cp = Def.cp;
pub const partition_table = Def.partition_table;
pub const ram_regions = Def.ram_regions;
pub const Keys = bk.embed.saradc.ButtonGroup(.{
    .channel = .adc14,
    .ranges = &.{
        .{ .id = 2, .min_mv = 1, .max_mv = 100 }, // next
        .{ .id = 1, .min_mv = 800, .max_mv = 930 }, // previous
        .{ .id = 4, .min_mv = 1600, .max_mv = 1800 }, // menu
    },
});
pub const BootButton = bk.embed.saradc.Button(.{
    .channel = .adc14,
    .min_mv = 2400,
    .max_mv = 2600,
});

pub const InitConfig = struct {
    audio_allocator: ?bk.ap.grt.std.mem.Allocator = null,
    audio_system_config: Audio.Type.Config = .{},
    bt_allocator: ?bk.ap.grt.std.mem.Allocator = null,
};

display_device: Display = .{},
adc_group: Keys = .{},
switch_outputs: embed.board.SwitchOutputBank(8) = .{},
smoke_gpio: GpioPin = GpioPin.init(.{ .pin = 26 }),
audio: ?Audio = null,
audio_allocator: ?bk.ap.grt.std.mem.Allocator = null,
audio_system_config: Audio.Type.Config = .{},
bt_host: ?BtHost = null,
bt_allocator: ?bk.ap.grt.std.mem.Allocator = null,
boot_button_impl: BootButton = .{},
touch_impl: Touch = Touch.init(.{}),

pub fn init(config: InitConfig) !Board {
    return .{
        .audio_allocator = config.audio_allocator,
        .audio_system_config = config.audio_system_config,
        .bt_allocator = config.bt_allocator,
    };
}

pub fn deinit(self: *Board) void {
    if (self.bt_host) |*bt_host| {
        bt_host.deinit();
    }
    if (self.audio) |*audio| {
        audio.deinit();
    }
    self.display_device.deinit();
}

pub fn powerOn(_: *Board) !void {}

pub fn start(_: *Board) !void {}

pub fn display(self: *Board, label: []const u8) !embed.drivers.Display {
    if (!stringsEqual(label, "display")) return error.UnknownPeripheral;
    try self.display_device.init();
    return self.display_device.handle();
}

pub fn singleButton(self: *Board, label: []const u8) !embed.drivers.button.Single {
    if (!stringsEqual(label, "boot")) return error.UnknownPeripheral;
    try self.boot_button_impl.init();
    return self.boot_button_impl.handle();
}

pub fn groupedButton(self: *Board, label: []const u8) !embed.drivers.button.Grouped {
    if (!stringsEqual(label, "keys") and !stringsEqual(label, "controls")) return error.UnknownPeripheral;
    try self.adc_group.init();
    return self.adc_group.handle();
}

pub fn gpio(self: *Board, label: []const u8) !embed.drivers.Gpio {
    if (stringsEqual(label, "smoke")) return self.smoke_gpio.handle();
    return error.UnknownPeripheral;
}

pub fn switchOutput(self: *Board, label: []const u8) !embed.drivers.Switch {
    return self.switch_outputs.get(label);
}

pub fn touch(self: *Board, label: []const u8) !embed.drivers.Touch {
    if (!stringsEqual(label, "touch")) return error.UnknownPeripheral;
    try self.touch_impl.open();
    return self.touch_impl.handle();
}

pub fn btHost(self: *Board, label: []const u8) !embed.bt.Host {
    if (!stringsEqual(label, "bt")) return error.UnknownPeripheral;
    if (self.bt_host == null) {
        const allocator = self.bt_allocator orelse return error.InvalidState;
        self.bt_host = try BtHost.init(.{ .allocator = allocator, .source_id = 1 });
    }
    return self.bt_host.?.handle();
}

pub fn audioSystem(self: *Board, label: []const u8) !*Audio.Type {
    if (!stringsEqual(label, "audio")) return error.UnknownPeripheral;
    return self.ensureAudioSystem();
}

fn ensureAudioSystem(self: *Board) !*Audio.Type {
    if (self.audio == null) {
        const allocator = self.audio_allocator orelse return error.InvalidState;
        self.audio = try Audio.init(allocator, self.audio_system_config);
    }
    if (self.audio) |*audio| return audio.system();
    return error.InvalidState;
}

fn stringsEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |aa, bb| {
        if (aa != bb) return false;
    }
    return true;
}
