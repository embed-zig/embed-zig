const glib = @import("glib");
const builtin = glib.std.builtin;
const drivers = @import("drivers");
const ledstrip = @import("ledstrip");
const modem_api = drivers;

const App = @import("../App.zig");
const button = @import("../component/button.zig");
const component_imu = @import("../component/Imu.zig");
const component_modem = @import("../component/modem.zig");
const component_nfc = @import("../component/Nfc.zig");
const component_wifi = @import("../component/wifi.zig");
const ledstrip_component = @import("../component/ledstrip.zig");
const flow_component = @import("../component/ui/flow.zig");
const overlay_component = @import("../component/ui/overlay.zig");
const selection_component = @import("../component/ui/selection.zig");
const route_component = @import("../component/ui/route.zig");
const Emitter = @import("../pipeline/Emitter.zig");
const Message = @import("../pipeline/Message.zig");
const Node = @import("../pipeline/Node.zig");
const Poller = @import("../pipeline/Poller.zig");
const Pipeline = @import("../pipeline/Pipeline.zig");
const store = @import("../Store.zig");
const build_config = @import("BuildConfig.zig");

const root = @This();

pub fn init() root {
    return .{};
}

pub fn makeRouterStoreType(comptime lib: type, comptime initial: route_component.Router.Item) type {
    const Inner = route_component.Reducer.make(lib);

    return struct {
        const Self = @This();

        inner: Inner,

        pub fn init(allocator: lib.mem.Allocator, _: anytype) !Self {
            return .{
                .inner = try Inner.init(allocator, initial),
            };
        }

        pub fn deinit(self: *Self) void {
            self.inner.deinit();
        }

        pub fn get(self: *Self) Inner.StateType {
            return self.inner.get();
        }

        pub fn router(self: *Self) route_component.Router {
            return self.inner.router();
        }

        pub fn subscribe(self: *Self, subscriber: anytype) error{OutOfMemory}!void {
            try self.inner.subscribe(subscriber);
        }

        pub fn unsubscribe(self: *Self, subscriber: anytype) bool {
            return self.inner.unsubscribe(subscriber);
        }

        pub fn tick(self: *Self) void {
            self.inner.tick();
        }

        pub fn reduce(self: anytype, message: Message, emit: Emitter) !usize {
            return Inner.reduce(&self.inner, message, emit);
        }
    };
}

pub fn makeSelectionStoreType(comptime lib: type, comptime initial: selection_component.State) type {
    const Inner = selection_component.Reducer.make(lib);

    return struct {
        const Self = @This();

        inner: Inner,

        pub fn init(allocator: lib.mem.Allocator, _: anytype) Self {
            return .{
                .inner = Inner.init(allocator, initial),
            };
        }

        pub fn deinit(self: *Self) void {
            self.inner.deinit();
        }

        pub fn get(self: *Self) Inner.StateType {
            return self.inner.get();
        }

        pub fn subscribe(self: *Self, subscriber: anytype) error{OutOfMemory}!void {
            try self.inner.subscribe(subscriber);
        }

        pub fn unsubscribe(self: *Self, subscriber: anytype) bool {
            return self.inner.unsubscribe(subscriber);
        }

        pub fn tick(self: *Self) void {
            self.inner.tick();
        }

        pub fn reduce(self: anytype, message: Message, emit: Emitter) !usize {
            return Inner.reduce(&self.inner, message, emit);
        }
    };
}

pub fn makeFlowStoreType(comptime lib: type, comptime FlowType: type) type {
    const Inner = FlowType.Reducer(lib);

    return struct {
        const Self = @This();

        inner: Inner,

        pub fn init(allocator: lib.mem.Allocator, _: anytype) Self {
            return .{
                .inner = Inner.init(allocator, FlowType.initialState()),
            };
        }

        pub fn deinit(self: *Self) void {
            self.inner.deinit();
        }

        pub fn get(self: *Self) Inner.StateType {
            return self.inner.get();
        }

        pub fn subscribe(self: *Self, subscriber: anytype) error{OutOfMemory}!void {
            try self.inner.subscribe(subscriber);
        }

        pub fn unsubscribe(self: *Self, subscriber: anytype) bool {
            return self.inner.unsubscribe(subscriber);
        }

        pub fn tick(self: *Self) void {
            self.inner.tick();
        }

        pub fn reduce(self: anytype, message: Message, emit: Emitter) !usize {
            return Inner.reduce(&self.inner, message, emit);
        }
    };
}

pub fn makeOverlayStoreType(comptime lib: type, comptime initial: overlay_component.State) type {
    const Inner = overlay_component.Reducer.make(lib);

    return struct {
        const Self = @This();

        inner: Inner,

        pub fn init(allocator: lib.mem.Allocator, _: anytype) Self {
            return .{
                .inner = Inner.init(allocator, initial),
            };
        }

        pub fn deinit(self: *Self) void {
            self.inner.deinit();
        }

        pub fn get(self: *Self) Inner.StateType {
            return self.inner.get();
        }

        pub fn subscribe(self: *Self, subscriber: anytype) error{OutOfMemory}!void {
            try self.inner.subscribe(subscriber);
        }

        pub fn unsubscribe(self: *Self, subscriber: anytype) bool {
            return self.inner.unsubscribe(subscriber);
        }

        pub fn tick(self: *Self) void {
            self.inner.tick();
        }

        pub fn reduce(self: anytype, message: Message, emit: Emitter) !usize {
            return Inner.reduce(&self.inner, message, emit);
        }
    };
}

