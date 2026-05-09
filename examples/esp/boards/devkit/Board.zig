const embed = @import("embed");
const esp = @import("esp");
const binding_common = @import("bindings/common.zig");
const led_strip_binding = @import("bindings/led_strip.zig");
const power_button_binding = @import("bindings/power_button.zig");
const LedStrip = @import("LedStrip.zig");
const PowerButton = @import("PowerButton.zig");
const WifiSta = @import("WifiSta.zig");

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
pub const InitConfig = struct {};

power_button: PowerButton = .{},
led_strip: LedStrip = .{},
wifi_sta: WifiSta = .{},
state_value: embed.board.State = .uninitialized,

pub fn init(config: InitConfig) !Self {
    _ = config;
    return .{};
}

pub fn deinit(self: *Self) void {
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
    if (!esp.grt.std.mem.eql(u8, label, "button")) return error.NotFound;
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

pub fn wifiSta(self: *Self, label: []const u8) !embed.drivers.wifi.Sta {
    if (!esp.grt.std.mem.eql(u8, label, "wifi")) return error.NotFound;
    switch (self.state_value) {
        .powered_on, .started => {},
        else => return error.InvalidState,
    }
    try self.wifi_sta.init();
    return self.wifi_sta.handle();
}

fn check(call_name: []const u8, rc: c_int) !void {
    if (rc == binding_common.esp_ok) return;

    esp.grt.std.log.scoped(.devkit_board).err("{s} failed with rc={d}", .{ call_name, rc });
    return error.BoardCallFailed;
}
