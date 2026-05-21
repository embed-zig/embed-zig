const NodeBuilder = @import("../pipeline/NodeBuilder.zig");
const Store = @import("../Store.zig");

const root = @This();

store: Store.BuilderOptions = .{},
node: NodeBuilder.BuilderOptions = .{},
max_adc_buttons: usize = 16,
max_bt_hosts: usize = 4,
max_audio_systems: usize = 4,
max_displays: usize = 4,
max_single_buttons: usize = 16,
max_imu: usize = 8,
max_led_strips: usize = 8,
max_modem: usize = 8,
max_nfc: usize = 8,
max_switches: usize = 8,
max_pwms: usize = 8,
max_touch: usize = 8,
max_wifi_sta: usize = 8,
max_wifi_ap: usize = 8,
max_handles: usize = Store.default_max_stores,
max_reducers: usize = Store.default_max_stores,
max_custom_events: usize = 16,