pub fn build(builder: root, comptime context: anytype) type {
    _ = builder;

    comptime {
        @setEvalBranchQuota(20_000);
    }

    const GeneratedBuildConfig = build_config.make(context.registries);
    comptime {
        if (@TypeOf(context.build_config) != GeneratedBuildConfig) {
            @compileError("zux.assembler.Builder.build BuildContext.build_config does not match generated BuildConfig");
        }
    }

    const adc_registry = context.registries.adc_button;
    const gpio_registry = context.registries.gpio_button;
    const imu_registry = context.registries.imu;
    const ledstrip_registry = context.registries.ledstrip;
    const modem_registry = context.registries.modem;
    const nfc_registry = context.registries.nfc;
    const wifi_sta_registry = context.registries.wifi_sta;
    const wifi_ap_registry = context.registries.wifi_ap;
    const flow_registry = context.flow_registry;
    const overlay_registry = context.overlay_registry;
    const router_registry = context.router_registry;
    const selection_registry = context.selection_registry;
    const adc_count = registryPeriphLen(adc_registry);
    const gpio_count = registryPeriphLen(gpio_registry);
    const imu_count = registryPeriphLen(imu_registry);
    const ledstrip_count = registryPeriphLen(ledstrip_registry);
    const modem_count = registryPeriphLen(modem_registry);
    const nfc_count = registryPeriphLen(nfc_registry);
    const wifi_sta_count = registryPeriphLen(wifi_sta_registry);
    const wifi_ap_count = registryPeriphLen(wifi_ap_registry);
    const flow_count = registryPeriphLen(flow_registry);
    const overlay_count = registryPeriphLen(overlay_registry);
    const router_count = registryPeriphLen(router_registry);
    const selection_count = registryPeriphLen(selection_registry);
    const configured_render_count = context.render_count;
    const configured_reducer_count = context.reducer_count;
    const has_button_runtime = (adc_count + gpio_count) > 0;
    const has_imu_runtime = imu_count > 0;
    const has_ledstrip_runtime = ledstrip_count > 0;
    const has_modem_runtime = modem_count > 0;
    const has_nfc_runtime = nfc_count > 0;
    const has_wifi_sta_runtime = wifi_sta_count > 0;
    const has_wifi_ap_runtime = wifi_ap_count > 0;
    const has_flow_runtime = flow_count > 0;
    const has_overlay_runtime = overlay_count > 0;
    const has_router_runtime = router_count > 0;
    const has_selection_runtime = selection_count > 0;
    const has_user_root_config = context.node_builder.len > 0;
    const runtime_poller_count = totalPollerCount(context.registries);
    const ledstrip_pixel_count = ledStripPixelCount(ledstrip_registry);
    const ledstrip_frame_capacity = ledStripFrameCapacity(ledstrip_registry);
    const runtime_pipeline_config: Pipeline.Config(context.lib) = .{
        .tick_interval_ns = context.assembler_config.pipeline.tick_interval_ns,
        .spawn_config = adaptSpawnConfig(
            context.lib.Thread.SpawnConfig,
            context.assembler_config.pipeline.spawn_config,
        ),
    };

    const runtime_store_builder = makeRuntimeStoreBuilder(context);
    const StoreType = runtime_store_builder.make(context.lib);

    const UserRoot = if (has_user_root_config) context.node_builder.make() else void;
    const runtime_node_builder = makeRuntimeNodeBuilder(context);
    const BuiltRoot = runtime_node_builder.make();

    const SingleButtonInstances = makePeriphInstancesType(context.build_config, gpio_registry);
    const GroupedButtonInstances = makePeriphInstancesType(context.build_config, adc_registry);
    const ImuInstances = makePeriphInstancesType(context.build_config, imu_registry);
    const LedStripInstances = makePeriphInstancesType(context.build_config, ledstrip_registry);
    const ModemInstances = makePeriphInstancesType(context.build_config, modem_registry);
    const NfcInstances = makePeriphInstancesType(context.build_config, nfc_registry);
    const WifiStaInstances = makePeriphInstancesType(context.build_config, wifi_sta_registry);
    const WifiApInstances = makePeriphInstancesType(context.build_config, wifi_ap_registry);
    const GeneratedInitConfig = makeInitConfigType(
        context.lib,
        context.build_config,
        context.registries,
        has_user_root_config,
        if (has_user_root_config) UserRoot.Config else void,
    );

    const AppLabel = makeLabelEnum(context.registries);
    const GeneratedFlowLabel = makeSingleRegistryLabelEnum(flow_registry);
    const GeneratedOverlayLabel = makeSingleRegistryLabelEnum(overlay_registry);
    const GeneratedRouterLabel = makeSingleRegistryLabelEnum(router_registry);
    const GeneratedSelectionLabel = makeSingleRegistryLabelEnum(selection_registry);
    const periph_ids = makePeriphIdTable(context.registries);
    const periph_kinds = makePeriphKindTable(context.registries);
    const runtime_poller_config: Poller.Config = context.assembler_config.poller;
    const SingleButtonPoller = button.SinglePoller.make(context.lib);
    const GroupedButtonPoller = button.GroupedPoller.make(context.lib);
    const ImuPollerType = component_imu.Poller.make(context.lib);
    const ImuPollerWrapper = if (has_imu_runtime) struct {
        inner: ImuPollerType,

        pub fn bindOutput(self: *@This(), out: Emitter) void {
            self.inner.bindOutput(out);
        }

        pub fn start(self: *@This(), config: Poller.Config) !void {
            self.inner.poll_interval_ns = config.poll_interval_ns;
            self.inner.spawn_config = adaptSpawnConfig(
                context.lib.Thread.SpawnConfig,
                config.spawn_config,
            );
            try self.inner.start();
        }

        pub fn stop(self: *@This()) void {
            self.inner.stop();
        }

        pub fn deinit(self: *@This()) void {
            self.inner.deinit();
        }
    } else void;
    const LedStripReducerType = if (has_ledstrip_runtime)
        ledstrip_component.Reducer.make(
            ledstrip_pixel_count,
            ledstrip_frame_capacity,
            runtime_pipeline_config.tick_interval_ns,
        )
    else
        void;
    const BuiltPipeline = Pipeline.make(context.lib, context.channel, runtime_pipeline_config);
    const PipelineSink = struct {
        pipeline: *BuiltPipeline,

        pub fn emit(self: *@This(), message: Message) !void {
            try self.pipeline.inject(message);
        }
    };
    const StoreReducerType = store.Reducer.make(StoreType);
    const StoreTickNode = struct {
        store: *StoreType,
        out: ?Emitter = null,

        pub fn node(self: *@This()) Node {
            return Node.init(@This(), self);
        }

        pub fn bindOutput(self: *@This(), out: Emitter) void {
            self.out = out;
        }

        pub fn process(self: *@This(), message: Message) !usize {
            if (message.body == .tick) {
                self.store.tick();
            }
            if (self.out) |out| {
                try out.emit(message);
                return 1;
            }
            return 0;
        }
    };
    const NfcStoreReducerNode = if (has_nfc_runtime) struct {
        stores: *StoreType.Stores,
        out: ?Emitter = null,

        pub fn node(self: *@This()) Node {
            return Node.init(@This(), self);
        }

        pub fn bindOutput(self: *@This(), out: Emitter) void {
            self.out = out;
        }

        pub fn process(self: *@This(), message: Message) !usize {
            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };

            var noop = NoopSink{};
            const emit = self.out orelse Emitter.init(&noop);
            switch (message.body) {
                .nfc_found,
                .nfc_read,
                => {
                    inline for (0..nfc_count) |i| {
                        const periph = nfc_registry.periphs[i];
                        if (messageSourceId(message) == periphIdForRecord(periph)) {
                            return component_nfc.Reducer.reduce(
                                &@field(self.stores, periphLabel(periph)),
                                message,
                                emit,
                            );
                        }
                    }
                    return 0;
                },
                .tick => {
                    if (self.out) |out| {
                        try out.emit(message);
                        return 1;
                    }
                    return 0;
                },
                else => {
                    if (self.out) |out| {
                        try out.emit(message);
                        return 1;
                    }
                    return 0;
                },
            }
        }
    } else void;
    const ModemStoreReducerNode = if (has_modem_runtime) struct {
        stores: *StoreType.Stores,
        reducer: *component_modem.Reducer,
        out: ?Emitter = null,

        pub fn node(self: *@This()) Node {
            return Node.init(@This(), self);
        }

        pub fn bindOutput(self: *@This(), out: Emitter) void {
            self.out = out;
        }

        pub fn process(self: *@This(), message: Message) !usize {
            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };

            var noop = NoopSink{};
            const emit = self.out orelse Emitter.init(&noop);
            switch (message.body) {
                .modem_sim_state_changed,
                .modem_network_registration_changed,
                .modem_network_signal_changed,
                .modem_data_packet_state_changed,
                .modem_data_apn_changed,
                .modem_call_incoming,
                .modem_call_state_changed,
                .modem_call_ended,
                .modem_sms_received,
                .modem_gnss_state_changed,
                .modem_gnss_fix_changed,
                => {
                    inline for (0..modem_count) |i| {
                        const periph = modem_registry.periphs[i];
                        if (messageSourceId(message) == periphIdForRecord(periph)) {
                            return self.reducer.reduce(
                                &@field(self.stores, periphLabel(periph)),
                                message,
                                emit,
                            );
                        }
                    }
                    return 0;
                },
                .tick => {
                    if (self.out) |out| {
                        try out.emit(message);
                        return 1;
                    }
                    return 0;
                },
                else => {
                    if (self.out) |out| {
                        try out.emit(message);
                        return 1;
                    }
                    return 0;
                },
            }
        }
    } else void;
    const WifiStaStoreReducerNode = if (has_wifi_sta_runtime) struct {
        stores: *StoreType.Stores,
        reducer: *component_wifi.StaReducer,
        out: ?Emitter = null,

        pub fn node(self: *@This()) Node {
            return Node.init(@This(), self);
        }

        pub fn bindOutput(self: *@This(), out: Emitter) void {
            self.out = out;
        }

        pub fn process(self: *@This(), message: Message) !usize {
            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };

            var noop = NoopSink{};
            const emit = self.out orelse Emitter.init(&noop);
            switch (message.body) {
                .wifi_sta_scan_result,
                .wifi_sta_connected,
                .wifi_sta_disconnected,
                .wifi_sta_got_ip,
                .wifi_sta_lost_ip,
                => {
                    inline for (0..wifi_sta_count) |i| {
                        const periph = wifi_sta_registry.periphs[i];
                        if (messageSourceId(message) == periphIdForRecord(periph)) {
                            return self.reducer.reduce(
                                &@field(self.stores, periphLabel(periph)),
                                message,
                                emit,
                            );
                        }
                    }
                    return 0;
                },
                .tick => {
                    if (self.out) |out| {
                        try out.emit(message);
                        return 1;
                    }
                    return 0;
                },
                else => {
                    if (self.out) |out| {
                        try out.emit(message);
                        return 1;
                    }
                    return 0;
                },
            }
        }
    } else void;
    const WifiApStoreReducerNode = if (has_wifi_ap_runtime) struct {
        stores: *StoreType.Stores,
        reducers: *[wifi_ap_count]component_wifi.ApReducer,
        out: ?Emitter = null,

        pub fn node(self: *@This()) Node {
            return Node.init(@This(), self);
        }

        pub fn bindOutput(self: *@This(), out: Emitter) void {
            self.out = out;
        }

        pub fn process(self: *@This(), message: Message) !usize {
            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };

            var noop = NoopSink{};
            const emit = self.out orelse Emitter.init(&noop);
            switch (message.body) {
                .wifi_ap_started,
                .wifi_ap_stopped,
                .wifi_ap_client_joined,
                .wifi_ap_client_left,
                .wifi_ap_lease_granted,
                .wifi_ap_lease_released,
                => {
                    inline for (0..wifi_ap_count) |i| {
                        const periph = wifi_ap_registry.periphs[i];
                        if (messageSourceId(message) == periphIdForRecord(periph)) {
                            return self.reducers[i].reduce(
                                &@field(self.stores, periphLabel(periph)),
                                message,
                                emit,
                            );
                        }
                    }
                    return 0;
                },
                .tick => {
                    if (self.out) |out| {
                        try out.emit(message);
                        return 1;
                    }
                    return 0;
                },
                else => {
                    if (self.out) |out| {
                        try out.emit(message);
                        return 1;
                    }
                    return 0;
                },
            }
        }
    } else void;

    const Impl = struct {
        const Self = @This();

        pub const Lib = context.lib;
        pub const Config = context.assembler_config;
        pub const BuildConfig = @TypeOf(context.build_config);
        pub const build_config = context.build_config;
        pub const pipeline_config = runtime_pipeline_config;
        pub const registries = .{
            .adc_button = adc_registry,
            .gpio_button = gpio_registry,
            .imu = imu_registry,
            .ledstrip = ledstrip_registry,
            .modem = modem_registry,
            .nfc = nfc_registry,
            .wifi_sta = wifi_sta_registry,
            .wifi_ap = wifi_ap_registry,
            .flow = flow_registry,
            .overlay = overlay_registry,
            .router = router_registry,
            .selection = selection_registry,
        };
        pub const InitConfig = GeneratedInitConfig;
        pub const StartConfig = App.StartConfig;
        pub const Store = StoreType;
        pub const Root = BuiltRoot;
        pub const Label = AppLabel;
        pub const PeriphLabel = AppLabel;
        pub const FlowLabel = GeneratedFlowLabel;
        pub const OverlayLabel = GeneratedOverlayLabel;
        pub const RouterLabel = GeneratedRouterLabel;
        pub const SelectionLabel = GeneratedSelectionLabel;
        pub const poller_count: usize = runtime_poller_count;
        pub const pixel_count: usize = ledstrip_pixel_count;
        pub const FrameType = ledstrip.Frame.make(pixel_count);

        pub fn LedStrip(comptime label: PeriphLabel) type {
            inline for (0..ledstrip_count) |i| {
                const periph = ledstrip_registry.periphs[i];
                if (label == @field(PeriphLabel, periphLabel(periph))) {
                    return struct {
                        pub const pixel_count: usize = periph.pixel_count;
                        pub const FrameType = ledstrip.Frame.make(@This().pixel_count);
                    };
                }
            }
            @compileError("zux app has no led strip for label '" ++ @tagName(label) ++ "'");
        }

        pub fn FlowEdgeLabel(comptime label: FlowLabel) type {
            return flowTypeForLabel(label).EdgeLabel;
        }

        pub fn FlowMove(comptime label: FlowLabel) type {
            return struct {
                direction: flow_component.event.Direction,
                edge: FlowEdgeLabel(label),
            };
        }

        const Runtime = struct {
            allocator: Lib.mem.Allocator,
            store: StoreType,
            single_buttons: SingleButtonInstances,
            grouped_buttons: GroupedButtonInstances,
            imus: ImuInstances,
            led_strips: LedStripInstances,
            modems: ModemInstances,
            nfcs: NfcInstances,
            wifi_stas: WifiStaInstances,
            wifi_aps: WifiApInstances,
            detector: if (has_button_runtime) button.Reducer else void,
            store_reducer: if (has_button_runtime) StoreReducerType else void,
            imu_detector: if (has_imu_runtime) component_imu.Reducer else void,
            imu_store_reducer: if (has_imu_runtime) StoreReducerType else void,
            ledstrip_store_reducer: if (has_ledstrip_runtime) StoreReducerType else void,
            modem_event_hooks: if (has_modem_runtime) [modem_count]component_modem.EventHook else void,
            modem_reducer: if (has_modem_runtime) component_modem.Reducer else void,
            modem_store_reducer: if (has_modem_runtime) ModemStoreReducerNode else void,
            nfc_event_hooks: if (has_nfc_runtime) [nfc_count]component_nfc.EventHook else void,
            nfc_store_reducer: if (has_nfc_runtime) NfcStoreReducerNode else void,
            wifi_sta_reducer: if (has_wifi_sta_runtime) component_wifi.StaReducer else void,
            wifi_ap_reducers: if (has_wifi_ap_runtime) [wifi_ap_count]component_wifi.ApReducer else void,
            wifi_sta_store_reducer: if (has_wifi_sta_runtime) WifiStaStoreReducerNode else void,
            wifi_ap_store_reducer: if (has_wifi_ap_runtime) WifiApStoreReducerNode else void,
            flow_store_reducer: if (has_flow_runtime) StoreReducerType else void,
            overlay_store_reducer: if (has_overlay_runtime) StoreReducerType else void,
            route_store_reducer: if (has_router_runtime) StoreReducerType else void,
            selection_store_reducer: if (has_selection_runtime) StoreReducerType else void,
            configured_reducers: [configured_reducer_count]StoreReducerType = undefined,
            render_subscribers: [configured_render_count]@import("../Store.zig").Subscriber = undefined,
            store_tick: StoreTickNode,
            root_config: BuiltRoot.Config,
            root: Node,
            pipeline: BuiltPipeline,
            pipeline_sink: PipelineSink,
            single_button_pollers: [gpio_count]SingleButtonPoller = undefined,
            grouped_button_pollers: [adc_count]GroupedButtonPoller = undefined,
            imu_pollers: [imu_count]ImuPollerWrapper = undefined,
            pollers: [runtime_poller_count]Poller = undefined,

            pub fn init(init_config: InitConfig) !*Runtime {
                const runtime = try init_config.allocator.create(Runtime);
                errdefer init_config.allocator.destroy(runtime);
                var subscribed_render_count: usize = 0;

                runtime.allocator = init_config.allocator;
                runtime.single_buttons = initSingleButtonInstances(init_config);
                runtime.grouped_buttons = initGroupedButtonInstances(init_config);
                runtime.imus = initImuInstances(init_config);
                runtime.led_strips = initLedStripInstances(init_config);
                runtime.modems = initModemInstances(init_config);
                runtime.nfcs = initNfcInstances(init_config);
                runtime.wifi_stas = initWifiStaInstances(init_config);
                runtime.wifi_aps = initWifiApInstances(init_config);

                const stores = try initStoreValues(init_config.allocator);
                runtime.store = try StoreType.init(init_config.allocator, stores);
                errdefer {
                    inline for (0..configured_render_count) |i| {
                        if (i >= subscribed_render_count) break;
                        const binding = context.render_bindings[i];
                        _ = runtime.store.unsubscribePath(binding.path, &runtime.render_subscribers[i]);
                    }
                    runtime.store.deinit();
                    deinitStoreValues(&runtime.store.stores);
                }
                inline for (0..configured_render_count) |i| {
                    const binding = context.render_bindings[i];
                    runtime.render_subscribers[i] = binding.AdapterType.makeSubscriber(Self, Runtime, runtime);
                    try runtime.store.subscribePath(binding.path, &runtime.render_subscribers[i]);
                    subscribed_render_count = i + 1;
                }

                if (has_button_runtime) {
                    runtime.detector = button.Reducer.init(init_config.allocator);
                    errdefer runtime.detector.deinit();

                    runtime.store_reducer = StoreReducerType.init(
                        &runtime.store.stores,
                        ButtonStoreReducerFn.reduce,
                    );
                }
                if (has_imu_runtime) {
                    runtime.imu_detector = component_imu.Reducer.initDefault(init_config.allocator);
                    errdefer runtime.imu_detector.deinit();

                    runtime.imu_store_reducer = StoreReducerType.init(
                        &runtime.store.stores,
                        ImuStoreReducerFn.reduce,
                    );
                }
                if (has_ledstrip_runtime) {
                    runtime.ledstrip_store_reducer = StoreReducerType.init(
                        &runtime.store.stores,
                        LedStripStoreReducerFn.reduce,
                    );
                }
                if (has_modem_runtime) {
                    runtime.modem_reducer = component_modem.Reducer.init();
                    runtime.modem_store_reducer = .{
                        .stores = &runtime.store.stores,
                        .reducer = &runtime.modem_reducer,
                    };
                }
                if (has_wifi_sta_runtime) {
                    runtime.wifi_sta_reducer = component_wifi.StaReducer.init();
                    runtime.wifi_sta_store_reducer = .{
                        .stores = &runtime.store.stores,
                        .reducer = &runtime.wifi_sta_reducer,
                    };
                }
                if (has_wifi_ap_runtime) {
                    var initialized_wifi_ap_reducer_count: usize = 0;
                    errdefer {
                        for (runtime.wifi_ap_reducers[0..initialized_wifi_ap_reducer_count]) |*reducer| {
                            reducer.deinit();
                        }
                    }
                    inline for (0..wifi_ap_count) |i| {
                        runtime.wifi_ap_reducers[i] = component_wifi.ApReducer.init(init_config.allocator);
                        initialized_wifi_ap_reducer_count = i + 1;
                    }
                    runtime.wifi_ap_store_reducer = .{
                        .stores = &runtime.store.stores,
                        .reducers = &runtime.wifi_ap_reducers,
                    };
                }

                if (has_flow_runtime) {
                    runtime.flow_store_reducer = StoreReducerType.init(
                        &runtime.store.stores,
                        FlowStoreReducerFn.reduce,
                    );
                }
                if (has_overlay_runtime) {
                    runtime.overlay_store_reducer = StoreReducerType.init(
                        &runtime.store.stores,
                        OverlayStoreReducerFn.reduce,
                    );
                }
                if (has_router_runtime) {
                    runtime.route_store_reducer = StoreReducerType.init(
                        &runtime.store.stores,
                        RouterStoreReducerFn.reduce,
                    );
                }
                if (has_selection_runtime) {
                    runtime.selection_store_reducer = StoreReducerType.init(
                        &runtime.store.stores,
                        SelectionStoreReducerFn.reduce,
                    );
                }
                inline for (0..configured_reducer_count) |i| {
                    const binding = context.reducer_bindings[i];
                    runtime.configured_reducers[i] = StoreReducerType.init(
                        &runtime.store.stores,
                        binding.factory(StoreType.Stores, Message, Emitter),
                    );
                }
                runtime.store_tick = .{
                    .store = &runtime.store,
                };

                runtime.pipeline = try BuiltPipeline.init(init_config.allocator);
                errdefer runtime.pipeline.deinit();

                runtime.pipeline_sink = .{
                    .pipeline = &runtime.pipeline,
                };

                if (has_modem_runtime) {
                    inline for (0..modem_count) |i| {
                        runtime.modem_event_hooks[i] = component_modem.EventHook.init();
                        runtime.modem_event_hooks[i].bindOutput(Emitter.init(&runtime.pipeline_sink));
                    }
                }
                if (has_nfc_runtime) {
                    inline for (0..nfc_count) |i| {
                        runtime.nfc_event_hooks[i] = component_nfc.EventHook.init();
                        runtime.nfc_event_hooks[i].bindOutput(Emitter.init(&runtime.pipeline_sink));
                    }
                    runtime.nfc_store_reducer = .{
                        .stores = &runtime.store.stores,
                    };
                }

                initPollers(runtime);
                runtime.root_config = buildRootConfig(runtime, init_config);
                runtime.root = BuiltRoot.build(&runtime.root_config);
                runtime.pipeline.bindOutput(runtime.root.in);

                return runtime;
            }

            pub fn deinit(runtime: *Runtime) void {
                inline for (&runtime.pollers) |*poller| {
                    poller.deinit();
                }
                runtime.pipeline.deinit();

                if (has_button_runtime) {
                    runtime.detector.deinit();
                }
                if (has_imu_runtime) {
                    runtime.imu_detector.deinit();
                }
                if (has_modem_runtime) {
                    runtime.modem_reducer.deinit();
                    inline for (&runtime.modem_event_hooks) |*hook| {
                        hook.clearOutput();
                    }
                }
                if (has_nfc_runtime) {
                    inline for (&runtime.nfc_event_hooks) |*hook| {
                        hook.clearOutput();
                    }
                }
                if (has_wifi_ap_runtime) {
                    inline for (&runtime.wifi_ap_reducers) |*reducer| {
                        reducer.deinit();
                    }
                }
                if (has_wifi_sta_runtime) {
                    runtime.wifi_sta_reducer.deinit();
                }
                inline for (0..configured_render_count) |i| {
                    const binding = context.render_bindings[i];
                    _ = runtime.store.unsubscribePath(binding.path, &runtime.render_subscribers[i]);
                }

                runtime.store.deinit();
                deinitStoreValues(&runtime.store.stores);
                runtime.allocator.destroy(runtime);
            }

            fn initPollers(runtime: *Runtime) void {
                inline for (0..gpio_count) |i| {
                    const periph = gpio_registry.periphs[i];
                    const label_name = comptime periphLabel(periph);
                    runtime.pollers[i] = runtime.single_button_pollers[i].init(
                        @field(runtime.single_buttons, label_name),
                        .{
                            .source_id = periphIdForRecord(periph),
                        },
                    );
                    runtime.pollers[i].bindOutput(Emitter.init(&runtime.pipeline_sink));
                }

                inline for (0..adc_count) |i| {
                    const periph = adc_registry.periphs[i];
                    const label_name = comptime periphLabel(periph);
                    const poller_index = gpio_count + i;
                    runtime.pollers[poller_index] = runtime.grouped_button_pollers[i].init(
                        @field(runtime.grouped_buttons, label_name),
                        .{
                            .source_id = periphIdForRecord(periph),
                        },
                    );
                    runtime.pollers[poller_index].bindOutput(Emitter.init(&runtime.pipeline_sink));
                }

                inline for (0..imu_count) |i| {
                    const periph = imu_registry.periphs[i];
                    const label_name = comptime periphLabel(periph);
                    const poller_index = gpio_count + adc_count + i;
                    runtime.imu_pollers[i] = .{
                        .inner = ImuPollerType.init(
                            @field(runtime.imus, label_name),
                            .{
                                .source_id = periphIdForRecord(periph),
                            },
                        ),
                    };
                    runtime.pollers[poller_index] = Poller.init(
                        ImuPollerWrapper,
                        &runtime.imu_pollers[i],
                    );
                    runtime.pollers[poller_index].bindOutput(Emitter.init(&runtime.pipeline_sink));
                }
            }

            fn buildRootConfig(runtime: *Runtime, init_config: InitConfig) BuiltRoot.Config {
                var config: BuiltRoot.Config = undefined;

                if (has_button_runtime) {
                    config._zux_button_detector = runtime.detector.node();
                    config._zux_button_store_reducer = runtime.store_reducer.node();
                }
                if (has_imu_runtime) {
                    config._zux_imu_detector = runtime.imu_detector.node();
                    config._zux_imu_store_reducer = runtime.imu_store_reducer.node();
                }
                if (has_ledstrip_runtime) {
                    config._zux_ledstrip_store_reducer = runtime.ledstrip_store_reducer.node();
                }
                if (has_modem_runtime) {
                    config._zux_modem_store_reducer = runtime.modem_store_reducer.node();
                }
                if (has_nfc_runtime) {
                    config._zux_nfc_store_reducer = runtime.nfc_store_reducer.node();
                }
                if (has_wifi_sta_runtime) {
                    config._zux_wifi_sta_store_reducer = runtime.wifi_sta_store_reducer.node();
                }
                if (has_wifi_ap_runtime) {
                    config._zux_wifi_ap_store_reducer = runtime.wifi_ap_store_reducer.node();
                }

                if (has_flow_runtime) {
                    config._zux_flow_store_reducer = runtime.flow_store_reducer.node();
                }
                if (has_overlay_runtime) {
                    config._zux_overlay_store_reducer = runtime.overlay_store_reducer.node();
                }
                if (has_router_runtime) {
                    config._zux_route_store_reducer = runtime.route_store_reducer.node();
                }
                if (has_selection_runtime) {
                    config._zux_selection_store_reducer = runtime.selection_store_reducer.node();
                }
                inline for (0..configured_reducer_count) |i| {
                    const binding = context.reducer_bindings[i];
                    @field(config, binding.name) = runtime.configured_reducers[i].node();
                }
                config._zux_store_tick = runtime.store_tick.node();

                if (has_user_root_config) {
                    copyUserRootConfig(&config, init_config.user_root_config);
                }

                return config;
            }

            fn copyUserRootConfig(dst: *BuiltRoot.Config, user_root_config: UserRoot.Config) void {
                inline for (@typeInfo(UserRoot.Config).@"struct".fields) |field| {
                    if (!comptimeEql(field.name, "__branches")) {
                        @field(dst.*, field.name) = @field(user_root_config, field.name);
                    }
                }
            }

            fn initSingleButtonInstances(init_config: InitConfig) SingleButtonInstances {
                var single_buttons: SingleButtonInstances = undefined;
                inline for (0..gpio_count) |i| {
                    const periph = gpio_registry.periphs[i];
                    const label_name = comptime periphLabel(periph);
                    @field(single_buttons, label_name) = @field(init_config, label_name);
                }
                return single_buttons;
            }

            fn initGroupedButtonInstances(init_config: InitConfig) GroupedButtonInstances {
                var grouped_buttons: GroupedButtonInstances = undefined;
                inline for (0..adc_count) |i| {
                    const periph = adc_registry.periphs[i];
                    const label_name = comptime periphLabel(periph);
                    @field(grouped_buttons, label_name) = @field(init_config, label_name);
                }
                return grouped_buttons;
            }

            fn initImuInstances(init_config: InitConfig) ImuInstances {
                var imus: ImuInstances = undefined;
                inline for (0..imu_count) |i| {
                    const periph = imu_registry.periphs[i];
                    const label_name = comptime periphLabel(periph);
                    @field(imus, label_name) = @field(init_config, label_name);
                }
                return imus;
            }

            fn initLedStripInstances(init_config: InitConfig) LedStripInstances {
                var led_strips: LedStripInstances = undefined;
                inline for (0..ledstrip_count) |i| {
                    const periph = ledstrip_registry.periphs[i];
                    const label_name = comptime periphLabel(periph);
                    @field(led_strips, label_name) = @field(init_config, label_name);
                }
                return led_strips;
            }

            fn initModemInstances(init_config: InitConfig) ModemInstances {
                var modems: ModemInstances = undefined;
                inline for (0..modem_count) |i| {
                    const periph = modem_registry.periphs[i];
                    const label_name = comptime periphLabel(periph);
                    @field(modems, label_name) = @field(init_config, label_name);
                }
                return modems;
            }

            fn initNfcInstances(init_config: InitConfig) NfcInstances {
                var nfcs: NfcInstances = undefined;
                inline for (0..nfc_count) |i| {
                    const periph = nfc_registry.periphs[i];
                    const label_name = comptime periphLabel(periph);
                    @field(nfcs, label_name) = @field(init_config, label_name);
                }
                return nfcs;
            }

            fn initWifiStaInstances(init_config: InitConfig) WifiStaInstances {
                var wifi_stas: WifiStaInstances = undefined;
                inline for (0..wifi_sta_count) |i| {
                    const periph = wifi_sta_registry.periphs[i];
                    const label_name = comptime periphLabel(periph);
                    @field(wifi_stas, label_name) = @field(init_config, label_name);
                }
                return wifi_stas;
            }

            fn initWifiApInstances(init_config: InitConfig) WifiApInstances {
                var wifi_aps: WifiApInstances = undefined;
                inline for (0..wifi_ap_count) |i| {
                    const periph = wifi_ap_registry.periphs[i];
                    const label_name = comptime periphLabel(periph);
                    @field(wifi_aps, label_name) = @field(init_config, label_name);
                }
                return wifi_aps;
            }

            fn initStoreValues(allocator: Lib.mem.Allocator) !StoreType.Stores {
                var stores_value: StoreType.Stores = undefined;
                var initialized_count: usize = 0;
                errdefer deinitStoreValuesPrefix(&stores_value, initialized_count);

                inline for (@typeInfo(StoreType.Stores).@"struct".fields) |field| {
                    @field(stores_value, field.name) = try initStoreValue(field.type, allocator);
                    initialized_count += 1;
                }

                return stores_value;
            }

            fn initStoreValue(comptime StoreFieldType: type, allocator: Lib.mem.Allocator) !StoreFieldType {
                if (@hasDecl(StoreFieldType, "init")) {
                    const result = StoreFieldType.init(allocator, .{});
                    return switch (@typeInfo(@TypeOf(result))) {
                        .error_union => try result,
                        else => result,
                    };
                }
                return .{};
            }

            fn deinitStoreValues(stores_value: *StoreType.Stores) void {
                deinitStoreValuesPrefix(stores_value, @typeInfo(StoreType.Stores).@"struct".fields.len);
            }

            fn deinitStoreValuesPrefix(stores_value: *StoreType.Stores, count: usize) void {
                inline for (@typeInfo(StoreType.Stores).@"struct".fields, 0..) |field, i| {
                    if (i < count and @hasDecl(field.type, "deinit")) {
                        @field(stores_value.*, field.name).deinit();
                    }
                }
            }

            fn commitStores(runtime: *Runtime) void {
                runtime.store.tick();
            }
        };

        const ButtonStoreReducerFn = struct {
            fn reduce(stores: *StoreType.Stores, message: Message, emit: Emitter) !usize {
                switch (message.body) {
                    .button_gesture => |button_gesture| {
                        inline for (0..gpio_count) |i| {
                            const periph = gpio_registry.periphs[i];
                            if (button_gesture.source_id == periphIdForRecord(periph)) {
                                return button.Reducer.reduce(&@field(stores, periphLabel(periph)), message, emit);
                            }
                        }
                        inline for (0..adc_count) |i| {
                            const periph = adc_registry.periphs[i];
                            if (button_gesture.source_id == periphIdForRecord(periph)) {
                                return button.Reducer.reduce(&@field(stores, periphLabel(periph)), message, emit);
                            }
                        }
                        try emit.emit(message);
                        return 1;
                    },
                    else => {
                        if (message.body == .tick) return 0;
                        try emit.emit(message);
                        return 1;
                    },
                }
            }
        };

        const ImuStoreReducerFn = struct {
            fn reduce(stores: *StoreType.Stores, message: Message, emit: Emitter) !usize {
                const source_id = switch (message.body) {
                    .raw_imu_accel => |raw_imu_accel| raw_imu_accel.source_id,
                    .raw_imu_gyro => |raw_imu_gyro| raw_imu_gyro.source_id,
                    .imu_motion => |imu_motion| imu_motion.source_id,
                    else => {
                        if (message.body == .tick) return 0;
                        try emit.emit(message);
                        return 1;
                    },
                };

                inline for (0..imu_count) |i| {
                    const periph = imu_registry.periphs[i];
                    if (source_id == periphIdForRecord(periph)) {
                        return component_imu.Reducer.reduce(
                            &@field(stores, periphLabel(periph)),
                            message,
                            emit,
                        );
                    }
                }
                try emit.emit(message);
                return 1;
            }
        };

        const LedStripStoreReducerFn = struct {
            fn reduce(stores: *StoreType.Stores, message: Message, emit: Emitter) !usize {
                switch (message.body) {
                    .ledstrip_set,
                    .ledstrip_set_pixels,
                    .ledstrip_flash,
                    .ledstrip_pingpong,
                    .ledstrip_rotate,
                    => {
                        inline for (0..ledstrip_count) |i| {
                            const periph = ledstrip_registry.periphs[i];
                            if (messageSourceId(message) == periphIdForRecord(periph)) {
                                return LedStripReducerType.reduce(&@field(stores, periphLabel(periph)), message, emit);
                            }
                        }
                        try emit.emit(message);
                        return 1;
                    },
                    .tick => {
                        var changed_count: usize = 0;
                        inline for (0..ledstrip_count) |i| {
                            const periph = ledstrip_registry.periphs[i];
                            changed_count += try LedStripReducerType.reduce(
                                &@field(stores, periphLabel(periph)),
                                message,
                                emit,
                            );
                        }
                        return changed_count;
                    },
                    else => {
                        if (message.body == .tick) return 0;
                        try emit.emit(message);
                        return 1;
                    },
                }
            }
        };

        const FlowStoreReducerFn = struct {
            fn reduce(stores: *StoreType.Stores, message: Message, emit: Emitter) !usize {
                switch (message.body) {
                    .ui_flow_move,
                    .ui_flow_reset,
                    => {
                        const flow_id = messageFlowId(message);
                        inline for (0..flow_count) |i| {
                            const flow_record = flow_registry.periphs[i];
                            if (flow_id == periphIdForRecord(flow_record)) {
                                return @TypeOf(@field(stores, periphLabel(flow_record))).reduce(
                                    &@field(stores, periphLabel(flow_record)),
                                    message,
                                    emit,
                                );
                            }
                        }
                        try emit.emit(message);
                        return 1;
                    },
                    else => {
                        if (message.body == .tick) return 0;
                        try emit.emit(message);
                        return 1;
                    },
                }
            }
        };

        const OverlayStoreReducerFn = struct {
            fn reduce(stores: *StoreType.Stores, message: Message, emit: Emitter) !usize {
                switch (message.body) {
                    .ui_overlay_show,
                    .ui_overlay_hide,
                    .ui_overlay_set_name,
                    .ui_overlay_set_blocking,
                    => {
                        const overlay_id = messageOverlayId(message);
                        inline for (0..overlay_count) |i| {
                            const overlay_record = overlay_registry.periphs[i];
                            if (overlay_id == periphIdForRecord(overlay_record)) {
                                return @TypeOf(@field(stores, periphLabel(overlay_record))).reduce(
                                    &@field(stores, periphLabel(overlay_record)),
                                    message,
                                    emit,
                                );
                            }
                        }
                        try emit.emit(message);
                        return 1;
                    },
                    else => {
                        if (message.body == .tick) return 0;
                        try emit.emit(message);
                        return 1;
                    },
                }
            }
        };

        const RouterStoreReducerFn = struct {
            fn reduce(stores: *StoreType.Stores, message: Message, emit: Emitter) !usize {
                switch (message.body) {
                    .ui_route_push,
                    .ui_route_replace,
                    .ui_route_reset,
                    .ui_route_pop,
                    .ui_route_pop_to_root,
                    .ui_route_set_transitioning,
                    => {
                        const router_id = messageRouterId(message);
                        inline for (0..router_count) |i| {
                            const router_record = router_registry.periphs[i];
                            if (router_id == periphIdForRecord(router_record)) {
                                return @TypeOf(@field(stores, periphLabel(router_record))).reduce(
                                    &@field(stores, periphLabel(router_record)),
                                    message,
                                    emit,
                                );
                            }
                        }
                        try emit.emit(message);
                        return 1;
                    },
                    else => {
                        if (message.body == .tick) return 0;
                        try emit.emit(message);
                        return 1;
                    },
                }
            }
        };

        const SelectionStoreReducerFn = struct {
            fn reduce(stores: *StoreType.Stores, message: Message, emit: Emitter) !usize {
                switch (message.body) {
                    .ui_selection_next,
                    .ui_selection_prev,
                    .ui_selection_set,
                    .ui_selection_reset,
                    .ui_selection_set_count,
                    .ui_selection_set_loop,
                    => {
                        const selection_id = messageSelectionId(message);
                        inline for (0..selection_count) |i| {
                            const selection_record = selection_registry.periphs[i];
                            if (selection_id == periphIdForRecord(selection_record)) {
                                return @TypeOf(@field(stores, periphLabel(selection_record))).reduce(
                                    &@field(stores, periphLabel(selection_record)),
                                    message,
                                    emit,
                                );
                            }
                        }
                        try emit.emit(message);
                        return 1;
                    },
                    else => {
                        try emit.emit(message);
                        return 1;
                    },
                }
            }
        };

        runtime: *Runtime,
        started: bool = false,
        manual_ticker: bool = false,
        closed: bool = false,
        last_event: ?Message.Event = null,
        last_grouped_button_ids: [periph_ids.len]?u32 = [_]?u32{null} ** periph_ids.len,

        pub fn init(init_config: InitConfig) !Self {
            const self: Self = .{
                .runtime = try Runtime.init(init_config),
            };
            errdefer Runtime.deinit(self.runtime);

            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.started) {
                self.stop() catch {};
            }
            Runtime.deinit(self.runtime);
            self.last_event = null;
        }

        pub fn start(self: *Self, start_config: StartConfig) !void {
            if (self.started or self.closed) return error.InvalidState;

            if (start_config.ticker) |ticker| switch (ticker) {
                .manual => {
                    self.manual_ticker = true;
                    self.started = true;
                    return;
                },
                .interval_ms => |interval_ms| {
                    if (interval_ms == 0) return error.InvalidStartConfig;
                    self.runtime.pipeline.tick_interval_ns = @as(u64, interval_ms) * Lib.time.ns_per_ms;
                },
            } else {
                self.runtime.pipeline.tick_interval_ns = runtime_pipeline_config.tick_interval_ns;
            }

            try self.runtime.pipeline.start();
            errdefer {
                self.runtime.pipeline.stop();
                self.runtime.pipeline.wait();
            }

            const poller_config = switch (start_config.poller) {
                .default => runtime_poller_config,
                .config => |config| config,
            };
            inline for (0..runtime_poller_count) |i| {
                self.runtime.pollers[i].start(poller_config) catch |err| {
                    inline for (0..i) |started_idx| {
                        self.runtime.pollers[started_idx].stop();
                    }
                    self.runtime.pipeline.stop();
                    self.runtime.pipeline.wait();
                    return err;
                };
            }

            if (has_modem_runtime) {
                inline for (0..modem_count) |i| {
                    const periph = modem_registry.periphs[i];
                    const label_name = comptime periphLabel(periph);
                    self.runtime.modem_event_hooks[i].attach(@field(self.runtime.modems, label_name));
                }
            }
            if (has_nfc_runtime) {
                inline for (0..nfc_count) |i| {
                    const periph = nfc_registry.periphs[i];
                    const label_name = comptime periphLabel(periph);
                    self.runtime.nfc_event_hooks[i].attach(@field(self.runtime.nfcs, label_name));
                }
            }

            self.started = true;
        }

        pub fn stop(self: *Self) !void {
            if (!self.started) return error.InvalidState;

            if (!self.manual_ticker) {
                if (has_modem_runtime) {
                    inline for (0..modem_count) |i| {
                        const periph = modem_registry.periphs[i];
                        const label_name = comptime periphLabel(periph);
                        self.runtime.modem_event_hooks[i].detach(@field(self.runtime.modems, label_name));
                    }
                }
                if (has_nfc_runtime) {
                    inline for (0..nfc_count) |i| {
                        const periph = nfc_registry.periphs[i];
                        const label_name = comptime periphLabel(periph);
                        self.runtime.nfc_event_hooks[i].detach(@field(self.runtime.nfcs, label_name));
                    }
                }
                inline for (&self.runtime.pollers) |*poller| {
                    poller.stop();
                }
                self.runtime.pipeline.stop();
                self.runtime.pipeline.wait();
            }

            self.runtime.commitStores();
            self.started = false;
            self.manual_ticker = false;
            self.closed = true;
        }

        pub fn dispatch(self: *Self, message: Message) !void {
            if (!self.started) return error.NotStarted;

            self.last_event = message.body;
            if (self.manual_ticker) {
                _ = try self.runtime.root.process(message);
                return;
            }
            try self.runtime.pipeline.inject(message);
        }

        pub fn press_single_button(self: *Self, label: PeriphLabel) !void {
            if (comptime periph_ids.len == 0) return error.InvalidPeriphKind;
            if (dispatchKind(label) != .single_button) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .raw_single_button = .{
                    .source_id = periphId(label),
                    .pressed = true,
                },
            });
        }

        pub fn release_single_button(self: *Self, label: PeriphLabel) !void {
            if (comptime periph_ids.len == 0) return error.InvalidPeriphKind;
            if (dispatchKind(label) != .single_button) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .raw_single_button = .{
                    .source_id = periphId(label),
                    .pressed = false,
                },
            });
        }

        pub fn press_grouped_button(self: *Self, label: PeriphLabel, button_id: u32) !void {
            if (comptime periph_ids.len == 0) return error.InvalidPeriphKind;
            if (dispatchKind(label) != .grouped_button) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .raw_grouped_button = .{
                    .source_id = periphId(label),
                    .button_id = button_id,
                    .pressed = true,
                },
            });
            const index = if (comptime periph_ids.len == 0) unreachable else @intFromEnum(label);
            self.last_grouped_button_ids[index] = button_id;
        }

        pub fn release_grouped_button(self: *Self, label: PeriphLabel) !void {
            if (comptime periph_ids.len == 0) return error.InvalidPeriphKind;
            if (dispatchKind(label) != .grouped_button) return error.InvalidPeriphKind;
            const index = if (comptime periph_ids.len == 0) unreachable else @intFromEnum(label);
            const last_button_id = self.last_grouped_button_ids[index];
            try self.emitBody(.{
                .raw_grouped_button = .{
                    .source_id = periphId(label),
                    .button_id = last_button_id,
                    .pressed = false,
                },
            });
            self.last_grouped_button_ids[index] = null;
        }

        pub fn imu_accel(self: *Self, label: PeriphLabel, accel: drivers.imu.Vec3) !void {
            if (comptime periph_ids.len == 0) return error.InvalidPeriphKind;
            if (dispatchKind(label) != .imu) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .raw_imu_accel = .{
                    .source_id = periphId(label),
                    .x = accel.x,
                    .y = accel.y,
                    .z = accel.z,
                },
            });
        }

        pub fn imu_gyro(self: *Self, label: PeriphLabel, gyro: drivers.imu.Vec3) !void {
            if (comptime periph_ids.len == 0) return error.InvalidPeriphKind;
            if (dispatchKind(label) != .imu) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .raw_imu_gyro = .{
                    .source_id = periphId(label),
                    .x = gyro.x,
                    .y = gyro.y,
                    .z = gyro.z,
                },
            });
        }

        pub fn modem_sim_state_changed(self: *Self, label: PeriphLabel, sim: modem_api.Modem.SimState) !void {
            if (dispatchKind(label) != .modem) return error.InvalidPeriphKind;
            try self.emitBody(try component_modem.event.make(Message.Event, periphId(label), .{
                .sim = .{
                    .state_changed = sim,
                },
            }));
        }

        pub fn modem_network_registration_changed(self: *Self, label: PeriphLabel, registration: modem_api.Modem.RegistrationState) !void {
            if (dispatchKind(label) != .modem) return error.InvalidPeriphKind;
            try self.emitBody(try component_modem.event.make(Message.Event, periphId(label), .{
                .network = .{
                    .registration_changed = registration,
                },
            }));
        }

        pub fn modem_network_signal_changed(self: *Self, label: PeriphLabel, signal: modem_api.Modem.SignalInfo) !void {
            if (dispatchKind(label) != .modem) return error.InvalidPeriphKind;
            try self.emitBody(try component_modem.event.make(Message.Event, periphId(label), .{
                .network = .{
                    .signal_changed = signal,
                },
            }));
        }

        pub fn modem_data_packet_state_changed(self: *Self, label: PeriphLabel, packet: modem_api.Modem.PacketState) !void {
            if (dispatchKind(label) != .modem) return error.InvalidPeriphKind;
            try self.emitBody(try component_modem.event.make(Message.Event, periphId(label), .{
                .data = .{
                    .packet_state_changed = packet,
                },
            }));
        }

        pub fn modem_data_apn_changed(self: *Self, label: PeriphLabel, apn: []const u8) !void {
            if (dispatchKind(label) != .modem) return error.InvalidPeriphKind;
            try self.emitBody(try component_modem.event.make(Message.Event, periphId(label), .{
                .data = .{
                    .apn_changed = apn,
                },
            }));
        }

        pub fn modem_call_incoming(self: *Self, label: PeriphLabel, call: modem_api.Modem.CallInfo) !void {
            if (dispatchKind(label) != .modem) return error.InvalidPeriphKind;
            try self.emitBody(try component_modem.event.make(Message.Event, periphId(label), .{
                .call = .{
                    .incoming = call,
                },
            }));
        }

        pub fn modem_call_state_changed(self: *Self, label: PeriphLabel, call: modem_api.Modem.CallStatus) !void {
            if (dispatchKind(label) != .modem) return error.InvalidPeriphKind;
            try self.emitBody(try component_modem.event.make(Message.Event, periphId(label), .{
                .call = .{
                    .state_changed = call,
                },
            }));
        }

        pub fn modem_call_ended(self: *Self, label: PeriphLabel, call: modem_api.Modem.CallEndInfo) !void {
            if (dispatchKind(label) != .modem) return error.InvalidPeriphKind;
            try self.emitBody(try component_modem.event.make(Message.Event, periphId(label), .{
                .call = .{
                    .ended = call,
                },
            }));
        }

        pub fn modem_sms_received(self: *Self, label: PeriphLabel, sms: modem_api.Modem.SmsMessage) !void {
            if (dispatchKind(label) != .modem) return error.InvalidPeriphKind;
            try self.emitBody(try component_modem.event.make(Message.Event, periphId(label), .{
                .sms = .{
                    .received = sms,
                },
            }));
        }

        pub fn modem_gnss_state_changed(self: *Self, label: PeriphLabel, state: modem_api.Modem.GnssState) !void {
            if (dispatchKind(label) != .modem) return error.InvalidPeriphKind;
            try self.emitBody(try component_modem.event.make(Message.Event, periphId(label), .{
                .gnss = .{
                    .state_changed = state,
                },
            }));
        }

        pub fn modem_gnss_fix_changed(self: *Self, label: PeriphLabel, fix: modem_api.Modem.GnssFix) !void {
            if (dispatchKind(label) != .modem) return error.InvalidPeriphKind;
            try self.emitBody(try component_modem.event.make(Message.Event, periphId(label), .{
                .gnss = .{
                    .fix_changed = fix,
                },
            }));
        }

        pub fn set_led_strip_pixels(self: *Self, label: PeriphLabel, frame: FrameType, brightness: u8) !void {
            if (comptime periph_ids.len == 0) return error.InvalidPeriphKind;
            if (dispatchKind(label) != .led_strip) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .ledstrip_set_pixels = .{
                    .source_id = periphId(label),
                    .pixels = frame.pixels[0..],
                    .brightness = brightness,
                },
            });
        }

        pub fn set_led_strip_animated(
            self: *Self,
            label: PeriphLabel,
            frame: FrameType,
            brightness: u8,
            duration: u32,
        ) !void {
            if (comptime periph_ids.len == 0) return error.InvalidPeriphKind;
            if (dispatchKind(label) != .led_strip) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .ledstrip_set = .{
                    .source_id = periphId(label),
                    .pixels = frame.pixels[0..],
                    .brightness = brightness,
                    .duration = duration,
                },
            });
        }

        pub fn set_led_strip_flash(
            self: *Self,
            label: PeriphLabel,
            frame: FrameType,
            brightness: u8,
            duration_ns: u64,
            interval_ns: u64,
        ) !void {
            if (comptime periph_ids.len == 0) return error.InvalidPeriphKind;
            if (dispatchKind(label) != .led_strip) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .ledstrip_flash = .{
                    .source_id = periphId(label),
                    .pixels = frame.pixels[0..],
                    .brightness = brightness,
                    .duration_ns = duration_ns,
                    .interval_ns = interval_ns,
                },
            });
        }

        pub fn set_led_strip_pingpong(
            self: *Self,
            label: PeriphLabel,
            from_frame: FrameType,
            to_frame: FrameType,
            brightness: u8,
            duration_ns: u64,
            interval_ns: u64,
        ) !void {
            if (comptime periph_ids.len == 0) return error.InvalidPeriphKind;
            if (dispatchKind(label) != .led_strip) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .ledstrip_pingpong = .{
                    .source_id = periphId(label),
                    .from_pixels = from_frame.pixels[0..],
                    .to_pixels = to_frame.pixels[0..],
                    .brightness = brightness,
                    .duration_ns = duration_ns,
                    .interval_ns = interval_ns,
                },
            });
        }

        pub fn set_led_strip_rotate(
            self: *Self,
            label: PeriphLabel,
            frame: FrameType,
            brightness: u8,
            duration_ns: u64,
            interval_ns: u64,
        ) !void {
            if (comptime periph_ids.len == 0) return error.InvalidPeriphKind;
            if (dispatchKind(label) != .led_strip) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .ledstrip_rotate = .{
                    .source_id = periphId(label),
                    .pixels = frame.pixels[0..],
                    .brightness = brightness,
                    .duration_ns = duration_ns,
                    .interval_ns = interval_ns,
                },
            });
        }

        pub fn nfc_found(self: *Self, label: PeriphLabel, uid: []const u8, card_type: drivers.nfc.CardType) !void {
            if (dispatchKind(label) != .nfc) return error.InvalidPeriphKind;
            try self.emitBody(try component_nfc.event.make(Message.Event, .{
                .source_id = periphId(label),
                .uid = uid,
                .payload = null,
                .card_type = card_type,
            }, null));
        }

        pub fn nfc_read(
            self: *Self,
            label: PeriphLabel,
            uid: []const u8,
            payload: []const u8,
            card_type: drivers.nfc.CardType,
        ) !void {
            if (dispatchKind(label) != .nfc) return error.InvalidPeriphKind;
            try self.emitBody(try component_nfc.event.make(Message.Event, .{
                .source_id = periphId(label),
                .uid = uid,
                .payload = payload,
                .card_type = card_type,
            }, null));
        }

        pub fn wifi_sta_scan_result(self: *Self, label: PeriphLabel, report: drivers.wifi.Sta.ScanResult) !void {
            if (dispatchKind(label) != .wifi_sta) return error.InvalidPeriphKind;
            try self.emitBody(try component_wifi.event.make(Message.Event, periphId(label), .{
                .sta = .{
                    .scan_result = report,
                },
            }));
        }

        pub fn wifi_sta_connected(self: *Self, label: PeriphLabel, info: drivers.wifi.Sta.LinkInfo) !void {
            if (dispatchKind(label) != .wifi_sta) return error.InvalidPeriphKind;
            try self.emitBody(try component_wifi.event.make(Message.Event, periphId(label), .{
                .sta = .{
                    .connected = info,
                },
            }));
        }

        pub fn wifi_sta_disconnected(self: *Self, label: PeriphLabel, info: drivers.wifi.Sta.DisconnectInfo) !void {
            if (dispatchKind(label) != .wifi_sta) return error.InvalidPeriphKind;
            try self.emitBody(try component_wifi.event.make(Message.Event, periphId(label), .{
                .sta = .{
                    .disconnected = info,
                },
            }));
        }

        pub fn wifi_sta_got_ip(self: *Self, label: PeriphLabel, info: drivers.wifi.Sta.IpInfo) !void {
            if (dispatchKind(label) != .wifi_sta) return error.InvalidPeriphKind;
            try self.emitBody(try component_wifi.event.make(Message.Event, periphId(label), .{
                .sta = .{
                    .got_ip = info,
                },
            }));
        }

        pub fn wifi_sta_lost_ip(self: *Self, label: PeriphLabel) !void {
            if (dispatchKind(label) != .wifi_sta) return error.InvalidPeriphKind;
            try self.emitBody(try component_wifi.event.make(Message.Event, periphId(label), .{
                .sta = .{
                    .lost_ip = {},
                },
            }));
        }

        pub fn wifi_ap_started(self: *Self, label: PeriphLabel, info: drivers.wifi.Ap.StartedInfo) !void {
            if (dispatchKind(label) != .wifi_ap) return error.InvalidPeriphKind;
            try self.emitBody(try component_wifi.event.make(Message.Event, periphId(label), .{
                .ap = .{
                    .started = info,
                },
            }));
        }

        pub fn wifi_ap_stopped(self: *Self, label: PeriphLabel) !void {
            if (dispatchKind(label) != .wifi_ap) return error.InvalidPeriphKind;
            try self.emitBody(try component_wifi.event.make(Message.Event, periphId(label), .{
                .ap = .{
                    .stopped = {},
                },
            }));
        }

        pub fn wifi_ap_client_joined(self: *Self, label: PeriphLabel, info: drivers.wifi.Ap.ClientInfo) !void {
            if (dispatchKind(label) != .wifi_ap) return error.InvalidPeriphKind;
            try self.emitBody(try component_wifi.event.make(Message.Event, periphId(label), .{
                .ap = .{
                    .client_joined = info,
                },
            }));
        }

        pub fn wifi_ap_client_left(self: *Self, label: PeriphLabel, info: drivers.wifi.Ap.ClientInfo) !void {
            if (dispatchKind(label) != .wifi_ap) return error.InvalidPeriphKind;
            try self.emitBody(try component_wifi.event.make(Message.Event, periphId(label), .{
                .ap = .{
                    .client_left = info,
                },
            }));
        }

        pub fn wifi_ap_lease_granted(self: *Self, label: PeriphLabel, info: drivers.wifi.Ap.LeaseInfo) !void {
            if (dispatchKind(label) != .wifi_ap) return error.InvalidPeriphKind;
            try self.emitBody(try component_wifi.event.make(Message.Event, periphId(label), .{
                .ap = .{
                    .lease_granted = info,
                },
            }));
        }

        pub fn wifi_ap_lease_released(self: *Self, label: PeriphLabel, info: drivers.wifi.Ap.LeaseInfo) !void {
            if (dispatchKind(label) != .wifi_ap) return error.InvalidPeriphKind;
            try self.emitBody(try component_wifi.event.make(Message.Event, periphId(label), .{
                .ap = .{
                    .lease_released = info,
                },
            }));
        }

        pub fn router(self: *Self, label: RouterLabel) route_component.Router {
            inline for (0..router_count) |i| {
                const router_record = router_registry.periphs[i];
                if (label == @field(RouterLabel, periphLabel(router_record))) {
                    return @field(self.runtime.store.stores, periphLabel(router_record)).router();
                }
            }
            unreachable;
        }

        pub fn push_route(self: *Self, label: RouterLabel, item: route_component.Router.Item) !void {
            try self.emitBody(.{
                .ui_route_push = .{
                    .source_id = routerId(label),
                    .item = item,
                },
            });
        }

        pub fn replace_route(self: *Self, label: RouterLabel, item: route_component.Router.Item) !void {
            try self.emitBody(.{
                .ui_route_replace = .{
                    .source_id = routerId(label),
                    .item = item,
                },
            });
        }

        pub fn reset_route(self: *Self, label: RouterLabel, item: route_component.Router.Item) !void {
            try self.emitBody(.{
                .ui_route_reset = .{
                    .source_id = routerId(label),
                    .item = item,
                },
            });
        }

        pub fn pop_route(self: *Self, label: RouterLabel) !void {
            try self.emitBody(.{
                .ui_route_pop = .{
                    .source_id = routerId(label),
                },
            });
        }

        pub fn pop_route_to_root(self: *Self, label: RouterLabel) !void {
            try self.emitBody(.{
                .ui_route_pop_to_root = .{
                    .source_id = routerId(label),
                },
            });
        }

        pub fn set_route_transitioning(self: *Self, label: RouterLabel, value: bool) !void {
            try self.emitBody(.{
                .ui_route_set_transitioning = .{
                    .source_id = routerId(label),
                    .value = value,
                },
            });
        }

        pub fn move_flow(
            self: *Self,
            comptime label: FlowLabel,
            direction: flow_component.event.Direction,
            edge: FlowEdgeLabel(label),
        ) !void {
            try self.emitBody(.{
                .ui_flow_move = .{
                    .source_id = flowId(label),
                    .direction = direction,
                    .edge_id = flowEdgeId(label, edge),
                },
            });
        }

        pub fn available_moves(
            self: *Self,
            comptime label: FlowLabel,
            allocator: Lib.mem.Allocator,
        ) ![]FlowMove(label) {
            const FlowType = flowTypeForLabel(label);
            const state = flowStateForLabel(self, label);
            const forward_edges = FlowType.forwardEdges(state.node);
            const reverse_edges = FlowType.reverseEdges(state.node);
            const moves = try allocator.alloc(FlowMove(label), forward_edges.len + reverse_edges.len);
            var next_index: usize = 0;

            for (forward_edges) |edge| {
                moves[next_index] = .{
                    .direction = .forward,
                    .edge = edge,
                };
                next_index += 1;
            }
            for (reverse_edges) |edge| {
                moves[next_index] = .{
                    .direction = .reverse,
                    .edge = edge,
                };
                next_index += 1;
            }

            return moves;
        }

        pub fn reset_flow(self: *Self, comptime label: FlowLabel) !void {
            try self.emitBody(.{
                .ui_flow_reset = .{
                    .source_id = flowId(label),
                },
            });
        }

        pub fn show_overlay(self: *Self, label: OverlayLabel, name: []const u8, blocking: bool) !void {
            const name_fields = try overlay_component.State.nameFields(name);
            try self.emitBody(.{
                .ui_overlay_show = .{
                    .source_id = overlayId(label),
                    .name = name_fields.name,
                    .name_len = name_fields.name_len,
                    .blocking = blocking,
                },
            });
        }

        pub fn hide_overlay(self: *Self, label: OverlayLabel) !void {
            try self.emitBody(.{
                .ui_overlay_hide = .{
                    .source_id = overlayId(label),
                },
            });
        }

        pub fn set_overlay_name(self: *Self, label: OverlayLabel, name: []const u8) !void {
            const name_fields = try overlay_component.State.nameFields(name);
            try self.emitBody(.{
                .ui_overlay_set_name = .{
                    .source_id = overlayId(label),
                    .name = name_fields.name,
                    .name_len = name_fields.name_len,
                },
            });
        }

        pub fn set_overlay_blocking(self: *Self, label: OverlayLabel, value: bool) !void {
            try self.emitBody(.{
                .ui_overlay_set_blocking = .{
                    .source_id = overlayId(label),
                    .value = value,
                },
            });
        }

        pub fn next_selection(self: *Self, label: SelectionLabel) !void {
            try self.emitBody(.{
                .ui_selection_next = .{
                    .source_id = selectionId(label),
                },
            });
        }

        pub fn prev_selection(self: *Self, label: SelectionLabel) !void {
            try self.emitBody(.{
                .ui_selection_prev = .{
                    .source_id = selectionId(label),
                },
            });
        }

        pub fn set_selection(self: *Self, label: SelectionLabel, index: usize) !void {
            try self.emitBody(.{
                .ui_selection_set = .{
                    .source_id = selectionId(label),
                    .index = index,
                },
            });
        }

        pub fn reset_selection(self: *Self, label: SelectionLabel) !void {
            try self.emitBody(.{
                .ui_selection_reset = .{
                    .source_id = selectionId(label),
                },
            });
        }

        pub fn set_selection_count(self: *Self, label: SelectionLabel, count: usize) !void {
            try self.emitBody(.{
                .ui_selection_set_count = .{
                    .source_id = selectionId(label),
                    .count = count,
                },
            });
        }

        pub fn set_selection_loop(self: *Self, label: SelectionLabel, value: bool) !void {
            try self.emitBody(.{
                .ui_selection_set_loop = .{
                    .source_id = selectionId(label),
                    .value = value,
                },
            });
        }

        pub fn store(self: *Self) *StoreType {
            return &self.runtime.store;
        }

        fn emitBody(self: *Self, body: Message.Event) !void {
            try self.dispatch(.{
                .origin = .manual,
                .timestamp_ns = Lib.time.nanoTimestamp(),
                .body = body,
            });
        }

        fn periphId(label: PeriphLabel) u32 {
            return if (comptime periph_ids.len == 0)
                unreachable
            else
                periph_ids[@intFromEnum(label)];
        }

        fn dispatchKind(label: PeriphLabel) PeriphDispatchKind {
            return if (comptime periph_kinds.len == 0)
                unreachable
            else
                periph_kinds[@intFromEnum(label)];
        }

        fn routerId(label: RouterLabel) u32 {
            inline for (0..router_count) |i| {
                const router_record = router_registry.periphs[i];
                if (label == @field(RouterLabel, periphLabel(router_record))) {
                    return periphIdForRecord(router_record);
                }
            }
            unreachable;
        }

        fn flowId(label: FlowLabel) u32 {
            inline for (0..flow_count) |i| {
                const flow_record = flow_registry.periphs[i];
                if (label == @field(FlowLabel, periphLabel(flow_record))) {
                    return periphIdForRecord(flow_record);
                }
            }
            unreachable;
        }

        fn flowEdgeId(comptime label: FlowLabel, edge: FlowEdgeLabel(label)) u32 {
            return flowTypeForLabel(label).edgeId(edge);
        }

        fn flowTypeForLabel(comptime label: FlowLabel) type {
            inline for (0..flow_count) |i| {
                const flow_record = flow_registry.periphs[i];
                if (label == @field(FlowLabel, periphLabel(flow_record))) {
                    return flow_record.FlowType;
                }
            }
            unreachable;
        }

        fn flowStateForLabel(self: *Self, comptime label: FlowLabel) flowTypeForLabel(label).State {
            inline for (0..flow_count) |i| {
                const flow_record = flow_registry.periphs[i];
                if (label == @field(FlowLabel, periphLabel(flow_record))) {
                    return @field(self.runtime.store.stores, periphLabel(flow_record)).get();
                }
            }
            unreachable;
        }

        fn overlayId(label: OverlayLabel) u32 {
            inline for (0..overlay_count) |i| {
                const overlay_record = overlay_registry.periphs[i];
                if (label == @field(OverlayLabel, periphLabel(overlay_record))) {
                    return periphIdForRecord(overlay_record);
                }
            }
            unreachable;
        }

        fn selectionId(label: SelectionLabel) u32 {
            inline for (0..selection_count) |i| {
                const selection_record = selection_registry.periphs[i];
                if (label == @field(SelectionLabel, periphLabel(selection_record))) {
                    return periphIdForRecord(selection_record);
                }
            }
            unreachable;
        }
    };

    return App.make(Impl);
}

