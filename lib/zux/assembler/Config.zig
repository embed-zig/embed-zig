const embed = @import("embed");
const NodeBuilder = @import("../pipeline/NodeBuilder.zig");
const Poller = @import("../pipeline/Poller.zig");
const Store = @import("../store.zig");

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
max_led_strips: usize = 8,
