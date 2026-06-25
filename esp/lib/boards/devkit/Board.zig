const embed = @import("embed_core");
const esp = @import("esp");
const binding_common = @import("bindings/common.zig");
const led_strip_binding = @import("bindings/led_strip.zig");
const power_button_binding = @import("bindings/power_button.zig");
const BtHost = esp.embed.bt.Local;
const LedStrip = @import("LedStrip.zig");
const PowerButton = @import("PowerButton.zig");
const Wifi = esp.embed.wifi.Local;

const Self = @This();

pub const Board = Self;
pub const metadata = embed.board.Metadata{
    .name = "devkit",
    .description = "ESP32-S3 devkit board with BOOT button and one addressable LED.",
    .vendor = "Espressif",
    .model = "ESP32-S3 DevKit",
    .chip = "esp32s3",
};
pub const Spec = embed.board.Spec{};
pub const Type = embed.board.Board.make(esp.grt, Spec);
pub const InitConfig = struct {
    bt_allocator: ?esp.grt.std.mem.Allocator = null,
};

power_button: PowerButton = .{},
led_strip: LedStrip = .{},
wifi_sta: Wifi.Sta = .{},
switch_outputs: embed.board.SwitchOutputBank(8) = .{},
bt_host: ?BtHost = null,
bt_allocator: ?esp.grt.std.mem.Allocator = null,
state_value: embed.board.State = .uninitialized,

pub fn init(config: InitConfig) !Self {
    return .{
        .bt_allocator = config.bt_allocator,
    };
}

pub fn deinit(self: *Self) void {
    if (self.bt_host) |*bt_host| {
        bt_host.deinit();
    }
    self.wifi_sta.deinit();
    self.* = undefined;
}

pub fn asBoard(self: *Self) Type {
    return Type.init(Self, self);
}

pub fn state(self: *Self) embed.board.State {
    return self.state_value;
}

pub fn powerOn(self: *Self) !void {
    try check("devkit_power_button_init", power_button_binding.devkit_power_button_init());
    try check("devkit_led_strip_init", led_strip_binding.devkit_led_strip_init());
    try check("devkit_led_strip_set_rgb", led_strip_binding.devkit_led_strip_set_rgb(0, 0, 0));
    self.state_value = .powered_on;
}

pub fn start(self: *Self) !void {
    if (self.state_value != .powered_on and self.state_value != .started) return error.InvalidState;
    self.state_value = .started;
}

pub fn singleButton(self: *Self, label: []const u8) !embed.drivers.button.Single {
    if (!esp.grt.std.mem.eql(u8, label, "boot")) return error.NotFound;
    switch (self.state_value) {
        .powered_on, .started => {},
        else => return error.InvalidState,
    }
    return embed.drivers.button.Single.init(PowerButton, &self.power_button);
}

pub fn ledStrip(self: *Self, label: []const u8) !embed.ledstrip.LedStrip {
    if (!esp.grt.std.mem.eql(u8, label, "strip")) return error.NotFound;
    switch (self.state_value) {
        .powered_on, .started => {},
        else => return error.InvalidState,
    }
    return self.led_strip.handle();
}

pub fn switchOutput(self: *Self, label: []const u8) !embed.drivers.Switch {
    switch (self.state_value) {
        .powered_on, .started => {},
        else => return error.InvalidState,
    }
    return self.switch_outputs.get(label);
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

fn check(call_name: []const u8, rc: c_int) !void {
    if (rc == binding_common.esp_ok) return;

    esp.grt.std.log.scoped(.devkit_board).err("{s} failed with rc={d}", .{ call_name, rc });
    return error.BoardCallFailed;
}