fn makeRuntimeStoreBuilder(comptime context: anytype) @TypeOf(context.store_builder) {
    const StoreBuilderType = @TypeOf(context.store_builder);
    var builder = StoreBuilderType.init();
    const ledstrip_registry = context.registries.ledstrip;
    const ledstrip_count = registryPeriphLen(ledstrip_registry);
    const ledstrip_pixel_count = ledStripPixelCount(ledstrip_registry);
    const ledstrip_frame_capacity = ledStripFrameCapacity(ledstrip_registry);
    const LedStripStateType = if (ledstrip_count > 0)
        ledstrip_component.State.make(ledstrip_pixel_count, ledstrip_frame_capacity)
    else
        void;

    inline for (0..registryPeriphLen(context.registries.gpio_button)) |i| {
        const periph = context.registries.gpio_button.periphs[i];
        builder.setStore(periph.label, store.Object.make(context.lib, button.state.Detected, periph.label));
    }
    inline for (0..registryPeriphLen(context.registries.adc_button)) |i| {
        const periph = context.registries.adc_button.periphs[i];
        builder.setStore(periph.label, store.Object.make(context.lib, button.state.Detected, periph.label));
    }
    inline for (0..registryPeriphLen(context.registries.imu)) |i| {
        const periph = context.registries.imu.periphs[i];
        builder.setStore(periph.label, store.Object.make(context.lib, component_imu.State, periph.label));
    }
    inline for (0..ledstrip_count) |i| {
        const periph = ledstrip_registry.periphs[i];
        builder.setStore(periph.label, store.Object.make(context.lib, LedStripStateType, periph.label));
    }
    inline for (0..registryPeriphLen(context.registries.modem)) |i| {
        const periph = context.registries.modem.periphs[i];
        builder.setStore(periph.label, store.Object.make(context.lib, component_modem.State, periph.label));
    }
    inline for (0..registryPeriphLen(context.registries.nfc)) |i| {
        const periph = context.registries.nfc.periphs[i];
        builder.setStore(periph.label, store.Object.make(context.lib, component_nfc.State, periph.label));
    }
    inline for (0..registryPeriphLen(context.registries.wifi_sta)) |i| {
        const periph = context.registries.wifi_sta.periphs[i];
        builder.setStore(periph.label, store.Object.make(context.lib, component_wifi.state.Sta, periph.label));
    }
    inline for (0..registryPeriphLen(context.registries.wifi_ap)) |i| {
        const periph = context.registries.wifi_ap.periphs[i];
        builder.setStore(periph.label, store.Object.make(context.lib, component_wifi.state.Ap, periph.label));
    }

    inline for (0..registryPeriphLen(context.flow_registry)) |i| {
        const flow_record = context.flow_registry.periphs[i];
        builder.setStore(
            flow_record.label,
            makeFlowStoreType(context.lib, flow_record.FlowType),
        );
    }

    inline for (0..context.store_builder.store_count) |i| {
        const binding = context.store_builder.store_bindings[i];
        builder.setStore(binding.name, binding.StoreType);
    }

    inline for (0..context.store_builder.state_binding_count) |i| {
        const binding = context.store_builder.state_bindings[i];
        builder.setState(binding.path, binding.labels[0..binding.labels_len]);
    }

    return builder;
}

