const glib = @import("glib");
const bt = @import("bt");
const drivers = @import("drivers");
const ledstrip = @import("ledstrip");
const modem_api = drivers;

const App = @import("../App.zig");
const component_audio_system = @import("../component/audio_system.zig");
const button = @import("../component/button.zig");
const component_display = @import("../component/display.zig");
const component_imu = @import("../component/Imu.zig");
const component_modem = @import("../component/modem.zig");
const component_nfc = @import("../component/Nfc.zig");
const component_switch = @import("../component/switch.zig");
const component_touch = @import("../component/touch.zig");
const component_wifi = @import("../component/wifi.zig");
const ledstrip_component = @import("../component/ledstrip.zig");
const Emitter = @import("../pipeline/Emitter.zig");
const Message = @import("../pipeline/Message.zig");
const Node = @import("../pipeline/Node.zig");
const NodeBuilder = @import("../pipeline/NodeBuilder.zig");
const Poller = @import("../pipeline/Poller.zig");
const Pipeline = @import("../pipeline/Pipeline.zig");
const store = @import("../Store.zig");
const build_config = @import("BuildConfig.zig");

const root = @This();

pub fn init() root {
    return .{};
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
    const bt_registry = context.registries.bt;
    const audio_system_registry = context.registries.audio_system;
    const display_registry = context.registries.display;
    const single_button_registry = context.registries.single_button;
    const imu_registry = context.registries.imu;
    const ledstrip_registry = context.registries.ledstrip;
    const modem_registry = context.registries.modem;
    const nfc_registry = context.registries.nfc;
    const switch_registry = context.registries.switch_output;
    const pwm_registry = context.registries.pwm;
    const touch_registry = context.registries.touch;
    const wifi_sta_registry = context.registries.wifi_sta;
    const wifi_ap_registry = context.registries.wifi_ap;
    const adc_count = registryPeriphLen(adc_registry);
    const bt_count = registryPeriphLen(bt_registry);
    const audio_system_count = registryPeriphLen(audio_system_registry);
    const display_count = registryPeriphLen(display_registry);
    const single_button_count = registryPeriphLen(single_button_registry);
    const imu_count = registryPeriphLen(imu_registry);
    const ledstrip_count = registryPeriphLen(ledstrip_registry);
    const modem_count = registryPeriphLen(modem_registry);
    const nfc_count = registryPeriphLen(nfc_registry);
    const switch_count = registryPeriphLen(switch_registry);
    const pwm_count = registryPeriphLen(pwm_registry);
    const touch_count = registryPeriphLen(touch_registry);
    const wifi_sta_count = registryPeriphLen(wifi_sta_registry);
    const wifi_ap_count = registryPeriphLen(wifi_ap_registry);
    const configured_render_count = context.render_count;
    const configured_reducer_count = context.reducer_count;
    const has_button_runtime = (adc_count + single_button_count) > 0;
    const has_audio_system_runtime = audio_system_count > 0;
    const has_display_runtime = display_count > 0;
    const has_imu_runtime = imu_count > 0;
    const has_ledstrip_runtime = ledstrip_count > 0;
    const has_modem_runtime = modem_count > 0;
    const has_nfc_runtime = nfc_count > 0;
    const has_switch_runtime = switch_count > 0;
    const has_pwm_runtime = pwm_count > 0;
    const has_touch_runtime = touch_count > 0;
    const has_wifi_sta_runtime = wifi_sta_count > 0;
    const has_wifi_ap_runtime = wifi_ap_count > 0;
    const single_button_poller_count = countRegistryControlType(
        context.build_config,
        single_button_registry,
        drivers.button.Single,
    );
    const grouped_button_poller_count = countRegistryControlType(
        context.build_config,
        adc_registry,
        drivers.button.Grouped,
    );
    const touch_poller_count = countRegistryControlType(
        context.build_config,
        touch_registry,
        drivers.Touch,
    );
    comptime validateRegistryControlTypes(context.build_config, single_button_registry, &.{
        drivers.button.Single,
    }, "button/single");
    comptime validateRegistryControlTypes(context.build_config, adc_registry, &.{
        drivers.button.Grouped,
    }, "button/grouped");
    comptime validateRegistryControlTypes(context.build_config, touch_registry, &.{
        drivers.Touch,
    }, "touch");
    comptime validateRegistryControlTypes(context.build_config, bt_registry, &.{
        bt.Host,
    }, "bt");
    const runtime_poller_count = totalPollerCount(context.build_config, context.registries);
    const ledstrip_pixel_count = ledStripPixelCount(ledstrip_registry);
    const ledstrip_frame_capacity = ledStripFrameCapacity(ledstrip_registry);
    const runtime_store_builder = makeRuntimeStoreBuilder(context);
    const StoreType = runtime_store_builder.make(context.grt);
    const GeneratedInitialState = makeInitialStateType(StoreType.Stores);

    const runtime_node_builder = makeRuntimeNodeBuilder(context);
    const BuiltRoot = runtime_node_builder.make();

    const SingleButtonInstances = makePeriphInstancesType(context.build_config, single_button_registry);
    const BtInstances = makePeriphInstancesType(context.build_config, bt_registry);
    const AudioSystemInstances = makePeriphInstancesType(context.build_config, audio_system_registry);
    const DisplayInstances = makePeriphInstancesType(context.build_config, display_registry);
    const GroupedButtonInstances = makePeriphInstancesType(context.build_config, adc_registry);
    const ImuInstances = makePeriphInstancesType(context.build_config, imu_registry);
    const LedStripInstances = makePeriphInstancesType(context.build_config, ledstrip_registry);
    const ModemInstances = makePeriphInstancesType(context.build_config, modem_registry);
    const NfcInstances = makePeriphInstancesType(context.build_config, nfc_registry);
    const SwitchInstances = makePeriphInstancesType(context.build_config, switch_registry);
    const PwmInstances = makePeriphInstancesType(context.build_config, pwm_registry);
    const TouchInstances = makePeriphInstancesType(context.build_config, touch_registry);
    const WifiStaInstances = makePeriphInstancesType(context.build_config, wifi_sta_registry);
    const WifiApInstances = makePeriphInstancesType(context.build_config, wifi_ap_registry);
    const AppLabel = makeLabelEnum(context.registries);
    const periph_ids = makePeriphIdTable(context.registries);
    const periph_kinds = makePeriphKindTable(context.registries);
    const SingleButtonPoller = button.SinglePoller.make(context.grt);
    const GroupedButtonPoller = button.GroupedPoller.make(context.grt);
    const TouchPoller = component_touch.Poller.make(context.grt);
    const ImuPollerType = component_imu.Poller.make(context.grt);
    const ImuPollerWrapper = if (has_imu_runtime) struct {
        inner: ImuPollerType,

        pub fn bindOutput(self: *@This(), out: Emitter) void {
            self.inner.bindOutput(out);
        }

        pub fn start(self: *@This(), config: Poller.Config) !void {
            self.inner.poll_interval = config.poll_interval;
            self.inner.task_options = config.task_options;
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
        )
    else
        void;
    const BuiltPipeline = Pipeline.make(context.grt, context.custom_event_registar);
    const PipelineSink = struct {
        pipeline: *BuiltPipeline,

        pub fn emit(self: *@This(), message: Message) !void {
            try self.pipeline.inject(message);
        }
    };
    const StoreReducerType = store.Reducer.make(StoreType);
    const RuntimeReducerHook = makeRuntimeReducerHook(StoreType);
    const ConfiguredReducerNode = struct {
        stores: *StoreType.Stores,
        hook: RuntimeReducerHook,
        out: ?Emitter = null,

        pub fn init(stores: *StoreType.Stores, hook: RuntimeReducerHook) @This() {
            return .{
                .stores = stores,
                .hook = hook,
            };
        }

        pub fn node(self: *@This()) Node {
            return Node.init(@This(), self);
        }

        pub fn bindOutput(self: *@This(), out: Emitter) void {
            self.out = out;
        }

        pub fn process(self: *@This(), message: Message) !void {
            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };

            var noop = NoopSink{};
            const emit = self.out orelse Emitter.init(&noop);
            try self.hook.reduce(self.stores, message, emit);
            if (message.body == .tick) {
                if (self.out) |out| {
                    try out.emit(message);
                }
            }
        }
    };
    const BypassNode = struct {
        out: ?Emitter = null,

        pub fn node(self: *@This()) Node {
            return Node.init(@This(), self);
        }

        pub fn bindOutput(self: *@This(), out: Emitter) void {
            self.out = out;
        }

        pub fn process(self: *@This(), message: Message) !void {
            if (self.out) |out| {
                try out.emit(message);
            }
        }
    };
    const StoreTickNode = struct {
        store: *StoreType,
        out: ?Emitter = null,

        pub fn node(self: *@This()) Node {
            return Node.init(@This(), self);
        }

        pub fn bindOutput(self: *@This(), out: Emitter) void {
            self.out = out;
        }

        pub fn process(self: *@This(), message: Message) !void {
            if (message.body == .tick) {
                self.store.tick();
            }
            if (self.out) |out| {
                try out.emit(message);
            }
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

        pub fn process(self: *@This(), message: Message) !void {
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
                            try component_nfc.Reducer.reduce(
                                &@field(self.stores, periphLabel(periph)),
                                message,
                                emit,
                            );
                            return;
                        }
                    }
                    return;
                },
                .tick => {
                    if (self.out) |out| {
                        try out.emit(message);
                    }
                },
                else => {
                    if (self.out) |out| {
                        try out.emit(message);
                    }
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

        pub fn process(self: *@This(), message: Message) !void {
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
                            try self.reducer.reduce(
                                &@field(self.stores, periphLabel(periph)),
                                message,
                                emit,
                            );
                            return;
                        }
                    }
                    return;
                },
                .tick => {
                    if (self.out) |out| {
                        try out.emit(message);
                    }
                },
                else => {
                    if (self.out) |out| {
                        try out.emit(message);
                    }
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

        pub fn process(self: *@This(), message: Message) !void {
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
                            try self.reducer.reduce(
                                &@field(self.stores, periphLabel(periph)),
                                message,
                                emit,
                            );
                            return;
                        }
                    }
                    return;
                },
                .tick => {
                    if (self.out) |out| {
                        try out.emit(message);
                    }
                },
                else => {
                    if (self.out) |out| {
                        try out.emit(message);
                    }
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

        pub fn process(self: *@This(), message: Message) !void {
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
                            try self.reducers[i].reduce(
                                &@field(self.stores, periphLabel(periph)),
                                message,
                                emit,
                            );
                            return;
                        }
                    }
                    return;
                },
                .tick => {
                    if (self.out) |out| {
                        try out.emit(message);
                    }
                },
                else => {
                    if (self.out) |out| {
                        try out.emit(message);
                    }
                },
            }
        }
    } else void;

    const Impl = struct {
        const Self = @This();

        pub const Lib = context.grt;
        pub const Config = context.assembler_config;
        pub const BuildConfig = @TypeOf(context.build_config);
        pub const build_config = context.build_config;
        pub const registries = .{
            .adc_button = adc_registry,
            .bt = bt_registry,
            .audio_system = audio_system_registry,
            .display = display_registry,
            .single_button = single_button_registry,
            .imu = imu_registry,
            .ledstrip = ledstrip_registry,
            .modem = modem_registry,
            .nfc = nfc_registry,
            .switch_output = switch_registry,
            .pwm = pwm_registry,
            .touch = touch_registry,
            .wifi_sta = wifi_sta_registry,
            .wifi_ap = wifi_ap_registry,
        };
        pub const ReducerHook = RuntimeReducerHook;
        pub const RenderHook = makeRuntimeRenderHook(Self);
        pub const InitConfig = makeInitConfigType(
            context.grt,
            GeneratedInitialState,
            context.build_config,
            context.registries,
            ReducerHook,
            RenderHook,
            context.reducer_bindings,
            configured_reducer_count,
            context.render_bindings,
            configured_render_count,
        );
        pub const StartConfig = App.StartConfig;
        pub const Store = StoreType;
        pub const InitialState = GeneratedInitialState;
        pub const Root = BuiltRoot;
        pub const Label = AppLabel;
        pub const PeriphLabel = AppLabel;
        pub const poller_count: usize = runtime_poller_count;
        pub const pixel_count: usize = ledstrip_pixel_count;
        pub const FrameType = ledstrip.Frame.make(pixel_count);
        pub const CustomEventRegistar = BuiltPipeline.CustomEventRegistar;

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

        pub fn AudioSystem(comptime label: PeriphLabel) type {
            return audioSystemType(label);
        }

        pub fn sourceId(label: PeriphLabel) u32 {
            return periphId(label);
        }

        const RuntimeRenderSubscriber = struct {
            runtime: *Runtime,
            hook: RenderHook,

            pub fn notify(self: *@This(), notification: @import("../Store.zig").Subscriber.Notification) void {
                _ = notification;

                var app: Self = undefined;
                app.runtime = self.runtime;
                if (@hasField(Self, "started")) {
                    app.started = context.grt.std.atomic.Value(bool).init(true);
                }
                if (@hasField(Self, "manual_ticker")) {
                    app.manual_ticker = true;
                }
                if (@hasField(Self, "closed")) {
                    app.closed = false;
                }
                if (@hasField(Self, "last_event")) {
                    app.last_event = null;
                }
                if (@hasField(Self, "last_grouped_button_ids")) {
                    const Ids = @FieldType(Self, "last_grouped_button_ids");
                    app.last_grouped_button_ids = [_]?u32{null} ** @typeInfo(Ids).array.len;
                }

                self.hook.render(&app) catch |err| {
                    @panic(@errorName(err));
                };
            }
        };

        const LedStripRenderSubscriber = struct {
            runtime: *Runtime,
            label: PeriphLabel,

            pub fn notify(self: *@This(), notification: @import("../Store.zig").Subscriber.Notification) void {
                _ = notification;

                inline for (0..ledstrip_count) |i| {
                    const periph = ledstrip_registry.periphs[i];
                    if (self.label == @field(PeriphLabel, periphLabel(periph))) {
                        const state = @field(self.runtime.store.stores, periphLabel(periph)).get();
                        const strip = @field(self.runtime.led_strips, periphLabel(periph));
                        strip.setPixels(0, state.current.pixels[0..]);
                        strip.refresh();
                        return;
                    }
                }
            }
        };

        const Runtime = struct {
            allocator: glib.std.mem.Allocator,
            store: StoreType,
            single_buttons: SingleButtonInstances,
            bts: BtInstances,
            audio_systems: AudioSystemInstances,
            displays: DisplayInstances,
            grouped_buttons: GroupedButtonInstances,
            imus: ImuInstances,
            led_strips: LedStripInstances,
            modems: ModemInstances,
            nfcs: NfcInstances,
            switches: SwitchInstances,
            pwms: PwmInstances,
            touches: TouchInstances,
            wifi_stas: WifiStaInstances,
            wifi_aps: WifiApInstances,
            detector: if (has_button_runtime) button.Reducer else void,
            store_reducer: if (has_button_runtime) StoreReducerType else void,
            audio_system_store_reducer: if (has_audio_system_runtime) StoreReducerType else void,
            display_store_reducer: if (has_display_runtime) StoreReducerType else void,
            imu_detector: if (has_imu_runtime) component_imu.Reducer else void,
            imu_store_reducer: if (has_imu_runtime) StoreReducerType else void,
            ledstrip_store_reducer: if (has_ledstrip_runtime) StoreReducerType else void,
            modem_event_hooks: if (has_modem_runtime) [modem_count]component_modem.EventHook else void,
            modem_reducer: if (has_modem_runtime) component_modem.Reducer else void,
            modem_store_reducer: if (has_modem_runtime) ModemStoreReducerNode else void,
            nfc_event_hooks: if (has_nfc_runtime) [nfc_count]component_nfc.EventHook else void,
            nfc_store_reducer: if (has_nfc_runtime) NfcStoreReducerNode else void,
            switch_store_reducer: if (has_switch_runtime) StoreReducerType else void,
            pwm_store_reducer: if (has_pwm_runtime) StoreReducerType else void,
            touch_store_reducer: if (has_touch_runtime) StoreReducerType else void,
            wifi_sta_event_hooks: if (has_wifi_sta_runtime) [wifi_sta_count]component_wifi.EventHook else void,
            wifi_sta_reducer: if (has_wifi_sta_runtime) component_wifi.StaReducer else void,
            wifi_ap_reducers: if (has_wifi_ap_runtime) [wifi_ap_count]component_wifi.ApReducer else void,
            wifi_sta_store_reducer: if (has_wifi_sta_runtime) WifiStaStoreReducerNode else void,
            wifi_ap_store_reducer: if (has_wifi_ap_runtime) WifiApStoreReducerNode else void,
            configured_reducers: [configured_reducer_count]ConfiguredReducerNode = undefined,
            render_hooks: [configured_render_count]RuntimeRenderSubscriber = undefined,
            render_subscribers: [configured_render_count]@import("../Store.zig").Subscriber = undefined,
            ledstrip_render_hooks: if (has_ledstrip_runtime) [ledstrip_count]LedStripRenderSubscriber else void,
            ledstrip_render_subscribers: if (has_ledstrip_runtime) [ledstrip_count]@import("../Store.zig").Subscriber else void,
            custom_pipeline_bypass: BypassNode = .{},
            store_tick: StoreTickNode,
            root_config: BuiltRoot.Config,
            root: Node,
            pipeline: BuiltPipeline,
            pipeline_sink: PipelineSink,
            poller_config: Poller.Config,
            single_button_pollers: [single_button_poller_count]SingleButtonPoller = undefined,
            grouped_button_pollers: [grouped_button_poller_count]GroupedButtonPoller = undefined,
            touch_pollers: [touch_poller_count]TouchPoller = undefined,
            imu_pollers: [imu_count]ImuPollerWrapper = undefined,
            pollers: [runtime_poller_count]Poller = undefined,

            pub fn init(init_config: InitConfig) !*Runtime {
                const runtime = try init_config.allocator.create(Runtime);
                errdefer init_config.allocator.destroy(runtime);
                var subscribed_render_count: usize = 0;
                var subscribed_ledstrip_render_count: usize = 0;

                runtime.allocator = init_config.allocator;
                runtime.single_buttons = initSingleButtonInstances(init_config);
                runtime.bts = initBtInstances(init_config);
                runtime.audio_systems = initAudioSystemInstances(init_config);
                runtime.displays = initDisplayInstances(init_config);
                runtime.grouped_buttons = initGroupedButtonInstances(init_config);
                runtime.imus = initImuInstances(init_config);
                runtime.led_strips = initLedStripInstances(init_config);
                runtime.modems = initModemInstances(init_config);
                runtime.nfcs = initNfcInstances(init_config);
                runtime.switches = initSwitchInstances(init_config);
                runtime.pwms = initPwmInstances(init_config);
                runtime.touches = initTouchInstances(init_config);
                runtime.wifi_stas = initWifiStaInstances(init_config);
                runtime.wifi_aps = initWifiApInstances(init_config);

                var stores = try initStoreValues(init_config.allocator, init_config.initial_state);
                configureRuntimeStoreValues(&stores, init_config);
                runtime.store = try StoreType.init(init_config.allocator, stores);
                errdefer {
                    if (has_ledstrip_runtime) {
                        inline for (0..ledstrip_count) |i| {
                            if (i >= subscribed_ledstrip_render_count) break;
                            const periph = ledstrip_registry.periphs[i];
                            _ = @field(runtime.store.stores, periphLabel(periph)).unsubscribe(&runtime.ledstrip_render_subscribers[i]);
                        }
                    }
                    inline for (0..configured_render_count) |i| {
                        if (i >= subscribed_render_count) break;
                        const binding = context.render_bindings[i];
                        _ = runtime.unsubscribeRenderPath(binding.path, &runtime.render_subscribers[i]);
                    }
                    runtime.store.deinit();
                    deinitStoreValues(&runtime.store.stores);
                }
                if (has_ledstrip_runtime) {
                    inline for (0..ledstrip_count) |i| {
                        const periph = ledstrip_registry.periphs[i];
                        runtime.ledstrip_render_hooks[i] = .{
                            .runtime = runtime,
                            .label = @field(PeriphLabel, periphLabel(periph)),
                        };
                        runtime.ledstrip_render_subscribers[i] = @import("../Store.zig").Subscriber.init(&runtime.ledstrip_render_hooks[i]);
                        try @field(runtime.store.stores, periphLabel(periph)).subscribe(&runtime.ledstrip_render_subscribers[i]);
                        subscribed_ledstrip_render_count = i + 1;
                    }
                }
                inline for (0..configured_render_count) |i| {
                    const binding = context.render_bindings[i];
                    const hook = @field(init_config, binding.name) orelse return error.MissingRenderHook;
                    runtime.render_hooks[i] = .{
                        .runtime = runtime,
                        .hook = hook,
                    };
                    runtime.render_subscribers[i] = @import("../Store.zig").Subscriber.init(&runtime.render_hooks[i]);
                    try runtime.subscribeRenderPath(binding.path, &runtime.render_subscribers[i]);
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
                if (has_audio_system_runtime) {
                    runtime.audio_system_store_reducer = StoreReducerType.init(
                        &runtime.store.stores,
                        AudioSystemStoreReducerFn.reduce,
                    );
                }
                if (has_display_runtime) {
                    runtime.display_store_reducer = StoreReducerType.init(
                        &runtime.store.stores,
                        DisplayStoreReducerFn.reduce,
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
                if (has_switch_runtime) {
                    runtime.switch_store_reducer = StoreReducerType.init(
                        &runtime.store.stores,
                        SwitchStoreReducerFn.reduce,
                    );
                }
                if (has_pwm_runtime) {
                    runtime.pwm_store_reducer = StoreReducerType.init(
                        &runtime.store.stores,
                        PwmStoreReducerFn.reduce,
                    );
                }

                inline for (0..configured_reducer_count) |i| {
                    const binding = context.reducer_bindings[i];
                    const hook = @field(init_config, binding.name) orelse return error.MissingReducerHook;
                    runtime.configured_reducers[i] = ConfiguredReducerNode.init(
                        &runtime.store.stores,
                        hook,
                    );
                }
                runtime.store_tick = .{
                    .store = &runtime.store,
                };
                runtime.custom_pipeline_bypass = .{};

                runtime.pipeline = try BuiltPipeline.init(init_config.allocator, init_config.pipeline_config);
                errdefer runtime.pipeline.deinit();

                runtime.pipeline_sink = .{
                    .pipeline = &runtime.pipeline,
                };
                runtime.poller_config = init_config.poller_config;

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
                if (has_wifi_sta_runtime) {
                    inline for (0..wifi_sta_count) |i| {
                        runtime.wifi_sta_event_hooks[i] = component_wifi.EventHook.init();
                        runtime.wifi_sta_event_hooks[i].bindOutput(Emitter.init(&runtime.pipeline_sink));
                    }
                }
                if (has_touch_runtime) {
                    runtime.touch_store_reducer = StoreReducerType.init(
                        &runtime.store.stores,
                        TouchStoreReducerFn.reduce,
                    );
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
                if (has_wifi_sta_runtime) {
                    inline for (&runtime.wifi_sta_event_hooks) |*hook| {
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
                if (has_ledstrip_runtime) {
                    inline for (0..ledstrip_count) |i| {
                        const periph = ledstrip_registry.periphs[i];
                        _ = @field(runtime.store.stores, periphLabel(periph)).unsubscribe(&runtime.ledstrip_render_subscribers[i]);
                    }
                }
                inline for (0..configured_render_count) |i| {
                    const binding = context.render_bindings[i];
                    _ = runtime.unsubscribeRenderPath(binding.path, &runtime.render_subscribers[i]);
                }

                runtime.store.deinit();
                deinitStoreValues(&runtime.store.stores);
                runtime.allocator.destroy(runtime);
            }

            fn subscribeRenderPath(
                runtime: *Runtime,
                comptime path: []const u8,
                subscriber: *@import("../Store.zig").Subscriber,
            ) !void {
                if (comptime storePathLabel(path)) |label| {
                    if (!@hasField(StoreType.Stores, label)) {
                        @compileError("zux render $store path references unknown store '" ++ label ++ "'");
                    }
                    try @field(runtime.store.stores, label).subscribe(subscriber);
                    return;
                }
                try runtime.store.subscribePath(path, subscriber);
            }

            fn unsubscribeRenderPath(
                runtime: *Runtime,
                comptime path: []const u8,
                subscriber: *@import("../Store.zig").Subscriber,
            ) bool {
                if (comptime storePathLabel(path)) |label| {
                    if (!@hasField(StoreType.Stores, label)) {
                        @compileError("zux render $store path references unknown store '" ++ label ++ "'");
                    }
                    return @field(runtime.store.stores, label).unsubscribe(subscriber);
                }
                return runtime.store.unsubscribePath(path, subscriber);
            }

            fn initPollers(runtime: *Runtime) void {
                inline for (0..single_button_count) |i| {
                    const periph = single_button_registry.periphs[i];
                    if (comptime isVirtualPeriph(periph)) continue;
                    const label_name = comptime periphLabel(periph);
                    const ButtonType = @TypeOf(@field(runtime.single_buttons, label_name));
                    if (comptime ButtonType == drivers.button.Single) {
                        const poller_index = countRegistryControlTypeBefore(
                            context.build_config,
                            single_button_registry,
                            i,
                            drivers.button.Single,
                        );
                        runtime.pollers[poller_index] = runtime.single_button_pollers[poller_index].init(
                            @field(runtime.single_buttons, label_name),
                            .{
                                .source_id = periphIdForRecord(periph),
                            },
                        );
                        runtime.pollers[poller_index].bindOutput(Emitter.init(&runtime.pipeline_sink));
                    } else {
                        @compileError("zux.assembler.Builder.build button/single must use drivers.button.Single");
                    }
                }

                inline for (0..adc_count) |i| {
                    const periph = adc_registry.periphs[i];
                    const label_name = comptime periphLabel(periph);
                    const ButtonType = @TypeOf(@field(runtime.grouped_buttons, label_name));
                    if (comptime ButtonType == drivers.button.Grouped) {
                        const grouped_poller_index = countRegistryControlTypeBefore(
                            context.build_config,
                            adc_registry,
                            i,
                            drivers.button.Grouped,
                        );
                        const poller_index = single_button_poller_count + grouped_poller_index;
                        runtime.pollers[poller_index] = runtime.grouped_button_pollers[grouped_poller_index].init(
                            @field(runtime.grouped_buttons, label_name),
                            .{
                                .source_id = periphIdForRecord(periph),
                            },
                        );
                        runtime.pollers[poller_index].bindOutput(Emitter.init(&runtime.pipeline_sink));
                    } else {
                        @compileError("zux.assembler.Builder.build button/grouped must use drivers.button.Grouped");
                    }
                }

                inline for (0..touch_count) |i| {
                    const periph = touch_registry.periphs[i];
                    const label_name = comptime periphLabel(periph);
                    const TouchType = @TypeOf(@field(runtime.touches, label_name));
                    if (comptime TouchType == drivers.Touch) {
                        const touch_poller_index = countRegistryControlTypeBefore(
                            context.build_config,
                            touch_registry,
                            i,
                            drivers.Touch,
                        );
                        const poller_index = single_button_poller_count + grouped_button_poller_count + touch_poller_index;
                        runtime.pollers[poller_index] = runtime.touch_pollers[touch_poller_index].init(
                            @field(runtime.touches, label_name),
                            .{
                                .source_id = periphIdForRecord(periph),
                            },
                        );
                        runtime.pollers[poller_index].bindOutput(Emitter.init(&runtime.pipeline_sink));
                    } else {
                        @compileError("zux.assembler.Builder.build touch must use drivers.Touch");
                    }
                }

                inline for (0..imu_count) |i| {
                    const periph = imu_registry.periphs[i];
                    const label_name = comptime periphLabel(periph);
                    const poller_index = single_button_poller_count + grouped_button_poller_count + touch_poller_count + i;
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
                if (has_audio_system_runtime) {
                    config._zux_audio_system_store_reducer = runtime.audio_system_store_reducer.node();
                }
                if (has_display_runtime) {
                    config._zux_display_store_reducer = runtime.display_store_reducer.node();
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
                if (has_switch_runtime) {
                    config._zux_switch_store_reducer = runtime.switch_store_reducer.node();
                }
                if (has_pwm_runtime) {
                    config._zux_pwm_store_reducer = runtime.pwm_store_reducer.node();
                }
                if (has_touch_runtime) {
                    config._zux_touch_store_reducer = runtime.touch_store_reducer.node();
                }
                if (has_wifi_sta_runtime) {
                    config._zux_wifi_sta_store_reducer = runtime.wifi_sta_store_reducer.node();
                }
                if (has_wifi_ap_runtime) {
                    config._zux_wifi_ap_store_reducer = runtime.wifi_ap_store_reducer.node();
                }

                inline for (0..configured_reducer_count) |i| {
                    const binding = context.reducer_bindings[i];
                    @field(config, binding.name) = runtime.configured_reducers[i].node();
                }
                config._zux_custom_pipeline_node = init_config.custom_pipeline_node orelse
                    runtime.custom_pipeline_bypass.node();
                config._zux_store_tick = runtime.store_tick.node();

                return config;
            }

            fn initSingleButtonInstances(init_config: InitConfig) SingleButtonInstances {
                var single_buttons: SingleButtonInstances = undefined;
                inline for (0..single_button_count) |i| {
                    const periph = single_button_registry.periphs[i];
                    if (comptime isVirtualPeriph(periph)) continue;
                    const label_name = comptime periphLabel(periph);
                    if (@hasField(SingleButtonInstances, label_name)) {
                        @field(single_buttons, label_name) = @field(init_config, label_name);
                    }
                }
                return single_buttons;
            }

            fn initBtInstances(init_config: InitConfig) BtInstances {
                var bts: BtInstances = undefined;
                inline for (0..bt_count) |i| {
                    const periph = bt_registry.periphs[i];
                    const label_name = comptime periphLabel(periph);
                    @field(bts, label_name) = @field(init_config, label_name);
                }
                return bts;
            }

            fn initAudioSystemInstances(init_config: InitConfig) AudioSystemInstances {
                var audio_systems: AudioSystemInstances = undefined;
                inline for (0..audio_system_count) |i| {
                    const periph = audio_system_registry.periphs[i];
                    const label_name = comptime periphLabel(periph);
                    @field(audio_systems, label_name) = @field(init_config, label_name);
                }
                return audio_systems;
            }

            fn initDisplayInstances(init_config: InitConfig) DisplayInstances {
                var displays: DisplayInstances = undefined;
                inline for (0..display_count) |i| {
                    const periph = display_registry.periphs[i];
                    const label_name = comptime periphLabel(periph);
                    @field(displays, label_name) = @field(init_config, label_name);
                }
                return displays;
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

            fn initSwitchInstances(init_config: InitConfig) SwitchInstances {
                var switches: SwitchInstances = undefined;
                inline for (0..switch_count) |i| {
                    const periph = switch_registry.periphs[i];
                    const label_name = comptime periphLabel(periph);
                    @field(switches, label_name) = @field(init_config, label_name);
                }
                return switches;
            }

            fn initPwmInstances(init_config: InitConfig) PwmInstances {
                var pwms: PwmInstances = undefined;
                inline for (0..pwm_count) |i| {
                    const periph = pwm_registry.periphs[i];
                    const label_name = comptime periphLabel(periph);
                    @field(pwms, label_name) = @field(init_config, label_name);
                }
                return pwms;
            }

            fn initTouchInstances(init_config: InitConfig) TouchInstances {
                var touches: TouchInstances = undefined;
                inline for (0..touch_count) |i| {
                    const periph = touch_registry.periphs[i];
                    const label_name = comptime periphLabel(periph);
                    @field(touches, label_name) = @field(init_config, label_name);
                }
                return touches;
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

            fn initStoreValues(allocator: glib.std.mem.Allocator, initial_state: InitialState) !StoreType.Stores {
                var stores_value: StoreType.Stores = undefined;
                var initialized_count: usize = 0;
                errdefer deinitStoreValuesPrefix(&stores_value, initialized_count);

                inline for (@typeInfo(StoreType.Stores).@"struct".fields) |field| {
                    @field(stores_value, field.name) = try initStoreValue(
                        field.type,
                        allocator,
                        @field(initial_state, field.name),
                    );
                    initialized_count += 1;
                }

                return stores_value;
            }

            fn initStoreValue(
                comptime StoreFieldType: type,
                allocator: glib.std.mem.Allocator,
                initial_state: StoreFieldType.StateType,
            ) !StoreFieldType {
                if (@hasDecl(StoreFieldType, "init")) {
                    const result = StoreFieldType.init(allocator, initial_state);
                    return switch (@typeInfo(@TypeOf(result))) {
                        .error_union => try result,
                        else => result,
                    };
                }
                return .{};
            }

            fn configureRuntimeStoreValues(stores_value: *StoreType.Stores, init_config: InitConfig) void {
                if (has_ledstrip_runtime) {
                    inline for (0..ledstrip_count) |i| {
                        const periph = ledstrip_registry.periphs[i];
                        const label_name = comptime periphLabel(periph);
                        const led_store = &@field(stores_value.*, label_name);
                        led_store.running.tick_interval = init_config.pipeline_config.tick_interval;
                        led_store.released.tick_interval = init_config.pipeline_config.tick_interval;
                    }
                }
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
            fn reduce(stores: *StoreType.Stores, message: Message, emit: Emitter) !void {
                switch (message.body) {
                    .button_gesture => |button_gesture| {
                        inline for (0..single_button_count) |i| {
                            const periph = single_button_registry.periphs[i];
                            if (button_gesture.source_id == periphIdForRecord(periph)) {
                                try button.Reducer.reduce(&@field(stores, periphLabel(periph)), message, emit);
                                try emit.emit(message);
                                return;
                            }
                        }
                        inline for (0..adc_count) |i| {
                            const periph = adc_registry.periphs[i];
                            if (button_gesture.source_id == periphIdForRecord(periph)) {
                                try button.Reducer.reduce(&@field(stores, periphLabel(periph)), message, emit);
                                try emit.emit(message);
                                return;
                            }
                        }
                        try emit.emit(message);
                        return;
                    },
                    else => {
                        if (message.body == .tick) return;
                        try emit.emit(message);
                        return;
                    },
                }
            }
        };

        const ImuStoreReducerFn = struct {
            fn reduce(stores: *StoreType.Stores, message: Message, emit: Emitter) !void {
                const source_id = switch (message.body) {
                    .raw_imu_accel => |raw_imu_accel| raw_imu_accel.source_id,
                    .raw_imu_gyro => |raw_imu_gyro| raw_imu_gyro.source_id,
                    .imu_motion => |imu_motion| imu_motion.source_id,
                    else => {
                        if (message.body == .tick) return;
                        try emit.emit(message);
                        return;
                    },
                };

                inline for (0..imu_count) |i| {
                    const periph = imu_registry.periphs[i];
                    if (source_id == periphIdForRecord(periph)) {
                        try component_imu.Reducer.reduce(
                            &@field(stores, periphLabel(periph)),
                            message,
                            emit,
                        );
                        return;
                    }
                }
                try emit.emit(message);
            }
        };

        const AudioSystemStoreReducerFn = struct {
            fn reduce(stores: *StoreType.Stores, message: Message, emit: Emitter) !void {
                switch (message.body) {
                    .audio_system_start, .audio_system_stop, .audio_system_set_gain, .audio_system_inc_gain, .audio_system_dec_gain, .audio_system_set_mic_gains => {
                        inline for (0..audio_system_count) |i| {
                            const periph = audio_system_registry.periphs[i];
                            if (messageSourceId(message) == periphIdForRecord(periph)) {
                                try component_audio_system.Reducer.reduce(&@field(stores, periphLabel(periph)), message, emit);
                                return;
                            }
                        }
                        try emit.emit(message);
                        return;
                    },
                    else => {
                        if (message.body == .tick) return;
                        try emit.emit(message);
                        return;
                    },
                }
            }
        };

        const DisplayStoreReducerFn = struct {
            fn reduce(stores: *StoreType.Stores, message: Message, emit: Emitter) !void {
                switch (message.body) {
                    .display_set => {
                        inline for (0..display_count) |i| {
                            const periph = display_registry.periphs[i];
                            if (messageSourceId(message) == periphIdForRecord(periph)) {
                                try component_display.Reducer.reduce(&@field(stores, periphLabel(periph)), message, emit);
                                return;
                            }
                        }
                        try emit.emit(message);
                        return;
                    },
                    else => {
                        if (message.body == .tick) return;
                        try emit.emit(message);
                        return;
                    },
                }
            }
        };

        const TouchStoreReducerFn = struct {
            fn reduce(stores: *StoreType.Stores, message: Message, emit: Emitter) !void {
                switch (message.body) {
                    .raw_touch => |raw_touch| {
                        inline for (0..touch_count) |i| {
                            const periph = touch_registry.periphs[i];
                            if (raw_touch.source_id == periphIdForRecord(periph)) {
                                try component_touch.Reducer.reduce(
                                    &@field(stores, periphLabel(periph)),
                                    message,
                                    emit,
                                );
                                try emit.emit(message);
                                return;
                            }
                        }
                        try emit.emit(message);
                        return;
                    },
                    else => {
                        if (message.body == .tick) return;
                        try emit.emit(message);
                        return;
                    },
                }
            }
        };

        const LedStripStoreReducerFn = struct {
            fn reduce(stores: *StoreType.Stores, message: Message, emit: Emitter) !void {
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
                                try LedStripReducerType.reduce(&@field(stores, periphLabel(periph)), message, emit);
                                return;
                            }
                        }
                        try emit.emit(message);
                        return;
                    },
                    .tick => {
                        inline for (0..ledstrip_count) |i| {
                            const periph = ledstrip_registry.periphs[i];
                            try LedStripReducerType.reduce(
                                &@field(stores, periphLabel(periph)),
                                message,
                                emit,
                            );
                        }
                        return;
                    },
                    else => {
                        if (message.body == .tick) return;
                        try emit.emit(message);
                        return;
                    },
                }
            }
        };

        const SwitchStoreReducerFn = struct {
            fn reduce(stores: *StoreType.Stores, message: Message, emit: Emitter) !void {
                switch (message.body) {
                    .switch_set => {
                        inline for (0..switch_count) |i| {
                            const periph = switch_registry.periphs[i];
                            if (messageSourceId(message) == periphIdForRecord(periph)) {
                                try component_switch.Reducer.reduceSwitch(&@field(stores, periphLabel(periph)), message, emit);
                                return;
                            }
                        }
                        try emit.emit(message);
                        return;
                    },
                    else => {
                        if (message.body == .tick) return;
                        try emit.emit(message);
                        return;
                    },
                }
            }
        };

        const PwmStoreReducerFn = struct {
            fn reduce(stores: *StoreType.Stores, message: Message, emit: Emitter) !void {
                switch (message.body) {
                    .pwm_set => {
                        inline for (0..pwm_count) |i| {
                            const periph = pwm_registry.periphs[i];
                            if (messageSourceId(message) == periphIdForRecord(periph)) {
                                try component_switch.Reducer.reducePwm(&@field(stores, periphLabel(periph)), message, emit);
                                return;
                            }
                        }
                        try emit.emit(message);
                        return;
                    },
                    else => {
                        if (message.body == .tick) return;
                        try emit.emit(message);
                        return;
                    },
                }
            }
        };

        runtime: *Runtime,
        started: context.grt.std.atomic.Value(bool) = context.grt.std.atomic.Value(bool).init(false),
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
            if (self.started.load(.acquire)) {
                self.stop() catch {};
            }
            Runtime.deinit(self.runtime);
            self.last_event = null;
        }

        pub fn start(self: *Self, start_config: StartConfig) !void {
            if (self.started.load(.acquire) or self.closed) return error.InvalidState;

            switch (start_config.ticker) {
                .manual => {
                    self.manual_ticker = true;
                    self.started.store(true, .release);
                    return;
                },
                .automatic => {},
            }

            try self.runtime.pipeline.start();
            errdefer {
                self.runtime.pipeline.stop();
                self.runtime.pipeline.wait();
            }

            inline for (0..runtime_poller_count) |i| {
                self.runtime.pollers[i].start(self.runtime.poller_config) catch |err| {
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
            if (has_wifi_sta_runtime) {
                inline for (0..wifi_sta_count) |i| {
                    const periph = wifi_sta_registry.periphs[i];
                    const label_name = comptime periphLabel(periph);
                    self.runtime.wifi_sta_event_hooks[i].attachSta(periph.id, @field(self.runtime.wifi_stas, label_name));
                }
            }
            self.started.store(true, .release);
        }

        pub fn stop(self: *Self) !void {
            if (!self.started.load(.acquire)) return error.InvalidState;

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
                if (has_wifi_sta_runtime) {
                    inline for (0..wifi_sta_count) |i| {
                        const periph = wifi_sta_registry.periphs[i];
                        const label_name = comptime periphLabel(periph);
                        self.runtime.wifi_sta_event_hooks[i].detachSta(@field(self.runtime.wifi_stas, label_name));
                    }
                }
                inline for (&self.runtime.pollers) |*poller| {
                    poller.stop();
                }
                self.runtime.pipeline.stop();
                self.runtime.pipeline.wait();
            }

            self.runtime.commitStores();
            self.started.store(false, .release);
            self.manual_ticker = false;
            self.closed = true;
        }

        pub fn dispatch(self: *Self, message: Message) !void {
            if (!self.started.load(.acquire)) {
                message.deinit();
                return error.NotStarted;
            }

            if (message.body == .custom) {
                self.last_event = null;
            } else {
                self.last_event = message.body;
            }
            if (self.manual_ticker) {
                defer message.deinit();
                try self.runtime.root.process(message);
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

        pub fn touch_down(self: *Self, label: PeriphLabel, point: drivers.Touch.Point) !void {
            if (comptime periph_ids.len == 0) return error.InvalidPeriphKind;
            if (dispatchKind(label) != .touch) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .raw_touch = .{
                    .source_id = periphId(label),
                    .pressed = true,
                    .point_count = 1,
                    .id = point.id,
                    .x = point.x,
                    .y = point.y,
                    .pressure = point.pressure,
                },
            });
        }

        pub fn touch_move(self: *Self, label: PeriphLabel, point: drivers.Touch.Point) !void {
            try self.touch_down(label, point);
        }

        pub fn touch_up(self: *Self, label: PeriphLabel) !void {
            if (comptime periph_ids.len == 0) return error.InvalidPeriphKind;
            if (dispatchKind(label) != .touch) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .raw_touch = .{
                    .source_id = periphId(label),
                    .pressed = false,
                    .point_count = 0,
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

        pub fn flush_led_strip_pixels(self: *Self, label: PeriphLabel, frame: FrameType, brightness: u8) !void {
            if (comptime periph_ids.len == 0) return error.InvalidPeriphKind;
            if (dispatchKind(label) != .led_strip) return error.InvalidPeriphKind;
            const output = frame.withBrightness(brightness);
            inline for (0..ledstrip_count) |i| {
                const periph = ledstrip_registry.periphs[i];
                if (label == @field(PeriphLabel, periphLabel(periph))) {
                    const strip = @field(self.runtime.led_strips, periphLabel(periph));
                    strip.setPixels(0, output.pixels[0..]);
                    strip.refresh();
                    return;
                }
            }
            return error.InvalidPeriphKind;
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
            duration: glib.time.duration.Duration,
            interval: glib.time.duration.Duration,
        ) !void {
            if (comptime periph_ids.len == 0) return error.InvalidPeriphKind;
            if (dispatchKind(label) != .led_strip) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .ledstrip_flash = .{
                    .source_id = periphId(label),
                    .pixels = frame.pixels[0..],
                    .brightness = brightness,
                    .duration = duration,
                    .interval = interval,
                },
            });
        }

        pub fn set_led_strip_pingpong(
            self: *Self,
            label: PeriphLabel,
            from_frame: FrameType,
            to_frame: FrameType,
            brightness: u8,
            duration: glib.time.duration.Duration,
            interval: glib.time.duration.Duration,
        ) !void {
            if (comptime periph_ids.len == 0) return error.InvalidPeriphKind;
            if (dispatchKind(label) != .led_strip) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .ledstrip_pingpong = .{
                    .source_id = periphId(label),
                    .from_pixels = from_frame.pixels[0..],
                    .to_pixels = to_frame.pixels[0..],
                    .brightness = brightness,
                    .duration = duration,
                    .interval = interval,
                },
            });
        }

        pub fn set_led_strip_rotate(
            self: *Self,
            label: PeriphLabel,
            frame: FrameType,
            brightness: u8,
            duration: glib.time.duration.Duration,
            interval: glib.time.duration.Duration,
        ) !void {
            if (comptime periph_ids.len == 0) return error.InvalidPeriphKind;
            if (dispatchKind(label) != .led_strip) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .ledstrip_rotate = .{
                    .source_id = periphId(label),
                    .pixels = frame.pixels[0..],
                    .brightness = brightness,
                    .duration = duration,
                    .interval = interval,
                },
            });
        }

        pub fn set_switch(self: *Self, label: PeriphLabel, enabled: bool) !void {
            if (comptime periph_ids.len == 0) return error.InvalidPeriphKind;
            if (dispatchKind(label) != .switch_output) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .switch_set = .{
                    .source_id = periphId(label),
                    .enabled = enabled,
                },
            });
        }

        pub fn set_pwm(self: *Self, label: PeriphLabel, enabled: bool, frequency_hz: u32, duty: drivers.Pwm.Duty) !void {
            if (comptime periph_ids.len == 0) return error.InvalidPeriphKind;
            if (dispatchKind(label) != .pwm) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .pwm_set = .{
                    .source_id = periphId(label),
                    .enabled = enabled,
                    .frequency_hz = frequency_hz,
                    .duty = duty,
                },
            });
        }

        pub fn set_audio_system(self: *Self, label: PeriphLabel, state: component_audio_system.State) !void {
            if (comptime periph_ids.len == 0) return error.InvalidPeriphKind;
            if (dispatchKind(label) != .audio_system) return error.InvalidPeriphKind;
            const source_id = periphId(label);
            if (state.started) {
                try self.emitBody(.{
                    .audio_system_start = .{
                        .source_id = source_id,
                    },
                });
            } else {
                try self.emitBody(.{
                    .audio_system_stop = .{
                        .source_id = source_id,
                    },
                });
            }
            try self.emitBody(.{
                .audio_system_set_gain = .{
                    .source_id = source_id,
                    .gain_db = state.gain_db,
                },
            });
            if (state.mic_gain_count != 0) {
                try self.emitBody(.{
                    .audio_system_set_mic_gains = .{
                        .source_id = source_id,
                        .mic_gain_count = state.mic_gain_count,
                        .mic_gains = state.mic_gains,
                    },
                });
            }
        }

        pub fn set_display(self: *Self, label: PeriphLabel, state: component_display.State) !void {
            if (comptime periph_ids.len == 0) return error.InvalidPeriphKind;
            if (dispatchKind(label) != .display) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .display_set = .{
                    .source_id = periphId(label),
                    .enabled = state.enabled,
                    .brightness = state.brightness,
                },
            });
        }

        pub fn connect_wifi_sta(self: *Self, label: PeriphLabel, config: drivers.wifi.Sta.ConnectConfig) !void {
            if (comptime periph_ids.len == 0) return error.InvalidPeriphKind;
            if (dispatchKind(label) != .wifi_sta) return error.InvalidPeriphKind;
            inline for (0..wifi_sta_count) |i| {
                const periph = wifi_sta_registry.periphs[i];
                if (label == @field(PeriphLabel, periphLabel(periph))) {
                    const sta = @field(self.runtime.wifi_stas, periphLabel(periph));
                    try sta.connect(config);
                    try self.wifi_sta_connected(label, .{
                        .ssid = config.ssid,
                    });
                    if (sta.getIpInfo()) |ip_info| {
                        try self.wifi_sta_got_ip(label, ip_info);
                    }
                    return;
                }
            }
            return error.InvalidPeriphKind;
        }

        pub fn disconnect_wifi_sta(self: *Self, label: PeriphLabel) !void {
            if (comptime periph_ids.len == 0) return error.InvalidPeriphKind;
            if (dispatchKind(label) != .wifi_sta) return error.InvalidPeriphKind;
            inline for (0..wifi_sta_count) |i| {
                const periph = wifi_sta_registry.periphs[i];
                if (label == @field(PeriphLabel, periphLabel(periph))) {
                    const sta = @field(self.runtime.wifi_stas, periphLabel(periph));
                    sta.disconnect();
                    try self.wifi_sta_lost_ip(label);
                    try self.wifi_sta_disconnected(label, .{});
                    return;
                }
            }
            return error.InvalidPeriphKind;
        }

        pub fn nfc_found(self: *Self, label: PeriphLabel, uid: []const u8, card_type: drivers.nfc.CardType) !void {
            if (dispatchKind(label) != .nfc) return error.InvalidPeriphKind;
            try self.emitBody(try component_nfc.event.make(Message.Event, .{
                .source_id = periphId(label),
                .uid = uid,
                .payload = null,
                .card_type = card_type,
            }));
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
            }));
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

        pub fn store(self: *Self) *StoreType {
            return &self.runtime.store;
        }

        pub fn audioSystem(self: *Self, comptime label: PeriphLabel) audioSystemType(label) {
            inline for (0..audio_system_count) |i| {
                const audio_system_record = audio_system_registry.periphs[i];
                if (label == @field(PeriphLabel, periphLabel(audio_system_record))) {
                    return @field(self.runtime.audio_systems, periphLabel(audio_system_record));
                }
            }
            @panic("zux app has no audio system for label");
        }

        pub fn btHost(self: *Self, comptime label: PeriphLabel) bt.Host {
            inline for (0..bt_count) |i| {
                const bt_record = bt_registry.periphs[i];
                if (label == @field(PeriphLabel, periphLabel(bt_record))) {
                    return @field(self.runtime.bts, periphLabel(bt_record));
                }
            }
            @panic("zux app has no bt host for label");
        }

        pub fn display(self: *Self, label: PeriphLabel) drivers.Display {
            inline for (0..display_count) |i| {
                const display_record = display_registry.periphs[i];
                if (label == @field(PeriphLabel, periphLabel(display_record))) {
                    return @field(self.runtime.displays, periphLabel(display_record));
                }
            }
            @panic("zux app has no display for label");
        }

        pub fn outputSwitch(self: *Self, label: PeriphLabel) drivers.Switch {
            inline for (0..switch_count) |i| {
                const switch_record = switch_registry.periphs[i];
                if (label == @field(PeriphLabel, periphLabel(switch_record))) {
                    return @field(self.runtime.switches, periphLabel(switch_record));
                }
            }
            @panic("zux app has no switch for label");
        }

        pub fn pwm(self: *Self, label: PeriphLabel) drivers.Pwm {
            inline for (0..pwm_count) |i| {
                const pwm_record = pwm_registry.periphs[i];
                if (label == @field(PeriphLabel, periphLabel(pwm_record))) {
                    return @field(self.runtime.pwms, periphLabel(pwm_record));
                }
            }
            @panic("zux app has no pwm for label");
        }

        pub fn touch(self: *Self, label: PeriphLabel) drivers.Touch {
            inline for (0..touch_count) |i| {
                const touch_record = touch_registry.periphs[i];
                if (label == @field(PeriphLabel, periphLabel(touch_record))) {
                    return @field(self.runtime.touches, periphLabel(touch_record));
                }
            }
            @panic("zux app has no touch for label");
        }

        fn emitBody(self: *Self, body: Message.Event) !void {
            try self.dispatch(.{
                .origin = .manual,
                .timestamp = Lib.time.instant.now(),
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

        fn audioSystemType(comptime label: PeriphLabel) type {
            inline for (0..audio_system_count) |i| {
                const audio_system_record = audio_system_registry.periphs[i];
                if (label == @field(PeriphLabel, periphLabel(audio_system_record))) {
                    return @field(context.build_config, periphLabel(audio_system_record));
                }
            }
            @compileError("zux app has no audio system for label '" ++ @tagName(label) ++ "'");
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

    inline for (0..registryPeriphLen(context.registries.single_button)) |i| {
        const periph = context.registries.single_button.periphs[i];
        builder.setStore(periph.label, store.Object.make(context.grt, button.state.Detected, periph.label));
    }
    inline for (0..registryPeriphLen(context.registries.audio_system)) |i| {
        const periph = context.registries.audio_system.periphs[i];
        builder.setStore(periph.label, store.Object.make(context.grt, component_audio_system.State, periph.label));
    }
    inline for (0..registryPeriphLen(context.registries.display)) |i| {
        const periph = context.registries.display.periphs[i];
        builder.setStore(periph.label, store.Object.make(context.grt, component_display.State, periph.label));
    }
    inline for (0..registryPeriphLen(context.registries.adc_button)) |i| {
        const periph = context.registries.adc_button.periphs[i];
        builder.setStore(periph.label, store.Object.make(context.grt, button.state.Detected, periph.label));
    }
    inline for (0..registryPeriphLen(context.registries.imu)) |i| {
        const periph = context.registries.imu.periphs[i];
        builder.setStore(periph.label, store.Object.make(context.grt, component_imu.State, periph.label));
    }
    inline for (0..ledstrip_count) |i| {
        const periph = ledstrip_registry.periphs[i];
        builder.setStore(periph.label, store.Object.make(context.grt, LedStripStateType, periph.label));
    }
    inline for (0..registryPeriphLen(context.registries.modem)) |i| {
        const periph = context.registries.modem.periphs[i];
        builder.setStore(periph.label, store.Object.make(context.grt, component_modem.State, periph.label));
    }
    inline for (0..registryPeriphLen(context.registries.nfc)) |i| {
        const periph = context.registries.nfc.periphs[i];
        builder.setStore(periph.label, store.Object.make(context.grt, component_nfc.State, periph.label));
    }
    inline for (0..registryPeriphLen(context.registries.switch_output)) |i| {
        const periph = context.registries.switch_output.periphs[i];
        builder.setStore(periph.label, store.Object.make(context.grt, component_switch.state.Switch, periph.label));
    }
    inline for (0..registryPeriphLen(context.registries.pwm)) |i| {
        const periph = context.registries.pwm.periphs[i];
        builder.setStore(periph.label, store.Object.make(context.grt, component_switch.state.Pwm, periph.label));
    }
    inline for (0..registryPeriphLen(context.registries.touch)) |i| {
        const periph = context.registries.touch.periphs[i];
        builder.setStore(periph.label, store.Object.make(context.grt, component_touch.State, periph.label));
    }
    inline for (0..registryPeriphLen(context.registries.wifi_sta)) |i| {
        const periph = context.registries.wifi_sta.periphs[i];
        builder.setStore(periph.label, store.Object.make(context.grt, component_wifi.state.Sta, periph.label));
    }
    inline for (0..registryPeriphLen(context.registries.wifi_ap)) |i| {
        const periph = context.registries.wifi_ap.periphs[i];
        builder.setStore(periph.label, store.Object.make(context.grt, component_wifi.state.Ap, periph.label));
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

fn makeRuntimeNodeBuilder(comptime context: anytype) NodeBuilder.Builder(context.assembler_config.node) {
    const NodeBuilderType = NodeBuilder.Builder(context.assembler_config.node);
    var builder = NodeBuilderType.init();

    builder.addNode(._zux_custom_pipeline_node);

    if (registryPeriphLen(context.registries.single_button) + registryPeriphLen(context.registries.adc_button) > 0) {
        builder.addNode(._zux_button_detector);
        builder.addNode(._zux_button_store_reducer);
    }
    if (registryPeriphLen(context.registries.display) > 0) {
        builder.addNode(._zux_display_store_reducer);
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
    if (registryPeriphLen(context.registries.switch_output) > 0) {
        builder.addNode(._zux_switch_store_reducer);
    }
    if (registryPeriphLen(context.registries.pwm) > 0) {
        builder.addNode(._zux_pwm_store_reducer);
    }
    if (registryPeriphLen(context.registries.touch) > 0) {
        builder.addNode(._zux_touch_store_reducer);
    }
    if (registryPeriphLen(context.registries.wifi_sta) > 0) {
        builder.addNode(._zux_wifi_sta_store_reducer);
    }
    if (registryPeriphLen(context.registries.wifi_ap) > 0) {
        builder.addNode(._zux_wifi_ap_store_reducer);
    }

    inline for (0..context.reducer_count) |i| {
        const binding = context.reducer_bindings[i];
        builder.addNode(binding.label);
    }

    if (registryPeriphLen(context.registries.audio_system) > 0) {
        builder.addNode(._zux_audio_system_store_reducer);
    }

    builder.addNode(._zux_store_tick);

    return builder;
}

fn makePeriphInstancesType(comptime build_config_value: anytype, comptime registry: anytype) type {
    const count = registryBuildConfigPeriphLen(registry);
    var fields: [count]glib.std.builtin.Type.StructField = undefined;
    comptime var field_index: usize = 0;

    inline for (0..registryPeriphLen(registry)) |i| {
        const periph = registry.periphs[i];
        if (!periphRequiresBuildConfig(periph)) continue;
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

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

fn makeRuntimeReducerHook(comptime StoreType: type) type {
    return struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        const RuntimeReducerHook = @This();

        pub const VTable = struct {
            reduce: *const fn (
                ptr: *anyopaque,
                stores: *StoreType.Stores,
                message: Message,
                emit: Emitter,
            ) anyerror!void,
        };

        pub fn init(pointer: anytype) RuntimeReducerHook {
            const Ptr = @TypeOf(pointer);
            const info = @typeInfo(Ptr);
            if (info != .pointer or info.pointer.size != .one) {
                @compileError("zux.RuntimeReducerHook.init expects a single-item pointer");
            }

            const Impl = info.pointer.child;
            const gen = struct {
                fn reduceFn(
                    ptr: *anyopaque,
                    stores: *StoreType.Stores,
                    message: Message,
                    emit: Emitter,
                ) !void {
                    const impl: *Impl = @ptrCast(@alignCast(ptr));
                    try impl.reduce(stores, message, emit);
                }

                const vtable = VTable{
                    .reduce = reduceFn,
                };
            };

            return .{
                .ptr = pointer,
                .vtable = &gen.vtable,
            };
        }

        pub fn reduce(
            self: RuntimeReducerHook,
            stores: *StoreType.Stores,
            message: Message,
            emit: Emitter,
        ) !void {
            try self.vtable.reduce(self.ptr, stores, message, emit);
        }
    };
}

fn makeRuntimeRenderHook(comptime AppType: type) type {
    return struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        const RuntimeRenderHook = @This();

        pub const VTable = struct {
            render: *const fn (ptr: *anyopaque, app: *AppType) anyerror!void,
        };

        pub fn init(pointer: anytype) RuntimeRenderHook {
            const Ptr = @TypeOf(pointer);
            const info = @typeInfo(Ptr);
            if (info != .pointer or info.pointer.size != .one) {
                @compileError("zux.RuntimeRenderHook.init expects a single-item pointer");
            }

            const Impl = info.pointer.child;
            const gen = struct {
                fn renderFn(ptr: *anyopaque, app: *AppType) !void {
                    const impl: *Impl = @ptrCast(@alignCast(ptr));
                    if (@hasDecl(Impl, "render")) {
                        try impl.render(app);
                    } else if (@hasDecl(Impl, "sync")) {
                        try impl.sync(app);
                    } else {
                        @compileError("zux.RuntimeRenderHook.init expects an implementation with render(app) or sync(app)");
                    }
                }

                const vtable = VTable{
                    .render = renderFn,
                };
            };

            return .{
                .ptr = pointer,
                .vtable = &gen.vtable,
            };
        }

        pub fn initFn(pointer: anytype, comptime render_fn_name: []const u8) RuntimeRenderHook {
            const Ptr = @TypeOf(pointer);
            const info = @typeInfo(Ptr);
            if (info != .pointer or info.pointer.size != .one) {
                @compileError("zux.RuntimeRenderHook.initFn expects a single-item pointer");
            }

            const Impl = info.pointer.child;
            if (!@hasDecl(Impl, render_fn_name)) {
                @compileError("zux.RuntimeRenderHook.initFn expects an implementation with " ++ render_fn_name ++ "(app)");
            }

            const gen = struct {
                fn renderFn(ptr: *anyopaque, app: *AppType) !void {
                    const impl: *Impl = @ptrCast(@alignCast(ptr));
                    try @field(Impl, render_fn_name)(impl, app);
                }

                const vtable = VTable{
                    .render = renderFn,
                };
            };

            return .{
                .ptr = pointer,
                .vtable = &gen.vtable,
            };
        }

        pub fn render(self: RuntimeRenderHook, app: *AppType) !void {
            try self.vtable.render(self.ptr, app);
        }
    };
}

fn makeInitConfigType(
    comptime grt: type,
    comptime InitialState: type,
    comptime build_config_value: anytype,
    comptime registries: anytype,
    comptime RuntimeReducerHook: type,
    comptime RuntimeRenderHook: type,
    comptime reducer_bindings: anytype,
    comptime reducer_count: usize,
    comptime render_bindings: anytype,
    comptime render_count: usize,
) type {
    const PipelineConfig = Pipeline.Config(grt);
    const default_pipeline_config: PipelineConfig = .{};
    const default_poller_config: Poller.Config = .{};
    const total_fields = 5 + totalBuildConfigPeriphLen(registries) + reducer_count + render_count;
    const default_custom_pipeline_node: ?Node = null;
    const default_reducer_hook: ?RuntimeReducerHook = null;
    const default_render_hook: ?RuntimeRenderHook = null;
    var fields: [total_fields]glib.std.builtin.Type.StructField = undefined;
    comptime var field_index: usize = 0;

    ensureUniqueInitConfigField(fields, field_index, "allocator");
    fields[field_index] = .{
        .name = "allocator",
        .type = glib.std.mem.Allocator,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(glib.std.mem.Allocator),
    };
    field_index += 1;

    ensureUniqueInitConfigField(fields, field_index, "initial_state");
    fields[field_index] = .{
        .name = "initial_state",
        .type = InitialState,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(InitialState),
    };
    field_index += 1;

    ensureUniqueInitConfigField(fields, field_index, "pipeline_config");
    fields[field_index] = .{
        .name = "pipeline_config",
        .type = PipelineConfig,
        .default_value_ptr = @ptrCast(&default_pipeline_config),
        .is_comptime = false,
        .alignment = @alignOf(PipelineConfig),
    };
    field_index += 1;

    ensureUniqueInitConfigField(fields, field_index, "poller_config");
    fields[field_index] = .{
        .name = "poller_config",
        .type = Poller.Config,
        .default_value_ptr = @ptrCast(&default_poller_config),
        .is_comptime = false,
        .alignment = @alignOf(Poller.Config),
    };
    field_index += 1;

    ensureUniqueInitConfigField(fields, field_index, "custom_pipeline_node");
    fields[field_index] = .{
        .name = "custom_pipeline_node",
        .type = ?Node,
        .default_value_ptr = @ptrCast(&default_custom_pipeline_node),
        .is_comptime = false,
        .alignment = @alignOf(?Node),
    };
    field_index += 1;

    inline for (configStructInfo(registries).fields) |field| {
        const registry = @field(registries, field.name);
        inline for (0..registryPeriphLen(registry)) |i| {
            const periph = registry.periphs[i];
            if (!periphRequiresBuildConfig(periph)) continue;
            const label_name = periphLabel(periph);
            ensureUniqueInitConfigField(fields, field_index, label_name);
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

    inline for (0..reducer_count) |i| {
        const binding = reducer_bindings[i];
        ensureUniqueInitConfigField(fields, field_index, binding.name);
        fields[field_index] = .{
            .name = sentinelName(binding.name),
            .type = ?RuntimeReducerHook,
            .default_value_ptr = @ptrCast(&default_reducer_hook),
            .is_comptime = false,
            .alignment = @alignOf(?RuntimeReducerHook),
        };
        field_index += 1;
    }

    inline for (0..render_count) |i| {
        const binding = render_bindings[i];
        ensureUniqueInitConfigField(fields, field_index, binding.name);
        fields[field_index] = .{
            .name = sentinelName(binding.name),
            .type = ?RuntimeRenderHook,
            .default_value_ptr = @ptrCast(&default_render_hook),
            .is_comptime = false,
            .alignment = @alignOf(?RuntimeRenderHook),
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

fn ensureUniqueInitConfigField(
    comptime fields: anytype,
    comptime field_count: usize,
    comptime field_name: []const u8,
) void {
    if (hasInitConfigField(fields, field_count, field_name)) {
        @compileError("zux.assembler.Builder.build found duplicate InitConfig field '" ++ field_name ++ "'");
    }
}

fn hasInitConfigField(
    comptime fields: anytype,
    comptime field_count: usize,
    comptime field_name: []const u8,
) bool {
    inline for (0..field_count) |i| {
        if (comptimeEql(fields[i].name, field_name)) {
            return true;
        }
    }
    return false;
}

fn makeInitialStateType(comptime Stores: type) type {
    const store_fields = @typeInfo(Stores).@"struct".fields;
    var fields: [store_fields.len]glib.std.builtin.Type.StructField = undefined;

    inline for (store_fields, 0..) |field, i| {
        const StateType = field.type.StateType;
        fields[i] = .{
            .name = sentinelName(field.name),
            .type = StateType,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(StateType),
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

fn configStructInfo(comptime config: anytype) glib.std.builtin.Type.Struct {
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

fn totalPollerCount(comptime build_config_value: anytype, comptime registries: anytype) usize {
    return buttonPollerCount(build_config_value, registries) +
        countRegistryControlType(build_config_value, registries.touch, drivers.Touch) +
        registryPeriphLen(registries.imu);
}

fn buttonPollerCount(comptime build_config_value: anytype, comptime registries: anytype) usize {
    return countRegistryControlType(
        build_config_value,
        registries.single_button,
        drivers.button.Single,
    ) + countRegistryControlType(
        build_config_value,
        registries.adc_button,
        drivers.button.Grouped,
    );
}

fn countRegistryControlType(
    comptime build_config_value: anytype,
    comptime registry: anytype,
    comptime ControlType: type,
) usize {
    return countRegistryControlTypeBefore(
        build_config_value,
        registry,
        registryPeriphLen(registry),
        ControlType,
    );
}

fn countRegistryControlTypeBefore(
    comptime build_config_value: anytype,
    comptime registry: anytype,
    comptime end_index: usize,
    comptime ControlType: type,
) usize {
    comptime var count: usize = 0;
    inline for (0..end_index) |i| {
        const periph = registry.periphs[i];
        if (comptime !periphRequiresBuildConfig(periph)) continue;
        if (comptime @field(build_config_value, periphLabel(periph)) == ControlType) {
            count += 1;
        }
    }
    return count;
}

fn validateRegistryControlTypes(
    comptime build_config_value: anytype,
    comptime registry: anytype,
    comptime allowed_types: anytype,
    comptime component_name: []const u8,
) void {
    inline for (0..registryPeriphLen(registry)) |i| {
        const periph = registry.periphs[i];
        if (!periphRequiresBuildConfig(periph)) continue;
        const FieldType = @field(build_config_value, periphLabel(periph));
        comptime var valid = false;
        inline for (allowed_types) |AllowedType| {
            if (FieldType == AllowedType) valid = true;
        }
        if (!valid) {
            @compileError("zux.assembler.Builder.build " ++ component_name ++ " has unsupported build_config control type");
        }
    }
}

fn registryBuildConfigPeriphLen(comptime registry: anytype) usize {
    comptime var count: usize = 0;
    inline for (0..registryPeriphLen(registry)) |i| {
        if (periphRequiresBuildConfig(registry.periphs[i])) count += 1;
    }
    return count;
}

fn totalBuildConfigPeriphLen(comptime registries: anytype) usize {
    const info = configStructInfo(registries);
    comptime var count: usize = 0;
    inline for (info.fields) |field| {
        count += registryBuildConfigPeriphLen(@field(registries, field.name));
    }
    return count;
}

fn periphRequiresBuildConfig(comptime periph: anytype) bool {
    const PeriphType = @TypeOf(periph);
    if (@hasField(PeriphType, "input_type") and @field(periph, "input_type") == .virtual) {
        return false;
    }
    return true;
}

fn isVirtualPeriph(comptime periph: anytype) bool {
    return !periphRequiresBuildConfig(periph);
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
    var fields: [total_len]glib.std.builtin.Type.EnumField = undefined;
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
    var fields: [total_len]glib.std.builtin.Type.EnumField = undefined;

    inline for (0..total_len) |i| {
        const record = registry.periphs[i];
        const name = periphLabel(record);

        inline for (0..i) |existing_idx| {
            if (comptimeEql(fields[existing_idx].name, name)) {
                @compileError("zux.assembler.Builder.build found duplicate labels");
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
    audio_system,
    bt,
    display,
    single_button,
    grouped_button,
    imu,
    led_strip,
    modem,
    nfc,
    switch_output,
    pwm,
    touch,
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
    if (ControlType == type) return .audio_system;
    if (ControlType == bt.Host) return .bt;
    if (ControlType == @import("drivers").Display) return .display;
    if (ControlType == @import("drivers").button.Single) return .single_button;
    if (ControlType == @import("drivers").button.Grouped) return .grouped_button;
    if (ControlType == @import("drivers").imu) return .imu;
    if (ControlType == ledstrip.LedStrip) return .led_strip;
    if (ControlType == modem_api.Modem) return .modem;
    if (ControlType == @import("drivers").nfc.Reader) return .nfc;
    if (ControlType == @import("drivers").Switch) return .switch_output;
    if (ControlType == @import("drivers").Pwm) return .pwm;
    if (ControlType == @import("drivers").Touch) return .touch;
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
        .audio_system_start => |event| event.source_id,
        .audio_system_stop => |event| event.source_id,
        .audio_system_set_gain => |event| event.source_id,
        .audio_system_inc_gain => |event| event.source_id,
        .audio_system_dec_gain => |event| event.source_id,
        .audio_system_set_mic_gains => |event| event.source_id,
        .display_set => |event| event.source_id,
        .switch_set => |event| event.source_id,
        .pwm_set => |event| event.source_id,
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
        .raw_touch => |event| event.source_id,
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

fn storePathLabel(comptime path: []const u8) ?[]const u8 {
    const prefix = "$store/";
    if (path.len <= prefix.len) return null;
    inline for (prefix, 0..) |ch, idx| {
        if (path[idx] != ch) return null;
    }
    const label = path[prefix.len..];
    inline for (label) |ch| {
        if (ch == '/') {
            @compileError("zux render $store paths must be exactly $store/{store_label}");
        }
        if (ch == '.') {
            @compileError("zux render $store labels must not contain dots");
        }
    }
    return label;
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

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const TestCase = struct {
                fn init_config_field_lookup_detects_user_label_duplicates() !void {
                    const StructField = glib.std.builtin.Type.StructField;
                    const fields = comptime blk: {
                        var out: [3]StructField = undefined;
                        out[0] = testStructField("allocator", glib.std.mem.Allocator);
                        out[1] = testStructField("button", u8);
                        out[2] = testStructField("strip", u16);
                        break :blk out;
                    };

                    try grt.std.testing.expect(comptime hasInitConfigField(fields, 3, "button"));
                    try grt.std.testing.expect(comptime hasInitConfigField(fields, 3, "strip"));
                    try grt.std.testing.expect(!(comptime hasInitConfigField(fields, 3, "scene_render")));
                }

                fn testStructField(comptime name: []const u8, comptime FieldType: type) glib.std.builtin.Type.StructField {
                    return .{
                        .name = sentinelName(name),
                        .type = FieldType,
                        .default_value_ptr = null,
                        .is_comptime = false,
                        .alignment = @alignOf(FieldType),
                    };
                }
            };

            TestCase.init_config_field_lookup_detects_user_label_duplicates() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };

            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
