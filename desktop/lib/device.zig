pub const audio_system = @import("device/audio_system.zig");
pub const bt_host = @import("device/bt_host.zig");
pub const display = @import("device/display.zig");
pub const grouped_button = @import("device/grouped_button.zig");
pub const ledstrip = @import("device/ledstrip.zig");
pub const modem = @import("device/modem.zig");
pub const nfc = @import("device/nfc.zig");
pub const single_button = @import("device/single_button.zig");
pub const switch_output = @import("device/switch_output.zig");
pub const touch = @import("device/touch.zig");
pub const wifi_sta = @import("device/wifi_sta.zig");
pub const test_runner = struct {
    pub const unit = @import("device/test_runner/unit.zig");
};
