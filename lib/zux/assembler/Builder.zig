const embed = @import("embed");
const builtin = embed.builtin;
const App = @import("../App.zig");
const button = @import("../component/button.zig");
const ledstrip_component = @import("../component/ledstrip.zig");
const Emitter = @import("../pipeline/Emitter.zig");
const Message = @import("../pipeline/Message.zig");
const Node = @import("../pipeline/Node.zig");
const Poller = @import("../pipeline/Poller.zig");
const Pipeline = @import("../pipeline/Pipeline.zig");
const store = @import("../store.zig");
const build_config = @import("BuildConfig.zig");
const ledstrip = @import("ledstrip");

const root = @This();

pub fn init() root {
    return .{};
}

pub fn build(builder: root, comptime context: anytype) type {
    _ = builder;

    const GeneratedBuildConfig = build_config.make(context.registries);
    comptime {
        if (@TypeOf(context.build_config) != GeneratedBuildConfig) {
            @compileError("zux.assembler.Builder.build BuildContext.build_config does not match generated BuildConfig");
        }
    }

    const adc_registry = context.registries.adc_button;
    const gpio_registry = context.registries.gpio_button;
    const ledstrip_registry = context.registries.ledstrip;
    const adc_count = registryPeriphLen(adc_registry);
    const gpio_count = registryPeriphLen(gpio_registry);
    const ledstrip_count = registryPeriphLen(ledstrip_registry);
    const has_button_runtime = (adc_count + gpio_count) > 0;
    const has_ledstrip_runtime = ledstrip_count > 0;
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
    const LedStripInstances = makePeriphInstancesType(context.build_config, ledstrip_registry);
    const GeneratedInitConfig = makeInitConfigType(
        context.lib,
        context.build_config,
        context.registries,
        has_user_root_config,
        if (has_user_root_config) UserRoot.Config else void,
    );

    const AppLabel = makeLabelEnum(context.registries);
    const periph_ids = makePeriphIdTable(context.registries);
    const periph_kinds = makePeriphKindTable(context.registries);
    const runtime_poller_config: Poller.Config = context.assembler_config.poller;

    const SingleButtonPoller = button.SinglePoller.make(context.lib);
    const GroupedButtonPoller = button.GroupedPoller.make(context.lib);
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

    const Impl = struct {
        const Self = @This();

        pub const Lib = context.lib;
        pub const Config = context.assembler_config;
        pub const BuildConfig = @TypeOf(context.build_config);
        pub const build_config = context.build_config;
        pub const pipeline_config = runtime_pipeline_config;
        pub const InitConfig = GeneratedInitConfig;
        pub const Store = StoreType;
        pub const Root = BuiltRoot;
        pub const Label = AppLabel;
        pub const PeriphLabel = AppLabel;
        pub const poller_count: usize = runtime_poller_count;
        pub const pixel_count: usize = ledstrip_pixel_count;
        pub const FrameType = ledstrip.Frame.make(pixel_count);

        const Runtime = struct {
            allocator: Lib.mem.Allocator,
            store: StoreType,
            single_buttons: SingleButtonInstances,
            grouped_buttons: GroupedButtonInstances,
            led_strips: LedStripInstances,
            detector: if (has_button_runtime) button.Reducer else void,
            store_reducer: if (has_button_runtime) StoreReducerType else void,
            ledstrip_store_reducer: if (has_ledstrip_runtime) StoreReducerType else void,
            store_tick: StoreTickNode,
            root_config: BuiltRoot.Config,
            root: Node,
            pipeline: BuiltPipeline,
            pipeline_sink: PipelineSink,
            single_button_pollers: [gpio_count]SingleButtonPoller = undefined,
            grouped_button_pollers: [adc_count]GroupedButtonPoller = undefined,
            pollers: [runtime_poller_count]Poller = undefined,

            pub fn init(init_config: InitConfig) !*Runtime {
                const runtime = try init_config.allocator.create(Runtime);
                errdefer init_config.allocator.destroy(runtime);

                runtime.allocator = init_config.allocator;
                runtime.single_buttons = initSingleButtonInstances(init_config);
                runtime.grouped_buttons = initGroupedButtonInstances(init_config);
                runtime.led_strips = initLedStripInstances(init_config);

                const stores = try initStoreValues(init_config.allocator);
                runtime.store = try StoreType.init(init_config.allocator, stores);
                errdefer {
                    runtime.store.deinit();
                    deinitStoreValues(&runtime.store.stores);
                }

                if (has_button_runtime) {
                    runtime.detector = button.Reducer.init(init_config.allocator);
                    errdefer runtime.detector.deinit();

                    runtime.store_reducer = StoreReducerType.init(
                        &runtime.store.stores,
                        ButtonStoreReducerFn.reduce,
                    );
                }
                if (has_ledstrip_runtime) {
                    runtime.ledstrip_store_reducer = StoreReducerType.init(
                        &runtime.store.stores,
                        LedStripStoreReducerFn.reduce,
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
            }

            fn buildRootConfig(runtime: *Runtime, init_config: InitConfig) BuiltRoot.Config {
                var config: BuiltRoot.Config = undefined;

                if (has_button_runtime) {
                    config._zux_button_detector = runtime.detector.node();
                    config._zux_button_store_reducer = runtime.store_reducer.node();
                }
                if (has_ledstrip_runtime) {
                    config._zux_ledstrip_store_reducer = runtime.ledstrip_store_reducer.node();
                }
                config._zux_store_tick = runtime.store_tick.node();

                if (has_user_root_config) {
                    copyUserRootConfig(&config, init_config.user_root_config);
                }

                return config;
            }

            fn copyUserRootConfig(dst: *BuiltRoot.Config, user_root_config: UserRoot.Config) void {
                inline for (@typeInfo(UserRoot.Config).@"struct".fields) |field| {
                    if (comptimeEql(field.name, "__branches")) continue;
                    @field(dst.*, field.name) = @field(user_root_config, field.name);
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

            fn initLedStripInstances(init_config: InitConfig) LedStripInstances {
                var led_strips: LedStripInstances = undefined;
                inline for (0..ledstrip_count) |i| {
                    const periph = ledstrip_registry.periphs[i];
                    const label_name = comptime periphLabel(periph);
                    @field(led_strips, label_name) = @field(init_config, label_name);
                }
                return led_strips;
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
                        return 0;
                    },
                    else => return 0,
                }
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
                            if (messagePeriphId(message) == periphIdForRecord(periph)) {
                                return LedStripReducerType.reduce(&@field(stores, periphLabel(periph)), message, emit);
                            }
                        }
                        return 0;
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
                    else => return 0,
                }
            }
        };

        runtime: *Runtime,
        started: bool = false,
        closed: bool = false,
        last_event: ?Message.Event = null,
        last_grouped_button_ids: [periph_ids.len]?u32 = [_]?u32{null} ** periph_ids.len,

        pub fn init(init_config: InitConfig) !Self {
            return .{
                .runtime = try Runtime.init(init_config),
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.started) {
                self.stop() catch {};
            }
            Runtime.deinit(self.runtime);
            self.last_event = null;
        }

        pub fn start(self: *Self) !void {
            if (self.started or self.closed) return error.InvalidState;

            try self.runtime.pipeline.start();
            errdefer {
                self.runtime.pipeline.stop();
                self.runtime.pipeline.wait();
            }

            inline for (0..runtime_poller_count) |i| {
                self.runtime.pollers[i].start(runtime_poller_config) catch |err| {
                    inline for (0..i) |started_idx| {
                        self.runtime.pollers[started_idx].stop();
                    }
                    self.runtime.pipeline.stop();
                    self.runtime.pipeline.wait();
                    return err;
                };
            }

            self.started = true;
        }

        pub fn stop(self: *Self) !void {
            if (!self.started) return error.InvalidState;

            inline for (&self.runtime.pollers) |*poller| {
                poller.stop();
            }
            self.runtime.pipeline.stop();
            self.runtime.pipeline.wait();

            self.runtime.commitStores();
            self.started = false;
            self.closed = true;
        }

        pub fn press_single_button(self: *Self, label: PeriphLabel) !void {
            if (dispatchKind(label) != .single_button) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .raw_single_button = .{
                    .source_id = periphId(label),
                    .pressed = true,
                },
            });
        }

        pub fn release_single_button(self: *Self, label: PeriphLabel) !void {
            if (dispatchKind(label) != .single_button) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .raw_single_button = .{
                    .source_id = periphId(label),
                    .pressed = false,
                },
            });
        }

        pub fn press_grouped_button(self: *Self, label: PeriphLabel, button_id: u32) !void {
            if (dispatchKind(label) != .grouped_button) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .raw_grouped_button = .{
                    .source_id = periphId(label),
                    .button_id = button_id,
                    .pressed = true,
                },
            });
            self.last_grouped_button_ids[@intFromEnum(label)] = button_id;
        }

        pub fn release_grouped_button(self: *Self, label: PeriphLabel) !void {
            if (dispatchKind(label) != .grouped_button) return error.InvalidPeriphKind;
            const last_button_id = self.last_grouped_button_ids[@intFromEnum(label)];
            try self.emitBody(.{
                .raw_grouped_button = .{
                    .source_id = periphId(label),
                    .button_id = last_button_id,
                    .pressed = false,
                },
            });
            self.last_grouped_button_ids[@intFromEnum(label)] = null;
        }

        pub fn set_led_strip_pixels(self: *Self, label: PeriphLabel, frame: FrameType, brightness: u8) !void {
            if (dispatchKind(label) != .led_strip) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .ledstrip_set_pixels = .{
                    .periph_id = periphId(label),
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
            if (dispatchKind(label) != .led_strip) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .ledstrip_set = .{
                    .periph_id = periphId(label),
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
            if (dispatchKind(label) != .led_strip) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .ledstrip_flash = .{
                    .periph_id = periphId(label),
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
            if (dispatchKind(label) != .led_strip) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .ledstrip_pingpong = .{
                    .periph_id = periphId(label),
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
            if (dispatchKind(label) != .led_strip) return error.InvalidPeriphKind;
            try self.emitBody(.{
                .ledstrip_rotate = .{
                    .periph_id = periphId(label),
                    .pixels = frame.pixels[0..],
                    .brightness = brightness,
                    .duration_ns = duration_ns,
                    .interval_ns = interval_ns,
                },
            });
        }

        pub fn store(self: *Self) *StoreType {
            return &self.runtime.store;
        }

        fn emitBody(self: *Self, body: Message.Event) !void {
            if (!self.started) return error.NotStarted;
            self.last_event = body;
            try self.runtime.pipeline.emit(body);
        }

        fn periphId(label: PeriphLabel) u32 {
            return periph_ids[@intFromEnum(label)];
        }

        fn dispatchKind(label: PeriphLabel) PeriphDispatchKind {
            return periph_kinds[@intFromEnum(label)];
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
    inline for (0..ledstrip_count) |i| {
        const periph = ledstrip_registry.periphs[i];
        builder.setStore(periph.label, store.Object.make(context.lib, LedStripStateType, periph.label));
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

    if (totalPollerCount(context.registries) > 0) {
        builder.node(._zux_button_detector);
        builder.node(._zux_button_store_reducer);
    }
    if (registryPeriphLen(context.registries.ledstrip) > 0) {
        builder.node(._zux_ledstrip_store_reducer);
    }

    inline for (0..context.node_builder.len) |i| {
        switch (context.node_builder.ops[i]) {
            .node => |tag| builder.node(tag),
            .begin_switch => builder.beginSwitch(),
            .route => |kind| builder.case(kind),
            .end_switch => builder.endSwitch(),
        }
    }

    builder.node(._zux_store_tick);

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
    return registryPeriphLen(registries.gpio_button) + registryPeriphLen(registries.adc_button);
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
            .tag_type = if (total_len == 0) u0 else embed.math.IntFittingRange(0, total_len - 1),
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
    led_strip,
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
    if (ControlType == ledstrip.LedStrip) return .led_strip;
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

fn messagePeriphId(message: Message) u32 {
    return switch (message.body) {
        .ledstrip_set => |event| event.periph_id,
        .ledstrip_set_pixels => |event| event.periph_id,
        .ledstrip_flash => |event| event.periph_id,
        .ledstrip_pingpong => |event| event.periph_id,
        .ledstrip_rotate => |event| event.periph_id,
        else => @panic("zux.assembler.Builder.messagePeriphId expected ledstrip event"),
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
