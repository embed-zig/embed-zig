const Config = @import("assembler/Config.zig");
const assembler_builder = @import("assembler/Builder.zig");
const BuildContext = @import("assembler/BuildContext.zig");
const assembler_build_config = @import("assembler/BuildConfig.zig");
const NodeBuilder = @import("pipeline/NodeBuilder.zig");
const Store = @import("Store.zig");
const overlay = @import("component/ui/overlay.zig");
const selection = @import("component/ui/selection.zig");
const route = @import("component/ui/route.zig");
const registry_adc_button = @import("assembler/registry/adc_button.zig");
const registry_flow = @import("assembler/registry/flow.zig");
const registry_gpio_button = @import("assembler/registry/gpio_button.zig");
const registry_imu = @import("assembler/registry/imu.zig");
const registry_ledstrip = @import("assembler/registry/ledstrip.zig");
const registry_modem = @import("assembler/registry/modem.zig");
const registry_nfc = @import("assembler/registry/nfc.zig");
const registry_wifi_ap = @import("assembler/registry/wifi_ap.zig");
const registry_wifi_sta = @import("assembler/registry/wifi_sta.zig");
const registry_overlay = @import("assembler/registry/overlay.zig");
const registry_router = @import("assembler/registry/router.zig");
const registry_selection = @import("assembler/registry/selection.zig");
const registry_unique = @import("assembler/registry/unique.zig");

pub const ReducerFnFactory = @TypeOf(struct {
    fn factory(
        comptime Stores: type,
        comptime MessageType: type,
        comptime EmitterType: type,
    ) Store.Reducer.ReducerFnType(Stores, MessageType, EmitterType) {
        unreachable;
    }
}.factory);
pub const RenderFnFactory = @TypeOf(struct {
    fn factory(comptime ZuxApp: type, comptime path: []const u8) *const fn (*ZuxApp) anyerror!void {
        _ = path;
        unreachable;
    }
}.factory);
pub const FlowTypeFactory = @TypeOf(struct {
    fn factory() type {
        unreachable;
    }
}.factory);

