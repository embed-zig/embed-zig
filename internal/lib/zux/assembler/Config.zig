const embed = @import("embed");
const NodeBuilder = @import("../pipeline/NodeBuilder.zig");
const Poller = @import("../pipeline/Poller.zig");
const Store = @import("../Store.zig");

const root = @This();

store: Store.BuilderOptions = .{},
node: NodeBuilder.BuilderOptions = .{},
pipeline: struct {
    tick_interval_ns: u64 = 10 * embed.time.ns_per_ms,
    spawn_config: embed.Thread.SpawnConfig = .{},
} = .{},
poller: Poller.Config = .{},
max_adc_buttons: usize = 16,
max_gpio_buttons: usize = 16,
max_imu: usize = 8,
max_led_strips: usize = 8,
max_modem: usize = 8,
max_nfc: usize = 8,
max_wifi_sta: usize = 8,
max_wifi_ap: usize = 8,
max_flows: usize = 8,
max_overlays: usize = 8,
max_routers: usize = 4,
max_selections: usize = 8,
max_handles: usize = Store.default_max_stores,
max_reducers: usize = Store.default_max_stores,
