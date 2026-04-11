const Config = @import("assembler/Config.zig");
const assembler_builder = @import("assembler/Builder.zig");
const BuildContext = @import("assembler/BuildContext.zig");
const assembler_build_config = @import("assembler/BuildConfig.zig");
const NodeBuilder = @import("pipeline/NodeBuilder.zig");
const Store = @import("store.zig");
const registry_adc_button = @import("assembler/registry/adc_button.zig");
const registry_gpio_button = @import("assembler/registry/gpio_button.zig");
const registry_ledstrip = @import("assembler/registry/ledstrip.zig");

pub fn make(
    comptime lib: type,
    comptime config: Config,
    comptime Channel: fn (type) type,
) type {
    const StoreBuilderType = Store.Builder(config.store);
    const NodeBuilderType = NodeBuilder.Builder(config.node);
    const AdcButtonRegistryType = registry_adc_button.make(config.max_adc_buttons);
    const GpioButtonRegistryType = registry_gpio_button.make(config.max_gpio_buttons);
    const LedStripRegistryType = registry_ledstrip.make(config.max_led_strips);

    return struct {
        const Self = @This();

        store_builder: StoreBuilderType,
        node_builder: NodeBuilderType,
        adc_button_registry: AdcButtonRegistryType,
        gpio_button_registry: GpioButtonRegistryType,
        ledstrip_registry: LedStripRegistryType,

        pub const Lib = lib;
        pub const Config = config;
        pub const ChannelType = Channel;

        pub fn init() Self {
            return .{
                .store_builder = StoreBuilderType.init(),
                .node_builder = NodeBuilderType.init(),
                .adc_button_registry = AdcButtonRegistryType.init(),
                .gpio_button_registry = GpioButtonRegistryType.init(),
                .ledstrip_registry = LedStripRegistryType.init(),
            };
        }

        pub fn setStore(self: *Self, comptime label: anytype, comptime StoreType: type) void {
            self.store_builder.setStore(label, StoreType);
        }

        pub fn setState(self: *Self, comptime path: []const u8, comptime labels: anytype) void {
            self.store_builder.setState(path, labels);
        }

        pub fn addGroupedButton(
            self: *Self,
            comptime label: @Type(.enum_literal),
            comptime id: u32,
            comptime button_count: usize,
        ) void {
            self.adc_button_registry.add(label, id, button_count);
        }

        pub fn addSingleButton(
            self: *Self,
            comptime label: @Type(.enum_literal),
            comptime id: u32,
        ) void {
            self.gpio_button_registry.add(label, id);
        }

        pub fn addLedStrip(
            self: *Self,
            comptime label: @Type(.enum_literal),
            comptime id: u32,
            comptime pixel_count: usize,
        ) void {
            self.ledstrip_registry.add(label, id, pixel_count);
        }

        pub fn BuildConfig(comptime self: Self) type {
            return assembler_build_config.make(.{
                .adc_button = self.adc_button_registry,
                .gpio_button = self.gpio_button_registry,
                .ledstrip = self.ledstrip_registry,
            });
        }

        pub fn build(comptime self: Self, comptime build_config: self.BuildConfig()) type {
            return assembler_builder.init().build(BuildContext.make(.{
                .lib = lib,
                .assembler_config = config,
                .build_config = build_config,
                .registries = .{
                    .adc_button = self.adc_button_registry,
                    .gpio_button = self.gpio_button_registry,
                    .ledstrip = self.ledstrip_registry,
                },
                .store_builder = self.store_builder,
                .node_builder = self.node_builder,
                .channel = Channel,
            }));
        }

        pub fn node(self: *Self, comptime tag: @Type(.enum_literal)) void {
            self.node_builder.node(tag);
        }

        pub fn beginSwitch(self: *Self) void {
            self.node_builder.beginSwitch();
        }

        pub fn case(self: *Self, comptime kind: @import("pipeline/Message.zig").Kind) void {
            self.node_builder.case(kind);
        }

        pub fn endSwitch(self: *Self) void {
            self.node_builder.endSwitch();
        }
    };
}