pub fn make(
    comptime lib: type,
    comptime config: Config,
    comptime Channel: fn (type) type,
) type {
    const StoreBuilderType = Store.Builder(config.store);
    const NodeBuilderType = NodeBuilder.Builder(config.node);
    const ReducerFactoryType = ReducerFnFactory;
    const max_render_bindings = config.max_handles;
    const RenderBinding = struct {
        path: []const u8,
        AdapterType: type,
    };
    const ReducerBinding = struct {
        label: []const u8,
        name: []const u8,
        factory: ReducerFactoryType,
    };
    const AdcButtonRegistryType = registry_adc_button.make(config.max_adc_buttons);
    const FlowRegistryType = registry_flow.make(config.max_flows);
    const GpioButtonRegistryType = registry_gpio_button.make(config.max_gpio_buttons);
    const ImuRegistryType = registry_imu.make(config.max_imu);
    const LedStripRegistryType = registry_ledstrip.make(config.max_led_strips);
    const ModemRegistryType = registry_modem.make(config.max_modem);
    const NfcRegistryType = registry_nfc.make(config.max_nfc);
    const WifiStaRegistryType = registry_wifi_sta.make(config.max_wifi_sta);
    const WifiApRegistryType = registry_wifi_ap.make(config.max_wifi_ap);
    const OverlayRegistryType = registry_overlay.make(config.max_overlays);
    const RouterRegistryType = registry_router.make(config.max_routers);
    const SelectionRegistryType = registry_selection.make(config.max_selections);

    return struct {
        const Self = @This();

        store_builder: StoreBuilderType,
        node_builder: NodeBuilderType,
        adc_button_registry: AdcButtonRegistryType,
        flow_registry: FlowRegistryType,
        gpio_button_registry: GpioButtonRegistryType,
        imu_registry: ImuRegistryType,
        ledstrip_registry: LedStripRegistryType,
        modem_registry: ModemRegistryType,
        nfc_registry: NfcRegistryType,
        wifi_sta_registry: WifiStaRegistryType,
        wifi_ap_registry: WifiApRegistryType,
        overlay_registry: OverlayRegistryType,
        router_registry: RouterRegistryType,
        selection_registry: SelectionRegistryType,
        render_bindings: [max_render_bindings]RenderBinding = undefined,
        render_count: usize = 0,
        reducer_bindings: [config.max_reducers]ReducerBinding = undefined,
        reducer_count: usize = 0,

        pub const Lib = lib;
        pub const Config = config;
        pub const ChannelType = Channel;

        pub fn init() Self {
            return .{
                .store_builder = StoreBuilderType.init(),
                .node_builder = NodeBuilderType.init(),
                .adc_button_registry = AdcButtonRegistryType.init(),
                .flow_registry = FlowRegistryType.init(),
                .gpio_button_registry = GpioButtonRegistryType.init(),
                .imu_registry = ImuRegistryType.init(),
                .ledstrip_registry = LedStripRegistryType.init(),
                .modem_registry = ModemRegistryType.init(),
                .nfc_registry = NfcRegistryType.init(),
                .wifi_sta_registry = WifiStaRegistryType.init(),
                .wifi_ap_registry = WifiApRegistryType.init(),
                .overlay_registry = OverlayRegistryType.init(),
                .router_registry = RouterRegistryType.init(),
                .selection_registry = SelectionRegistryType.init(),
            };
        }

        pub fn setStore(self: *Self, comptime label: anytype, comptime StoreType: type) void {
            self.store_builder.setStore(label, StoreType);
        }

        pub fn setState(self: *Self, comptime path: []const u8, comptime labels: anytype) void {
            self.store_builder.setState(path, labels);
        }

        pub fn addRender(
            self: *Self,
            comptime path: []const u8,
            comptime factory: RenderFnFactory,
        ) void {
            const normalized_path = validateRenderPath(path);
            if (self.render_count >= self.render_bindings.len) {
                @compileError("zux.Assembler.addRender exceeded max_handles");
            }

            self.render_bindings[self.render_count] = .{
                .path = normalized_path,
                .AdapterType = makeRenderAdapter(normalized_path, factory),
            };
            self.render_count += 1;
        }

        pub fn addReducer(
            self: *Self,
            comptime label: anytype,
            comptime factory: ReducerFactoryType,
        ) void {
            const label_name = validateReducerLabel(label);

            if (nodeBuilderHasTag(self.node_builder, label_name)) {
                @compileError(
                    "zux.Assembler.addReducer label '" ++ label_name ++ "' is already used by node_builder; reducer nodes are wired automatically",
                );
            }
            if (self.reducer_count >= self.reducer_bindings.len) {
                @compileError("zux.Assembler.addReducer exceeded max_reducers");
            }
            if (hasReducerLabel(self, label_name)) {
                @compileError("zux.Assembler.addReducer duplicate reducer label '" ++ label_name ++ "'");
            }

            self.reducer_bindings[self.reducer_count] = .{
                .label = label_name,
                .name = label_name,
                .factory = factory,
            };
            self.reducer_count += 1;
        }

        pub fn addGroupedButton(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
            comptime button_count: usize,
        ) void {
            ensureComponentUnique(self, label, id);
            self.adc_button_registry.add(label, id, button_count);
        }

        pub fn addSingleButton(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
        ) void {
            ensureComponentUnique(self, label, id);
            self.gpio_button_registry.add(label, id);
        }

        pub fn addImu(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
        ) void {
            ensureComponentUnique(self, label, id);
            self.imu_registry.add(label, id);
        }

        pub fn addLedStrip(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
            comptime pixel_count: usize,
        ) void {
            ensureComponentUnique(self, label, id);
            self.ledstrip_registry.add(label, id, pixel_count);
        }

        pub fn addModem(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
        ) void {
            ensureComponentUnique(self, label, id);
            self.modem_registry.add(label, id);
        }

        pub fn addNfc(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
        ) void {
            ensureComponentUnique(self, label, id);
            self.nfc_registry.add(label, id);
        }

        pub fn addWifiSta(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
        ) void {
            ensureComponentUnique(self, label, id);
            self.wifi_sta_registry.add(label, id);
        }

        pub fn addWifiAp(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
        ) void {
            ensureComponentUnique(self, label, id);
            self.wifi_ap_registry.add(label, id);
        }

        pub fn addRouter(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
            comptime initial_item: route.Router.Item,
        ) void {
            ensureComponentUnique(self, label, id);
            self.router_registry.add(label, id, initial_item);
            self.store_builder.setStore(label, assembler_builder.makeRouterStoreType(lib, initial_item));
        }

        pub fn addFlow(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
            comptime FlowType: type,
        ) void {
            ensureComponentUnique(self, label, id);
            self.flow_registry.add(label, id, FlowType);
        }

        pub fn addOverlay(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
            comptime initial_state: overlay.State,
        ) void {
            ensureComponentUnique(self, label, id);
            self.overlay_registry.add(label, id, initial_state);
            self.store_builder.setStore(label, assembler_builder.makeOverlayStoreType(lib, initial_state));
        }

        pub fn addSelection(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
            comptime initial_state: selection.State,
        ) void {
            ensureComponentUnique(self, label, id);
            self.selection_registry.add(label, id, initial_state);
            self.store_builder.setStore(label, assembler_builder.makeSelectionStoreType(lib, initial_state));
        }

        pub fn BuildConfig(comptime self: Self) type {
            return assembler_build_config.make(.{
                .adc_button = self.adc_button_registry,
                .gpio_button = self.gpio_button_registry,
                .imu = self.imu_registry,
                .ledstrip = self.ledstrip_registry,
                .modem = self.modem_registry,
                .nfc = self.nfc_registry,
                .wifi_sta = self.wifi_sta_registry,
                .wifi_ap = self.wifi_ap_registry,
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
                    .imu = self.imu_registry,
                    .ledstrip = self.ledstrip_registry,
                    .modem = self.modem_registry,
                    .nfc = self.nfc_registry,
                    .wifi_sta = self.wifi_sta_registry,
                    .wifi_ap = self.wifi_ap_registry,
                },
                .flow_registry = self.flow_registry,
                .overlay_registry = self.overlay_registry,
                .router_registry = self.router_registry,
                .selection_registry = self.selection_registry,
                .store_builder = self.store_builder,
                .node_builder = self.node_builder,
                .render_bindings = self.render_bindings,
                .render_count = self.render_count,
                .reducer_bindings = self.reducer_bindings,
                .reducer_count = self.reducer_count,
                .channel = Channel,
            }));
        }

        pub fn addNode(self: *Self, comptime tag: anytype) void {
            self.node_builder.addNode(tag);
        }

        pub fn beginSwitch(self: *Self) void {
            self.node_builder.beginSwitch();
        }

        pub fn addCase(self: *Self, comptime kind: @import("pipeline/Message.zig").Kind) void {
            self.node_builder.addCase(kind);
        }

        pub fn endSwitch(self: *Self) void {
            self.node_builder.endSwitch();
        }

        pub fn node(self: *Self, comptime tag: anytype) void {
            self.addNode(tag);
        }

        pub fn case(self: *Self, comptime kind: @import("pipeline/Message.zig").Kind) void {
            self.addCase(kind);
        }

        fn ensureComponentUnique(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
        ) void {
            const label_name = registry_unique.labelText(label);
            registry_unique.ensureUniqueAcross(
                .{
                    self.adc_button_registry,
                    self.gpio_button_registry,
                    self.imu_registry,
                    self.ledstrip_registry,
                    self.modem_registry,
                    self.nfc_registry,
                    self.wifi_sta_registry,
                    self.wifi_ap_registry,
                    self.flow_registry,
                    self.overlay_registry,
                    self.router_registry,
                    self.selection_registry,
                },
                label_name,
                id,
                "zux.Assembler duplicate component label",
                "zux.Assembler duplicate component id",
            );
        }

        fn validateReducerLabel(comptime label: anytype) []const u8 {
            const label_name = registry_unique.labelText(label);
            if (label_name.len == 0) {
                @compileError("zux.Assembler.addReducer labels must not be empty");
            }
            return label_name;
        }

        fn hasReducerLabel(self: *Self, comptime label: []const u8) bool {
            inline for (0..self.reducer_count) |i| {
                if (comptimeEql(self.reducer_bindings[i].label, label)) return true;
            }
            return false;
        }

        fn nodeBuilderHasTag(node_builder: NodeBuilderType, comptime label: []const u8) bool {
            inline for (0..node_builder.tag_len) |i| {
                if (comptimeEql(node_builder.tags[i], label)) return true;
            }
            return false;
        }

        fn validateRenderPath(comptime path: []const u8) []const u8 {
            if (path.len == 0) {
                @compileError("zux.Assembler.addRender paths must not be empty");
            }
            if (path[0] == '/' or path[path.len - 1] == '/') {
                @compileError("zux.Assembler.addRender paths must not start or end with '/'");
            }

            comptime var segment_start: usize = 0;
            inline for (path, 0..) |ch, idx| {
                if (ch == '.') {
                    @compileError("zux.Assembler.addRender paths must use '/' separators instead of '.'");
                }
                if (ch == '/') {
                    if (idx == segment_start) {
                        @compileError("zux.Assembler.addRender paths must not contain empty segments");
                    }
                    segment_start = idx + 1;
                }
            }

            if (segment_start == path.len) {
                @compileError("zux.Assembler.addRender paths must not contain empty segments");
            }
            return path;
        }

        fn comptimeEql(comptime a: []const u8, comptime b: []const u8) bool {
            if (a.len != b.len) return false;
            inline for (a, 0..) |ch, idx| {
                if (ch != b[idx]) return false;
            }
            return true;
        }

        fn makeRenderAdapter(comptime path: []const u8, comptime factory: RenderFnFactory) type {
            return struct {
                const render_path = path;
                const render_factory = factory;

                pub fn makeSubscriber(comptime App: type, comptime Runtime: type, runtime: *Runtime) Store.Subscriber {
                    const gen = struct {
                        fn notifyFn(ctx: *anyopaque, notification: Store.Subscriber.Notification) void {
                            _ = notification;

                            const runtime_ptr: *Runtime = @ptrCast(@alignCast(ctx));
                            var app: App = undefined;
                            if (!@hasField(App, "runtime")) {
                                @compileError("zux.Assembler.addRender app adapter requires App.runtime");
                            }
                            @field(app, "runtime") = runtime_ptr;
                            if (@hasField(App, "started")) {
                                @field(app, "started") = true;
                            }
                            if (@hasField(App, "closed")) {
                                @field(app, "closed") = false;
                            }
                            if (@hasField(App, "last_event")) {
                                @field(app, "last_event") = null;
                            }
                            if (@hasField(App, "last_grouped_button_ids")) {
                                const Ids = @FieldType(App, "last_grouped_button_ids");
                                @field(app, "last_grouped_button_ids") = [_]?u32{null} ** @typeInfo(Ids).array.len;
                            }

                            const render_fn = render_factory(App, render_path);
                            render_fn(&app) catch |err| {
                                @panic(@errorName(err));
                            };
                        }

                        const vtable = Store.Subscriber.VTable{
                            .notify = notifyFn,
                        };
                    };

                    return .{
                        .ctx = runtime,
                        .vtable = &gen.vtable,
                    };
                }

            };
        }
    };
}