fn makeRuntimeNodeBuilder(comptime context: anytype) @TypeOf(context.node_builder) {
    const NodeBuilderType = @TypeOf(context.node_builder);
    var builder = NodeBuilderType.init();

    if (buttonPollerCount(context.registries) > 0) {
        builder.addNode(._zux_button_detector);
        builder.addNode(._zux_button_store_reducer);
    }
    if (registryPeriphLen(context.registries.imu) > 0) {
        builder.addNode(._zux_imu_detector);
        builder.addNode(._zux_imu_store_reducer);
    }
    if (registryPeriphLen(context.registries.ledstrip) > 0) {
        builder.addNode(._zux_ledstrip_store_reducer);
    }
    if (registryPeriphLen(context.registries.modem) > 0) {
        builder.addNode(._zux_modem_store_reducer);
    }
    if (registryPeriphLen(context.registries.nfc) > 0) {
        builder.addNode(._zux_nfc_store_reducer);
    }
    if (registryPeriphLen(context.registries.wifi_sta) > 0) {
        builder.addNode(._zux_wifi_sta_store_reducer);
    }
    if (registryPeriphLen(context.registries.wifi_ap) > 0) {
        builder.addNode(._zux_wifi_ap_store_reducer);
    }

    if (registryPeriphLen(context.flow_registry) > 0) {
        builder.addNode(._zux_flow_store_reducer);
    }
    if (registryPeriphLen(context.overlay_registry) > 0) {
        builder.addNode(._zux_overlay_store_reducer);
    }
    if (registryPeriphLen(context.router_registry) > 0) {
        builder.addNode(._zux_route_store_reducer);
    }
    if (registryPeriphLen(context.selection_registry) > 0) {
        builder.addNode(._zux_selection_store_reducer);
    }
    inline for (0..context.reducer_count) |i| {
        const binding = context.reducer_bindings[i];
        if (nodeBuilderHasTag(context.node_builder, binding.label)) {
            @compileError(
                "zux.assembler.Builder.build reducer label '" ++ binding.name ++ "' is already present in node_builder; reducer nodes are wired automatically",
            );
        }
        builder.addNode(binding.label);
    }

    inline for (0..context.node_builder.len) |i| {
        switch (context.node_builder.ops[i]) {
            .node => |tag| builder.addNode(tag),
            .begin_switch => builder.beginSwitch(),
            .route => |kind| builder.addCase(kind),
            .end_switch => builder.endSwitch(),
        }
    }

    builder.addNode(._zux_store_tick);

    return builder;
}

fn makePeriphInstancesType(comptime build_config_value: anytype, comptime registry: anytype) type {
    const count = registryPeriphLen(registry);
    var fields: [count]builtin.Type.StructField = undefined;

    inline for (0..count) |i| {
        const periph = registry.periphs[i];
        const label_name = periphLabel(periph);
        const FieldType = @field(build_config_value, label_name);

        fields[i] = .{
            .name = sentinelName(label_name),
            .type = FieldType,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(FieldType),
        };
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

fn makeInitConfigType(
    comptime lib: type,
    comptime build_config_value: anytype,
    comptime registries: anytype,
    comptime has_user_root_config: bool,
    comptime UserRootConfig: type,
) type {
    const total_fields = 1 + totalPeriphLen(registries) + @as(usize, if (has_user_root_config) 1 else 0);
    var fields: [total_fields]builtin.Type.StructField = undefined;
    comptime var field_index: usize = 0;

    fields[field_index] = .{
        .name = "allocator",
        .type = lib.mem.Allocator,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(lib.mem.Allocator),
    };
    field_index += 1;

    inline for (configStructInfo(registries).fields) |field| {
        const registry = @field(registries, field.name);
        inline for (0..registryPeriphLen(registry)) |i| {
            const periph = registry.periphs[i];
            const label_name = periphLabel(periph);
            const FieldType = @field(build_config_value, label_name);
            fields[field_index] = .{
                .name = sentinelName(label_name),
                .type = FieldType,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(FieldType),
            };
            field_index += 1;
        }
    }

    if (has_user_root_config) {
        fields[field_index] = .{
            .name = "user_root_config",
            .type = UserRootConfig,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(UserRootConfig),
        };
        field_index += 1;
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

fn configStructInfo(comptime config: anytype) builtin.Type.Struct {
    const ConfigType = @TypeOf(config);
    return switch (@typeInfo(ConfigType)) {
        .@"struct" => |info| info,
        else => @compileError("zux.assembler.Builder.build requires a struct config"),
    };
}

fn totalPeriphLen(comptime registries: anytype) usize {
    const info = configStructInfo(registries);
    comptime var total: usize = 0;

    inline for (info.fields) |field| {
        total += registryPeriphLen(@field(registries, field.name));
    }

    return total;
}

fn totalPollerCount(comptime registries: anytype) usize {
    return buttonPollerCount(registries) + registryPeriphLen(registries.imu);
}

fn buttonPollerCount(comptime registries: anytype) usize {
    return registryPeriphLen(registries.gpio_button) + registryPeriphLen(registries.adc_button);
}

fn nodeBuilderHasTag(comptime builder: anytype, comptime tag: []const u8) bool {
    inline for (0..builder.tag_len) |i| {
        if (comptimeEql(builder.tags[i], tag)) return true;
    }
    return false;
}

fn registryPeriphLen(comptime registry: anytype) usize {
    const RegistryType = @TypeOf(registry);
    if (!@hasField(RegistryType, "periphs") or !@hasField(RegistryType, "len")) {
        @compileError("zux.assembler.Builder.build requires registry fields `periphs` and `len`");
    }
    return registry.len;
}

fn makeLabelEnum(comptime registries: anytype) type {
    const info = configStructInfo(registries);
    const total_len = totalPeriphLen(registries);
    var fields: [total_len]builtin.Type.EnumField = undefined;
    comptime var field_index: usize = 0;

    inline for (info.fields) |field| {
        const registry = @field(registries, field.name);
        inline for (0..registryPeriphLen(registry)) |i| {
            const periph = registry.periphs[i];
            const name = periphLabel(periph);

            inline for (0..field_index) |existing_idx| {
                if (comptimeEql(fields[existing_idx].name, name)) {
                    @compileError("zux.assembler.Builder.build found duplicate periph labels");
                }
            }

            fields[field_index] = .{
                .name = sentinelName(name),
                .value = field_index,
            };
            field_index += 1;
        }
    }

    return @Type(.{
        .@"enum" = .{
            .tag_type = if (total_len == 0) u0 else glib.std.math.IntFittingRange(0, total_len - 1),
            .fields = &fields,
            .decls = &.{},
            .is_exhaustive = true,
        },
    });
}

fn makeSingleRegistryLabelEnum(comptime registry: anytype) type {
    const total_len = registryPeriphLen(registry);
    var fields: [total_len]builtin.Type.EnumField = undefined;

    inline for (0..total_len) |i| {
        const record = registry.periphs[i];
        const name = periphLabel(record);

        inline for (0..i) |existing_idx| {
            if (comptimeEql(fields[existing_idx].name, name)) {
                @compileError("zux.assembler.Builder.build found duplicate router labels");
            }
        }

        fields[i] = .{
            .name = sentinelName(name),
            .value = i,
        };
    }

    return @Type(.{
        .@"enum" = .{
            .tag_type = if (total_len == 0) u0 else glib.std.math.IntFittingRange(0, total_len - 1),
            .fields = &fields,
            .decls = &.{},
            .is_exhaustive = true,
        },
    });
}

fn makePeriphIdTable(comptime registries: anytype) [totalPeriphLen(registries)]u32 {
    const info = configStructInfo(registries);
    const total_len = totalPeriphLen(registries);
    var ids: [total_len]u32 = undefined;
    comptime var field_index: usize = 0;

    inline for (info.fields) |field| {
        const registry = @field(registries, field.name);
        inline for (0..registryPeriphLen(registry)) |i| {
            const periph = registry.periphs[i];
            ids[field_index] = periphIdForRecord(periph);
            field_index += 1;
        }
    }

    return ids;
}

fn makePeriphKindTable(comptime registries: anytype) [totalPeriphLen(registries)]PeriphDispatchKind {
    const info = configStructInfo(registries);
    const total_len = totalPeriphLen(registries);
    var kinds: [total_len]PeriphDispatchKind = undefined;
    comptime var field_index: usize = 0;

    inline for (info.fields) |field| {
        const registry = @field(registries, field.name);
        inline for (0..registryPeriphLen(registry)) |i| {
            const periph = registry.periphs[i];
            kinds[field_index] = dispatchKindForRecord(periph);
            field_index += 1;
        }
    }

    return kinds;
}

const PeriphDispatchKind = enum {
    single_button,
    grouped_button,
    imu,
    led_strip,
    modem,
    nfc,
    wifi_sta,
    wifi_ap,
};

fn periphIdForRecord(comptime periph: anytype) u32 {
    const PeriphType = @TypeOf(periph);
    if (@hasField(PeriphType, "id")) {
        return @field(periph, "id");
    }
    @compileError("zux.assembler.Builder.build periph must expose `id`");
}

fn dispatchKindForRecord(comptime periph: anytype) PeriphDispatchKind {
    const PeriphType = @TypeOf(periph);
    if (!@hasField(PeriphType, "control_type")) {
        @compileError("zux.assembler.Builder.build periph must expose `control_type`");
    }
    const ControlType = @field(periph, "control_type");
    if (ControlType == @import("drivers").button.Single) return .single_button;
    if (ControlType == @import("drivers").button.Grouped) return .grouped_button;
    if (ControlType == @import("drivers").imu) return .imu;
    if (ControlType == ledstrip.LedStrip) return .led_strip;
    if (ControlType == modem_api.Modem) return .modem;
    if (ControlType == @import("drivers").nfc.Reader) return .nfc;
    if (ControlType == @import("drivers").wifi.Sta) return .wifi_sta;
    if (ControlType == @import("drivers").wifi.Ap) return .wifi_ap;
    @compileError("zux.assembler.Builder.build encountered unsupported periph control_type");
}

fn ledStripPixelCount(comptime registry: anytype) usize {
    const count = registryPeriphLen(registry);
    if (count == 0) return 0;

    const pixel_count = registry.periphs[0].pixel_count;
    inline for (1..count) |i| {
        if (registry.periphs[i].pixel_count != pixel_count) {
            @compileError("zux.assembler.Builder.build currently requires all led strips to share the same pixel_count");
        }
    }
    return pixel_count;
}

fn ledStripFrameCapacity(comptime registry: anytype) usize {
    const pixel_count = ledStripPixelCount(registry);
    if (pixel_count == 0) return 0;
    return if (pixel_count < 2) 2 else pixel_count;
}

fn messageSourceId(message: Message) u32 {
    return switch (message.body) {
        .button_gesture => |event| event.source_id,
        .raw_single_button => |event| event.source_id,
        .raw_grouped_button => |event| event.source_id,
        .ledstrip_set => |event| event.source_id,
        .ledstrip_set_pixels => |event| event.source_id,
        .ledstrip_flash => |event| event.source_id,
        .ledstrip_pingpong => |event| event.source_id,
        .ledstrip_rotate => |event| event.source_id,
        .raw_imu_accel => |event| event.source_id,
        .raw_imu_gyro => |event| event.source_id,
        .imu_motion => |event| event.source_id,
        .modem_sim_state_changed => |event| event.source_id,
        .modem_network_registration_changed => |event| event.source_id,
        .modem_network_signal_changed => |event| event.source_id,
        .modem_data_packet_state_changed => |event| event.source_id,
        .modem_data_apn_changed => |event| event.source_id,
        .modem_call_incoming => |event| event.source_id,
        .modem_call_state_changed => |event| event.source_id,
        .modem_call_ended => |event| event.source_id,
        .modem_sms_received => |event| event.source_id,
        .modem_gnss_state_changed => |event| event.source_id,
        .modem_gnss_fix_changed => |event| event.source_id,
        .nfc_found => |event| event.source_id,
        .nfc_read => |event| event.source_id,
        .wifi_sta_scan_result => |event| event.source_id,
        .wifi_sta_connected => |event| event.source_id,
        .wifi_sta_disconnected => |event| event.source_id,
        .wifi_sta_got_ip => |event| event.source_id,
        .wifi_sta_lost_ip => |event| event.source_id,
        .wifi_ap_started => |event| event.source_id,
        .wifi_ap_stopped => |event| event.source_id,
        .wifi_ap_client_joined => |event| event.source_id,
        .wifi_ap_client_left => |event| event.source_id,
        .wifi_ap_lease_granted => |event| event.source_id,
        .wifi_ap_lease_released => |event| event.source_id,
        else => @panic("zux.assembler.Builder.messageSourceId expected source-tagged event"),
    };
}

fn messageRouterId(message: Message) u32 {
    return switch (message.body) {
        .ui_route_push => |event| event.source_id,
        .ui_route_replace => |event| event.source_id,
        .ui_route_reset => |event| event.source_id,
        .ui_route_pop => |event| event.source_id,
        .ui_route_pop_to_root => |event| event.source_id,
        .ui_route_set_transitioning => |event| event.source_id,
        else => @panic("zux.assembler.Builder.messageRouterId expected route event"),
    };
}

fn messageFlowId(message: Message) u32 {
    return switch (message.body) {
        .ui_flow_move => |event| event.source_id,
        .ui_flow_reset => |event| event.source_id,
        else => @panic("zux.assembler.Builder.messageFlowId expected flow event"),
    };
}

fn messageOverlayId(message: Message) u32 {
    return switch (message.body) {
        .ui_overlay_show => |event| event.source_id,
        .ui_overlay_hide => |event| event.source_id,
        .ui_overlay_set_name => |event| event.source_id,
        .ui_overlay_set_blocking => |event| event.source_id,
        else => @panic("zux.assembler.Builder.messageOverlayId expected overlay event"),
    };
}

fn messageSelectionId(message: Message) u32 {
    return switch (message.body) {
        .ui_selection_next => |event| event.source_id,
        .ui_selection_prev => |event| event.source_id,
        .ui_selection_set => |event| event.source_id,
        .ui_selection_reset => |event| event.source_id,
        .ui_selection_set_count => |event| event.source_id,
        .ui_selection_set_loop => |event| event.source_id,
        else => @panic("zux.assembler.Builder.messageSelectionId expected selection event"),
    };
}

fn adaptSpawnConfig(comptime Target: type, source: anytype) Target {
    var out: Target = .{};
    const Source = @TypeOf(source);

    inline for (@typeInfo(Target).@"struct".fields) |field| {
        if (@hasField(Source, field.name)) {
            @field(out, field.name) = @field(source, field.name);
        }
    }

    return out;
}

fn periphLabel(comptime periph: anytype) []const u8 {
    const PeriphType = @TypeOf(periph);
    if (@hasField(PeriphType, "label")) {
        return labelText(@field(periph, "label"));
    }
    if (@hasDecl(PeriphType, "label")) {
        return labelText(periph.label());
    }
    @compileError("zux.assembler.Builder.build periph must expose `label`");
}

fn comptimeEql(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    inline for (a, 0..) |ch, idx| {
        if (ch != b[idx]) return false;
    }
    return true;
}

fn labelText(comptime raw_label: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(raw_label))) {
        .enum_literal => @tagName(raw_label),
        .pointer => |ptr| switch (ptr.size) {
            .slice => raw_label,
            .one => switch (@typeInfo(ptr.child)) {
                .array => raw_label[0..],
                else => @compileError("zux.assembler.Builder.build label must be enum_literal or []const u8"),
            },
            else => @compileError("zux.assembler.Builder.build label must be enum_literal or []const u8"),
        },
        .array => raw_label[0..],
        else => @compileError("zux.assembler.Builder.build label must be enum_literal or []const u8"),
    };
}

fn sentinelName(comptime text: []const u8) [:0]const u8 {
    const terminated = text ++ "\x00";
    return terminated[0..text.len :0];
}
