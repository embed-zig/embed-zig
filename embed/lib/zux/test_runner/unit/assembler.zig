const glib = @import("glib");

const Assembler = @import("../../Assembler.zig");
const Store = @import("../../Store.zig");
const Emitter = @import("../../pipeline/Emitter.zig");
const Message = @import("../../pipeline/Message.zig");
const Node = @import("../../pipeline/Node.zig");
const registry_unique = @import("../../assembler/registry/unique.zig");
const ui_flow = @import("../../component/ui/flow.zig");

const PairingFlow = blk: {
    var builder = ui_flow.Builder.init();
    builder.addNode("idle");
    builder.addNode("searching");
    builder.addEdge("idle", "searching", "start");
    break :blk builder.build();
};

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const TestCase = struct {
                fn make_uses_store_and_runtime_config() !void {
                    const AssemblerType = Assembler.make(grt, .{
                        .store = .{
                            .max_stores = 8,
                            .max_state_nodes = 32,
                            .max_store_refs = 64,
                            .max_depth = 12,
                        },
                        .node = .{
                            .max_ops = 24,
                        },
                        .max_imu = 2,
                        .max_adc_buttons = 4,
                        .max_gpio_buttons = 6,
                        .max_led_strips = 3,
                        .max_modem = 2,
                        .max_nfc = 2,
                        .max_wifi_sta = 2,
                        .max_wifi_ap = 2,
                        .max_flows = 2,
                        .max_overlays = 2,
                        .max_routers = 2,
                        .max_selections = 2,
                    });

                    const assembler = comptime AssemblerType.init();
                    try grt.std.testing.expect(AssemblerType.Lib == grt);
                    try grt.std.testing.expectEqual(@as(usize, 8), assembler.store_builder.store_bindings.len);
                    try grt.std.testing.expectEqual(@as(usize, 32), assembler.store_builder.state_bindings.len);
                    try grt.std.testing.expectEqual(AssemblerType.Config.max_reducers, assembler.reducer_bindings.len);
                    try grt.std.testing.expectEqual(@as(usize, 4), assembler.adc_button_registry.periphs.len);
                    try grt.std.testing.expectEqual(@as(usize, 6), assembler.gpio_button_registry.periphs.len);
                    try grt.std.testing.expectEqual(@as(usize, 2), assembler.imu_registry.periphs.len);
                    try grt.std.testing.expectEqual(@as(usize, 3), assembler.ledstrip_registry.periphs.len);
                    try grt.std.testing.expectEqual(@as(usize, 2), assembler.modem_registry.periphs.len);
                    try grt.std.testing.expectEqual(@as(usize, 2), assembler.nfc_registry.periphs.len);
                    try grt.std.testing.expectEqual(@as(usize, 2), assembler.wifi_sta_registry.periphs.len);
                    try grt.std.testing.expectEqual(@as(usize, 2), assembler.wifi_ap_registry.periphs.len);
                    try grt.std.testing.expectEqual(@as(usize, 2), assembler.flow_registry.periphs.len);
                    try grt.std.testing.expectEqual(@as(usize, 2), assembler.overlay_registry.periphs.len);
                    try grt.std.testing.expectEqual(@as(usize, 2), assembler.router_registry.periphs.len);
                    try grt.std.testing.expectEqual(@as(usize, 2), assembler.selection_registry.periphs.len);
                    try grt.std.testing.expectEqual(@as(usize, 0), assembler.store_builder.store_count);
                    try grt.std.testing.expectEqual(@as(usize, 0), assembler.adc_button_registry.len);
                    try grt.std.testing.expectEqual(@as(usize, 0), assembler.gpio_button_registry.len);
                    try grt.std.testing.expectEqual(@as(usize, 0), assembler.imu_registry.len);
                    try grt.std.testing.expectEqual(@as(usize, 0), assembler.ledstrip_registry.len);
                    try grt.std.testing.expectEqual(@as(usize, 0), assembler.modem_registry.len);
                    try grt.std.testing.expectEqual(@as(usize, 0), assembler.nfc_registry.len);
                    try grt.std.testing.expectEqual(@as(usize, 0), assembler.wifi_sta_registry.len);
                    try grt.std.testing.expectEqual(@as(usize, 0), assembler.wifi_ap_registry.len);
                    try grt.std.testing.expectEqual(@as(usize, 0), assembler.flow_registry.len);
                    try grt.std.testing.expectEqual(@as(usize, 0), assembler.overlay_registry.len);
                    try grt.std.testing.expectEqual(@as(usize, 0), assembler.router_registry.len);
                    try grt.std.testing.expectEqual(@as(usize, 0), assembler.selection_registry.len);
                    try grt.std.testing.expectEqual(@as(usize, 0), assembler.reducer_count);
                }

                fn custom_pipeline_node_runs_before_store_tick() !void {
                    const WifiState = struct { enabled: bool = false };
                    const WifiStore = Store.Object.make(grt, WifiState, .wifi);

                    const Built = comptime blk: {
                        const AssemblerType = Assembler.make(grt, .{});
                        var next = AssemblerType.init();
                        next.setStore("wifi", WifiStore);
                        next.setState("ui/home", .{"wifi"});
                        const BuildConfig = next.BuildConfig();
                        const build_config: BuildConfig = .{};
                        break :blk next.build(build_config);
                    };

                    const CustomPipelineNode = struct {
                        out: ?Emitter = null,
                        calls: usize = 0,

                        pub fn bindOutput(self_node: *@This(), out: Emitter) void {
                            self_node.out = out;
                        }

                        pub fn process(self_node: *@This(), message: Message) !usize {
                            self_node.calls += 1;
                            if (self_node.out) |out| {
                                try out.emit(message);
                                return 1;
                            }
                            return 0;
                        }
                    };
                    var custom_pipeline_node = CustomPipelineNode{};
                    var app = try Built.init(.{
                        .allocator = grt.std.testing.allocator,
                        .initial_state = .{ .wifi = .{} },
                        .custom_pipeline_node = Node.init(CustomPipelineNode, &custom_pipeline_node),
                    });
                    defer app.deinit();

                    _ = try app.impl.runtime.root.process(.{
                        .origin = .manual,
                        .timestamp = 0,
                        .body = .{
                            .tick = .{
                                .seq = 1,
                            },
                        },
                    });

                    try grt.std.testing.expectEqual(@as(usize, 1), custom_pipeline_node.calls);
                }

                fn build_auto_wires_configured_reducers() !void {
                    const CounterState = struct {
                        ticks: usize = 0,
                    };
                    const CounterStore = Store.Object.make(grt, CounterState, .counter);

                    const Built = comptime blk: {
                        const AssemblerType = Assembler.make(grt, .{
                            .max_reducers = 2,
                        });
                        var next = AssemblerType.init();
                        next.setStore("counter", CounterStore);
                        next.addReducer("counter");
                        const BuildConfig = next.BuildConfig();
                        const build_config: BuildConfig = .{};
                        break :blk next.build(build_config);
                    };

                    try grt.std.testing.expect(@hasField(Built.Root.Config, "counter"));
                    try grt.std.testing.expect(@hasField(Built.InitConfig, "counter"));
                    const reducer_field = comptime initConfigField(Built.InitConfig, "counter");
                    try grt.std.testing.expect(reducer_field.type == ?Built.ReducerHook);
                    try grt.std.testing.expect(initConfigFieldDefaultValue(reducer_field) == null);

                    try grt.std.testing.expectError(error.MissingReducerHook, Built.init(.{
                        .allocator = grt.std.testing.allocator,
                        .initial_state = .{
                            .counter = .{},
                        },
                    }));

                    const RuntimeCounterReducer = struct {
                        calls: usize = 0,
                        increment_by: usize = 1,

                        pub fn reduce(
                            self_hook: *@This(),
                            stores: *Built.Store.Stores,
                            message: Message,
                            emit: Emitter,
                        ) !usize {
                            _ = emit;
                            switch (message.body) {
                                .tick => {
                                    self_hook.calls += 1;
                                    stores.counter.invoke(self_hook.increment_by, struct {
                                        fn apply(state: *CounterState, increment_by: usize) void {
                                            state.ticks += increment_by;
                                        }
                                    }.apply);
                                    return 1;
                                },
                                else => return 0,
                            }
                        }
                    };
                    var runtime_reducer = RuntimeCounterReducer{
                        .increment_by = 5,
                    };

                    var app = try Built.init(.{
                        .allocator = grt.std.testing.allocator,
                        .initial_state = .{
                            .counter = .{
                                .ticks = 41,
                            },
                        },
                        .counter = Built.ReducerHook.init(&runtime_reducer),
                    });
                    defer app.deinit();

                    try grt.std.testing.expectEqual(@as(usize, 41), app.store.stores.counter.get().ticks);
                    _ = try app.impl.runtime.root.process(.{
                        .origin = .manual,
                        .timestamp = 0,
                        .body = .{
                            .tick = .{
                                .seq = 1,
                            },
                        },
                    });
                    try grt.std.testing.expectEqual(@as(usize, 1), runtime_reducer.calls);
                    try grt.std.testing.expectEqual(@as(usize, 46), app.store.stores.counter.get().ticks);
                }

                fn manual_start_disables_auto_ticks_and_dispatch_processes_messages() !void {
                    const CounterState = struct {
                        ticks: usize = 0,
                        pressed: bool = false,
                    };
                    const CounterStore = Store.Object.make(grt, CounterState, .counter);

                    const Built = comptime blk: {
                        const AssemblerType = Assembler.make(grt, .{
                            .max_reducers = 1,
                        });
                        var next = AssemblerType.init();
                        next.setStore("counter", CounterStore);
                        next.addReducer("counter");
                        const BuildConfig = next.BuildConfig();
                        const build_config: BuildConfig = .{};
                        break :blk next.build(build_config);
                    };

                    const RuntimeCounterReducer = struct {
                        pub fn reduce(
                            self_hook: *@This(),
                            stores: *Built.Store.Stores,
                            message: Message,
                            emit: Emitter,
                        ) !usize {
                            _ = self_hook;
                            _ = emit;
                            switch (message.body) {
                                .tick => {
                                    stores.counter.invoke({}, struct {
                                        fn apply(state: *CounterState, _: void) void {
                                            state.ticks += 1;
                                        }
                                    }.apply);
                                    return 1;
                                },
                                .raw_single_button => |button| {
                                    stores.counter.invoke(button.pressed, struct {
                                        fn apply(state: *CounterState, pressed: bool) void {
                                            state.pressed = pressed;
                                        }
                                    }.apply);
                                    return 1;
                                },
                                else => return 0,
                            }
                        }
                    };

                    var runtime_reducer = RuntimeCounterReducer{};
                    var app = try Built.init(.{
                        .allocator = grt.std.testing.allocator,
                        .initial_state = .{
                            .counter = .{},
                        },
                        .counter = Built.ReducerHook.init(&runtime_reducer),
                    });
                    defer app.deinit();

                    try app.start(.{ .ticker = .manual });
                    grt.std.Thread.sleep(@intCast(3 * grt.time.duration.MilliSecond));
                    try grt.std.testing.expectEqual(@as(usize, 0), app.store.stores.counter.get().ticks);

                    try app.dispatch(.{
                        .origin = .timer,
                        .timestamp = 0,
                        .body = .{
                            .tick = .{
                                .seq = 1,
                            },
                        },
                    });
                    try grt.std.testing.expectEqual(@as(usize, 1), app.store.stores.counter.get().ticks);

                    try app.dispatch(.{
                        .origin = .manual,
                        .timestamp = 0,
                        .body = .{
                            .raw_single_button = .{
                                .source_id = 7,
                                .pressed = true,
                            },
                        },
                    });
                    switch (app.impl.last_event.?) {
                        .raw_single_button => |event_value| {
                            try grt.std.testing.expectEqual(@as(u32, 7), event_value.source_id);
                            try grt.std.testing.expect(event_value.pressed);
                        },
                        else => return error.UnexpectedMessage,
                    }

                    try app.dispatch(.{
                        .origin = .timer,
                        .timestamp = 1,
                        .body = .{
                            .tick = .{
                                .seq = 2,
                            },
                        },
                    });
                    try grt.std.testing.expectEqual(@as(usize, 2), app.store.stores.counter.get().ticks);
                    try grt.std.testing.expect(app.store.stores.counter.get().pressed);

                    try app.stop();
                    try grt.std.testing.expectError(error.NotStarted, app.dispatch(.{
                        .origin = .timer,
                        .timestamp = 0,
                        .body = .{
                            .tick = .{
                                .seq = 2,
                            },
                        },
                    }));
                }

                fn add_grouped_button_records_registry_entry() !void {
                    const assembler = comptime blk: {
                        const AssemblerType = Assembler.make(grt, .{
                            .max_adc_buttons = 2,
                        });
                        var next = AssemblerType.init();
                        next.addGroupedButton("buttons", 7, 3);
                        break :blk next;
                    };

                    try grt.std.testing.expectEqual(@as(usize, 1), assembler.adc_button_registry.len);
                    try grt.std.testing.expectEqual(@as(u32, 7), assembler.adc_button_registry.periphs[0].id);
                    try grt.std.testing.expectEqual(@as(usize, 3), assembler.adc_button_registry.periphs[0].button_count);
                }

                fn build_config_exposes_added_labels() !void {
                    const BuildConfig = comptime blk: {
                        const AssemblerType = Assembler.make(grt, .{
                            .max_adc_buttons = 2,
                            .max_imu = 1,
                            .max_led_strips = 1,
                            .max_modem = 1,
                            .max_nfc = 1,
                            .max_wifi_sta = 1,
                            .max_wifi_ap = 1,
                        });
                        var next = AssemblerType.init();
                        next.addGroupedButton("buttons", 7, 3);
                        next.addImu("imu", 13);
                        next.addLedStrip("strip", 9, 4);
                        next.addModem("modem", 15);
                        next.addNfc("nfc", 17);
                        next.addWifiSta("sta", 19);
                        next.addWifiAp("ap", 21);
                        break :blk next.BuildConfig();
                    };

                    try grt.std.testing.expect(@hasField(BuildConfig, "buttons"));
                    try grt.std.testing.expect(@hasField(BuildConfig, "imu"));
                    try grt.std.testing.expect(@hasField(BuildConfig, "strip"));
                    try grt.std.testing.expect(@hasField(BuildConfig, "modem"));
                    try grt.std.testing.expect(@hasField(BuildConfig, "nfc"));
                    try grt.std.testing.expect(@hasField(BuildConfig, "sta"));
                    try grt.std.testing.expect(@hasField(BuildConfig, "ap"));
                }

                fn add_led_strip_records_registry_entry() !void {
                    const assembler = comptime blk: {
                        const AssemblerType = Assembler.make(grt, .{
                            .max_led_strips = 2,
                        });
                        var next = AssemblerType.init();
                        next.addLedStrip("strip", 9, 4);
                        break :blk next;
                    };

                    try grt.std.testing.expectEqual(@as(usize, 1), assembler.ledstrip_registry.len);
                    try grt.std.testing.expectEqual(@as(u32, 9), assembler.ledstrip_registry.periphs[0].id);
                    try grt.std.testing.expectEqual(@as(usize, 4), assembler.ledstrip_registry.periphs[0].pixel_count);
                }

                fn add_component_registries_record_entries() !void {
                    const assembler = comptime blk: {
                        const AssemblerType = Assembler.make(grt, .{
                            .max_imu = 1,
                            .max_modem = 1,
                            .max_nfc = 1,
                            .max_wifi_sta = 1,
                            .max_wifi_ap = 1,
                        });
                        var next = AssemblerType.init();
                        next.addImu("imu", 13);
                        next.addModem("modem", 15);
                        next.addNfc("nfc", 17);
                        next.addWifiSta("sta", 19);
                        next.addWifiAp("ap", 21);
                        break :blk next;
                    };

                    try grt.std.testing.expectEqual(@as(usize, 1), assembler.imu_registry.len);
                    try grt.std.testing.expectEqual(@as(u32, 13), assembler.imu_registry.periphs[0].id);
                    try grt.std.testing.expectEqual(@as(usize, 1), assembler.modem_registry.len);
                    try grt.std.testing.expectEqual(@as(u32, 15), assembler.modem_registry.periphs[0].id);
                    try grt.std.testing.expectEqual(@as(usize, 1), assembler.nfc_registry.len);
                    try grt.std.testing.expectEqual(@as(u32, 17), assembler.nfc_registry.periphs[0].id);
                    try grt.std.testing.expectEqual(@as(usize, 1), assembler.wifi_sta_registry.len);
                    try grt.std.testing.expectEqual(@as(u32, 19), assembler.wifi_sta_registry.periphs[0].id);
                    try grt.std.testing.expectEqual(@as(usize, 1), assembler.wifi_ap_registry.len);
                    try grt.std.testing.expectEqual(@as(u32, 21), assembler.wifi_ap_registry.periphs[0].id);
                }

                fn add_ui_registries_record_entries() !void {
                    const assembler = comptime blk: {
                        const AssemblerType = Assembler.make(grt, .{
                            .max_flows = 1,
                            .max_overlays = 1,
                            .max_routers = 1,
                            .max_selections = 1,
                        });
                        var next = AssemblerType.init();
                        next.addFlow("pairing", 31, PairingFlow);
                        next.addOverlay("loading", 41);
                        next.addRouter("nav", 51);
                        next.addSelection("menu", 61);
                        break :blk next;
                    };

                    try grt.std.testing.expectEqual(@as(usize, 1), assembler.flow_registry.len);
                    try grt.std.testing.expectEqual(@as(u32, 31), assembler.flow_registry.periphs[0].id);
                    try grt.std.testing.expect(@hasDecl(assembler.flow_registry.periphs[0].FlowType, "Reducer"));
                    try grt.std.testing.expectEqual(@as(usize, 1), assembler.overlay_registry.len);
                    try grt.std.testing.expectEqual(@as(u32, 41), assembler.overlay_registry.periphs[0].id);
                    try grt.std.testing.expectEqual(@as(usize, 1), assembler.router_registry.len);
                    try grt.std.testing.expectEqual(@as(u32, 51), assembler.router_registry.periphs[0].id);
                    try grt.std.testing.expectEqual(@as(usize, 1), assembler.selection_registry.len);
                    try grt.std.testing.expectEqual(@as(u32, 61), assembler.selection_registry.periphs[0].id);
                    try grt.std.testing.expectEqual(@as(usize, 3), assembler.store_builder.store_count);
                }

                fn component_duplicate_detector_rejects_reused_labels_and_ids() !void {
                    const assembler = comptime blk: {
                        const AssemblerType = Assembler.make(grt, .{
                            .max_gpio_buttons = 1,
                            .max_flows = 1,
                            .max_overlays = 1,
                            .max_routers = 1,
                            .max_selections = 1,
                        });
                        var next = AssemblerType.init();
                        next.addSingleButton("shared", 7);
                        next.addFlow("pairing", 31, PairingFlow);
                        next.addOverlay("loading", 41);
                        next.addRouter("nav", 51);
                        next.addSelection("menu", 61);
                        break :blk next;
                    };

                    try grt.std.testing.expect(!registry_unique.isUniqueAcross(
                        .{
                            assembler.gpio_button_registry,
                            assembler.flow_registry,
                            assembler.overlay_registry,
                            assembler.router_registry,
                            assembler.selection_registry,
                        },
                        .shared,
                        99,
                    ));
                    try grt.std.testing.expect(!registry_unique.isUniqueAcross(
                        .{
                            assembler.gpio_button_registry,
                            assembler.flow_registry,
                            assembler.overlay_registry,
                            assembler.router_registry,
                            assembler.selection_registry,
                        },
                        .fresh,
                        31,
                    ));
                    try grt.std.testing.expect(registry_unique.isUniqueAcross(
                        .{
                            assembler.gpio_button_registry,
                            assembler.flow_registry,
                            assembler.overlay_registry,
                            assembler.router_registry,
                            assembler.selection_registry,
                        },
                        .fresh,
                        99,
                    ));
                }

                fn build_without_optional_ui_still_returns_valid_app() !void {
                    const Built = comptime blk: {
                        const AssemblerType = Assembler.make(grt, .{});
                        var next = AssemblerType.init();
                        const BuildConfig = next.BuildConfig();
                        const build_config: BuildConfig = .{};
                        break :blk next.build(build_config);
                    };

                    try grt.std.testing.expectEqual(@as(usize, 0), @typeInfo(Built.FlowLabel).@"enum".fields.len);
                    try grt.std.testing.expectEqual(@as(usize, 0), @typeInfo(Built.RouterLabel).@"enum".fields.len);
                    try grt.std.testing.expectEqual(@as(usize, 0), @typeInfo(Built.OverlayLabel).@"enum".fields.len);
                    try grt.std.testing.expectEqual(@as(usize, 0), @typeInfo(Built.SelectionLabel).@"enum".fields.len);

                    var app = try Built.init(.{
                        .allocator = grt.std.testing.allocator,
                        .initial_state = .{},
                    });
                    try app.start(.{});
                    try app.stop();
                    app.deinit();
                }

                fn ui_source_ids_follow_configured_ids() !void {
                    const Built = comptime blk: {
                        const AssemblerType = Assembler.make(grt, .{
                            .max_flows = 2,
                            .max_overlays = 2,
                            .max_routers = 2,
                            .max_selections = 2,
                        });
                        var next = AssemblerType.init();
                        next.addFlow("pairing_a", 31, PairingFlow);
                        next.addFlow("pairing_b", 32, PairingFlow);
                        next.addOverlay("loading_a", 41);
                        next.addOverlay("loading_b", 42);
                        next.addRouter("nav_a", 51);
                        next.addRouter("nav_b", 52);
                        next.addSelection("menu_a", 61);
                        next.addSelection("menu_b", 62);

                        const BuildConfig = next.BuildConfig();
                        const build_config: BuildConfig = .{};
                        break :blk next.build(build_config);
                    };

                    var app = try Built.init(.{
                        .allocator = grt.std.testing.allocator,
                        .initial_state = .{
                            .pairing_a = .{ .node = .idle },
                            .pairing_b = .{ .node = .idle },
                            .loading_a = .{},
                            .loading_b = .{},
                            .nav_a = .{},
                            .nav_b = .{},
                            .menu_a = .{ .count = 2 },
                            .menu_b = .{ .count = 2 },
                        },
                    });
                    defer app.deinit();

                    try app.start(.{});
                    defer app.stop() catch {};

                    try app.push_route(.nav_a, .{ .screen_id = 8 });
                    switch (app.impl.last_event.?) {
                        .ui_route_push => |event_value| {
                            try grt.std.testing.expectEqual(@as(u32, 51), event_value.source_id);
                        },
                        else => return error.UnexpectedMessage,
                    }

                    try app.push_route(.nav_b, .{ .screen_id = 9 });
                    switch (app.impl.last_event.?) {
                        .ui_route_push => |event_value| {
                            try grt.std.testing.expectEqual(@as(u32, 52), event_value.source_id);
                        },
                        else => return error.UnexpectedMessage,
                    }

                    try app.move_flow(.pairing_a, .forward, .start);
                    switch (app.impl.last_event.?) {
                        .ui_flow_move => |event_value| {
                            try grt.std.testing.expectEqual(@as(u32, 31), event_value.source_id);
                        },
                        else => return error.UnexpectedMessage,
                    }

                    try app.move_flow(.pairing_b, .forward, .start);
                    switch (app.impl.last_event.?) {
                        .ui_flow_move => |event_value| {
                            try grt.std.testing.expectEqual(@as(u32, 32), event_value.source_id);
                        },
                        else => return error.UnexpectedMessage,
                    }

                    try app.reset_flow(.pairing_b);
                    switch (app.impl.last_event.?) {
                        .ui_flow_reset => |event_value| {
                            try grt.std.testing.expectEqual(@as(u32, 32), event_value.source_id);
                        },
                        else => return error.UnexpectedMessage,
                    }

                    try app.show_overlay(.loading_a, "base", false);
                    switch (app.impl.last_event.?) {
                        .ui_overlay_show => |event_value| {
                            try grt.std.testing.expectEqual(@as(u32, 41), event_value.source_id);
                        },
                        else => return error.UnexpectedMessage,
                    }

                    try app.show_overlay(.loading_b, "busy", true);
                    switch (app.impl.last_event.?) {
                        .ui_overlay_show => |event_value| {
                            try grt.std.testing.expectEqual(@as(u32, 42), event_value.source_id);
                        },
                        else => return error.UnexpectedMessage,
                    }

                    try app.hide_overlay(.loading_b);
                    switch (app.impl.last_event.?) {
                        .ui_overlay_hide => |event_value| {
                            try grt.std.testing.expectEqual(@as(u32, 42), event_value.source_id);
                        },
                        else => return error.UnexpectedMessage,
                    }

                    try app.next_selection(.menu_a);
                    switch (app.impl.last_event.?) {
                        .ui_selection_next => |event_value| {
                            try grt.std.testing.expectEqual(@as(u32, 61), event_value.source_id);
                        },
                        else => return error.UnexpectedMessage,
                    }

                    try app.next_selection(.menu_b);
                    switch (app.impl.last_event.?) {
                        .ui_selection_next => |event_value| {
                            try grt.std.testing.expectEqual(@as(u32, 62), event_value.source_id);
                        },
                        else => return error.UnexpectedMessage,
                    }

                    try app.reset_selection(.menu_b);
                    switch (app.impl.last_event.?) {
                        .ui_selection_reset => |event_value| {
                            try grt.std.testing.expectEqual(@as(u32, 62), event_value.source_id);
                        },
                        else => return error.UnexpectedMessage,
                    }
                }

                fn built_app_exposes_registry_metadata() !void {
                    const Built = comptime blk: {
                        const AssemblerType = Assembler.make(grt, .{
                            .max_adc_buttons = 1,
                            .max_flows = 1,
                            .max_overlays = 1,
                            .max_routers = 1,
                            .max_selections = 1,
                        });
                        var next = AssemblerType.init();
                        next.addGroupedButton("buttons", 7, 3);
                        next.addFlow("pairing", 31, PairingFlow);
                        next.addOverlay("loading", 41);
                        next.addRouter("nav", 51);
                        next.addSelection("menu", 61);

                        const BuildConfig = next.BuildConfig();
                        const build_config: BuildConfig = .{
                            .buttons = @import("drivers").button.Grouped,
                        };
                        break :blk next.build(build_config);
                    };

                    const meta = comptime .{
                        .grouped_button_id = Built.registries.adc_button.periphs[0].id,
                        .flow_id = Built.registries.flow.periphs[0].id,
                        .overlay_id = Built.registries.overlay.periphs[0].id,
                        .router_id = Built.registries.router.periphs[0].id,
                        .selection_id = Built.registries.selection.periphs[0].id,
                    };

                    try grt.std.testing.expect(@hasDecl(Built, "Registries"));
                    try grt.std.testing.expect(@hasDecl(Built, "registries"));
                    try grt.std.testing.expectEqual(@as(usize, 1), Built.registries.adc_button.len);
                    try grt.std.testing.expectEqual(@as(usize, 1), Built.registries.flow.len);
                    try grt.std.testing.expectEqual(@as(usize, 1), Built.registries.overlay.len);
                    try grt.std.testing.expectEqual(@as(usize, 1), Built.registries.router.len);
                    try grt.std.testing.expectEqual(@as(usize, 1), Built.registries.selection.len);
                    try grt.std.testing.expectEqual(@as(u32, 7), meta.grouped_button_id);
                    try grt.std.testing.expectEqual(@as(u32, 31), meta.flow_id);
                    try grt.std.testing.expectEqual(@as(u32, 41), meta.overlay_id);
                    try grt.std.testing.expectEqual(@as(u32, 51), meta.router_id);
                    try grt.std.testing.expectEqual(@as(u32, 61), meta.selection_id);
                }

                fn build_returns_app_methods() !void {
                    const drivers = @import("drivers");
                    const ledstrip_mod = @import("ledstrip");

                    const Built = comptime blk: {
                        const AssemblerType = Assembler.make(grt, .{
                            .max_adc_buttons = 2,
                            .max_led_strips = 1,
                            .pipeline = .{
                                .tick_interval = 7 * grt.time.duration.MilliSecond,
                                .spawn_config = .{
                                    .stack_size = 64 * 1024,
                                },
                            },
                        });
                        var next = AssemblerType.init();
                        next.addGroupedButton("buttons", 7, 3);
                        next.addLedStrip("strip", 11, 4);
                        next.addFlow("pairing", 31, PairingFlow);
                        next.addOverlay("loading", 41);
                        next.addRouter("nav", 51);
                        next.addSelection("menu", 61);

                        const BuildConfig = next.BuildConfig();
                        const build_config: BuildConfig = .{
                            .buttons = @import("drivers").button.Grouped,
                            .strip = ledstrip_mod.LedStrip,
                        };
                        break :blk next.build(build_config);
                    };

                    try grt.std.testing.expect(@hasDecl(Built, "PeriphLabel"));
                    try grt.std.testing.expect(@hasDecl(Built, "InitConfig"));
                    try grt.std.testing.expect(@hasDecl(Built, "start"));
                    try grt.std.testing.expect(@hasDecl(Built, "stop"));
                    try grt.std.testing.expect(@hasDecl(Built, "press_single_button"));
                    try grt.std.testing.expect(@hasDecl(Built, "release_single_button"));
                    try grt.std.testing.expect(@hasDecl(Built, "press_grouped_button"));
                    try grt.std.testing.expect(@hasDecl(Built, "release_grouped_button"));
                    try grt.std.testing.expect(@hasDecl(Built, "set_led_strip_animated"));
                    try grt.std.testing.expect(@hasDecl(Built, "set_led_strip_pixels"));
                    try grt.std.testing.expect(@hasDecl(Built, "set_led_strip_flash"));
                    try grt.std.testing.expect(@hasDecl(Built, "set_led_strip_pingpong"));
                    try grt.std.testing.expect(@hasDecl(Built, "set_led_strip_rotate"));
                    try grt.std.testing.expect(@hasDecl(Built, "router"));
                    try grt.std.testing.expect(@hasDecl(Built, "push_route"));
                    try grt.std.testing.expect(@hasDecl(Built, "move_flow"));
                    try grt.std.testing.expect(@hasDecl(Built, "available_moves"));
                    try grt.std.testing.expect(@hasDecl(Built, "show_overlay"));
                    try grt.std.testing.expect(@hasDecl(Built, "next_selection"));
                    try grt.std.testing.expectEqual(@as(usize, 1), Built.poller_count);
                    try grt.std.testing.expectEqual(@as(usize, 4), Built.pixel_count);
                    try grt.std.testing.expectEqual(@as(usize, 4), Built.LedStrip(.strip).pixel_count);
                    try grt.std.testing.expectEqual(@as(usize, 4), Built.LedStrip(.strip).FrameType.pixel_count);
                    try grt.std.testing.expectEqual(@as(glib.time.duration.Duration, 7 * grt.time.duration.MilliSecond), Built.ImplType.pipeline_config.tick_interval);
                    if (@hasField(@TypeOf(Built.ImplType.pipeline_config.spawn_config), "stack_size")) {
                        try grt.std.testing.expectEqual(
                            @as(usize, 64 * 1024),
                            Built.ImplType.pipeline_config.spawn_config.stack_size,
                        );
                    }
                    try grt.std.testing.expectEqualStrings("buttons", @typeInfo(Built.PeriphLabel).@"enum".fields[0].name);
                    try grt.std.testing.expect(@hasField(Built.Store.Stores, "buttons"));
                    try grt.std.testing.expect(@hasField(Built.Store.Stores, "strip"));
                    try grt.std.testing.expect(@hasField(Built.Store.Stores, "pairing"));
                    try grt.std.testing.expect(@hasField(Built.Store.Stores, "loading"));
                    try grt.std.testing.expect(@hasField(Built.Store.Stores, "nav"));
                    try grt.std.testing.expect(@hasField(Built.Store.Stores, "menu"));

                    const MockGrouped = struct {
                        pub fn pressedButtonId(_: *@This()) !?u32 {
                            return null;
                        }
                    };
                    const DummyStrip = struct {
                        pixels: [4]ledstrip_mod.Color = [_]ledstrip_mod.Color{ledstrip_mod.Color.black} ** 4,

                        fn deinitFn(_: *anyopaque) void {}

                        fn countFn(_: *anyopaque) usize {
                            return 4;
                        }

                        fn setPixelFn(ptr: *anyopaque, index: usize, color: ledstrip_mod.Color) void {
                            const dummy: *@This() = @ptrCast(@alignCast(ptr));
                            if (index >= dummy.pixels.len) return;
                            dummy.pixels[index] = color;
                        }

                        fn pixelFn(ptr: *anyopaque, index: usize) ledstrip_mod.Color {
                            const dummy: *@This() = @ptrCast(@alignCast(ptr));
                            if (index >= dummy.pixels.len) return ledstrip_mod.Color.black;
                            return dummy.pixels[index];
                        }

                        fn refreshFn(_: *anyopaque) void {}

                        const vtable = ledstrip_mod.LedStrip.VTable{
                            .deinit = deinitFn,
                            .count = countFn,
                            .setPixel = setPixelFn,
                            .pixel = pixelFn,
                            .refresh = refreshFn,
                        };

                        fn handle(dummy: *@This()) ledstrip_mod.LedStrip {
                            return .{
                                .ptr = dummy,
                                .vtable = &vtable,
                            };
                        }
                    };
                    var mock_grouped = MockGrouped{};
                    var dummy_strip = DummyStrip{};
                    var app = try Built.init(.{
                        .allocator = grt.std.testing.allocator,
                        .initial_state = .{
                            .buttons = .{},
                            .strip = .{},
                            .pairing = .{ .node = .idle },
                            .loading = .{},
                            .nav = .{ .current_page = 5 },
                            .menu = .{ .count = 2 },
                        },
                        .buttons = drivers.button.Grouped.init(MockGrouped, &mock_grouped),
                        .strip = dummy_strip.handle(),
                    });
                    try app.start(.{});
                    try grt.std.testing.expectEqual(@as(u32, 5), app.router(.nav).currentPage());
                    const moves = try app.available_moves(.pairing, grt.std.testing.allocator);
                    defer grt.std.testing.allocator.free(moves);
                    try grt.std.testing.expectEqual(@as(usize, 1), moves.len);
                    try grt.std.testing.expect(moves[0].direction == .forward);
                    try grt.std.testing.expect(moves[0].edge == .start);
                    try grt.std.testing.expectError(error.InvalidPeriphKind, app.press_single_button(.buttons));
                    try grt.std.testing.expectError(error.InvalidPeriphKind, app.release_single_button(.buttons));
                    try grt.std.testing.expectError(error.InvalidPeriphKind, app.set_led_strip_pixels(.buttons, Built.FrameType{}, 1));
                    try app.press_grouped_button(.buttons, 1);
                    switch (app.impl.last_event.?) {
                        .raw_grouped_button => |event_value| {
                            try grt.std.testing.expectEqual(@as(u32, 7), event_value.source_id);
                            try grt.std.testing.expectEqual(@as(?u32, 1), event_value.button_id);
                            try grt.std.testing.expect(event_value.pressed);
                        },
                        else => return error.UnexpectedMessage,
                    }
                    try app.release_grouped_button(.buttons);
                    switch (app.impl.last_event.?) {
                        .raw_grouped_button => |event_value| {
                            try grt.std.testing.expectEqual(@as(u32, 7), event_value.source_id);
                            try grt.std.testing.expectEqual(@as(?u32, 1), event_value.button_id);
                            try grt.std.testing.expect(!event_value.pressed);
                        },
                        else => return error.UnexpectedMessage,
                    }
                    try app.set_led_strip_pixels(.strip, Built.FrameType{}, 200);
                    switch (app.impl.last_event.?) {
                        .ledstrip_set_pixels => |event_value| {
                            try grt.std.testing.expectEqual(@as(u32, 11), event_value.source_id);
                            try grt.std.testing.expectEqual(@as(usize, 4), event_value.pixels.len);
                            try grt.std.testing.expectEqual(@as(u8, 200), event_value.brightness);
                        },
                        else => return error.UnexpectedMessage,
                    }
                    try app.set_led_strip_animated(.strip, Built.FrameType{}, 128, 42);
                    switch (app.impl.last_event.?) {
                        .ledstrip_set => |event_value| {
                            try grt.std.testing.expectEqual(@as(u32, 11), event_value.source_id);
                            try grt.std.testing.expectEqual(@as(u8, 128), event_value.brightness);
                            try grt.std.testing.expectEqual(@as(u32, 42), event_value.duration);
                        },
                        else => return error.UnexpectedMessage,
                    }
                    try app.set_led_strip_flash(.strip, Built.FrameType{}, 111, 5 * glib.time.duration.MilliSecond, 12 * glib.time.duration.MilliSecond);
                    switch (app.impl.last_event.?) {
                        .ledstrip_flash => |event_value| {
                            try grt.std.testing.expectEqual(@as(u32, 11), event_value.source_id);
                            try grt.std.testing.expectEqual(@as(u8, 111), event_value.brightness);
                            try grt.std.testing.expectEqual(@as(glib.time.duration.Duration, 5 * glib.time.duration.MilliSecond), event_value.duration);
                            try grt.std.testing.expectEqual(@as(glib.time.duration.Duration, 12 * glib.time.duration.MilliSecond), event_value.interval);
                        },
                        else => return error.UnexpectedMessage,
                    }
                    try app.set_led_strip_pingpong(.strip, Built.FrameType{}, Built.FrameType{}, 99, 9 * glib.time.duration.MilliSecond, 21 * glib.time.duration.MilliSecond);
                    switch (app.impl.last_event.?) {
                        .ledstrip_pingpong => |event_value| {
                            try grt.std.testing.expectEqual(@as(u32, 11), event_value.source_id);
                            try grt.std.testing.expectEqual(@as(u8, 99), event_value.brightness);
                            try grt.std.testing.expectEqual(@as(glib.time.duration.Duration, 9 * glib.time.duration.MilliSecond), event_value.duration);
                            try grt.std.testing.expectEqual(@as(glib.time.duration.Duration, 21 * glib.time.duration.MilliSecond), event_value.interval);
                        },
                        else => return error.UnexpectedMessage,
                    }
                    try app.set_led_strip_rotate(.strip, Built.FrameType{}, 77, 3 * glib.time.duration.MilliSecond, 7 * glib.time.duration.MilliSecond);
                    switch (app.impl.last_event.?) {
                        .ledstrip_rotate => |event_value| {
                            try grt.std.testing.expectEqual(@as(u32, 11), event_value.source_id);
                            try grt.std.testing.expectEqual(@as(u8, 77), event_value.brightness);
                            try grt.std.testing.expectEqual(@as(glib.time.duration.Duration, 3 * glib.time.duration.MilliSecond), event_value.duration);
                            try grt.std.testing.expectEqual(@as(glib.time.duration.Duration, 7 * glib.time.duration.MilliSecond), event_value.interval);
                        },
                        else => return error.UnexpectedMessage,
                    }
                    try app.push_route(.nav, .{ .screen_id = 9 });
                    switch (app.impl.last_event.?) {
                        .ui_route_push => |event_value| {
                            try grt.std.testing.expectEqual(@as(u32, 51), event_value.source_id);
                            try grt.std.testing.expectEqual(@as(u32, 9), event_value.item.screen_id);
                        },
                        else => return error.UnexpectedMessage,
                    }
                    try app.move_flow(.pairing, .forward, .start);
                    switch (app.impl.last_event.?) {
                        .ui_flow_move => |event_value| {
                            try grt.std.testing.expectEqual(@as(u32, 31), event_value.source_id);
                            try grt.std.testing.expect(event_value.direction == .forward);
                        },
                        else => return error.UnexpectedMessage,
                    }
                    try app.show_overlay(.loading, "sync", true);
                    switch (app.impl.last_event.?) {
                        .ui_overlay_show => |event_value| {
                            try grt.std.testing.expectEqual(@as(u32, 41), event_value.source_id);
                            try grt.std.testing.expectEqual(@as(u8, 4), event_value.name_len);
                            try grt.std.testing.expect(event_value.blocking);
                        },
                        else => return error.UnexpectedMessage,
                    }
                    try app.next_selection(.menu);
                    switch (app.impl.last_event.?) {
                        .ui_selection_next => |event_value| {
                            try grt.std.testing.expectEqual(@as(u32, 61), event_value.source_id);
                        },
                        else => return error.UnexpectedMessage,
                    }
                    try app.stop();
                    try grt.std.testing.expectError(error.NotStarted, app.release_grouped_button(.buttons));
                    app.deinit();
                }

                fn render_subscriber_runs_on_store_commit() !void {
                    const CounterStore = Store.Object.make(grt, struct {
                        value: u32 = 0,
                    }, .counter);

                    const Built = comptime blk: {
                        const AssemblerType = Assembler.make(grt, .{
                            .max_handles = 1,
                            .store = .{
                                .max_stores = 1,
                                .max_state_nodes = 4,
                                .max_store_refs = 4,
                                .max_depth = 4,
                            },
                        });
                        var next = AssemblerType.init();
                        next.setStore("counter", CounterStore);
                        next.setState("ui", .{"counter"});
                        next.addRender("counter_render", "ui");
                        const BuildConfig = next.BuildConfig();
                        const build_config: BuildConfig = .{};
                        break :blk next.build(build_config);
                    };

                    try grt.std.testing.expect(@hasField(Built.InitConfig, "counter_render"));
                    const render_field = comptime initConfigField(Built.InitConfig, "counter_render");
                    try grt.std.testing.expect(render_field.type == ?Built.RenderHook);
                    try grt.std.testing.expect(initConfigFieldDefaultValue(render_field) == null);

                    try grt.std.testing.expectError(error.MissingRenderHook, Built.init(.{
                        .allocator = grt.std.testing.allocator,
                        .initial_state = .{
                            .counter = .{},
                        },
                    }));

                    const RuntimeRender = struct {
                        call_count: usize = 0,
                        last_value: u32 = 0,

                        pub fn render(self_hook: *@This(), app: *Built.ImplType) !void {
                            self_hook.call_count += 1;
                            self_hook.last_value = app.runtime.store.stores.counter.get().value;
                        }
                    };
                    var runtime_render = RuntimeRender{};

                    var app = try Built.init(.{
                        .allocator = grt.std.testing.allocator,
                        .initial_state = .{
                            .counter = .{},
                        },
                        .counter_render = Built.RenderHook.init(&runtime_render),
                    });
                    defer app.deinit();

                    app.impl.runtime.store.stores.counter.patch(.{
                        .value = 7,
                    });

                    app.impl.runtime.store.stores.counter.tick();

                    try grt.std.testing.expectEqual(@as(usize, 1), runtime_render.call_count);
                    try grt.std.testing.expectEqual(@as(u32, 7), runtime_render.last_value);
                }

                fn initConfigField(
                    comptime InitConfig: type,
                    comptime field_name: []const u8,
                ) glib.std.builtin.Type.StructField {
                    inline for (@typeInfo(InitConfig).@"struct".fields) |field| {
                        if (glib.std.mem.eql(u8, field.name, field_name)) return field;
                    }

                    @compileError("missing InitConfig field '" ++ field_name ++ "'");
                }

                fn initConfigFieldDefaultValue(
                    comptime field: glib.std.builtin.Type.StructField,
                ) field.type {
                    const default_value_ptr = field.default_value_ptr orelse
                        @compileError("missing InitConfig field default value");
                    const default_value: *const field.type = @ptrCast(@alignCast(default_value_ptr));
                    return default_value.*;
                }
            };

            TestCase.make_uses_store_and_runtime_config() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.custom_pipeline_node_runs_before_store_tick() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.build_auto_wires_configured_reducers() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.manual_start_disables_auto_ticks_and_dispatch_processes_messages() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.add_grouped_button_records_registry_entry() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.add_led_strip_records_registry_entry() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.add_component_registries_record_entries() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.add_ui_registries_record_entries() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.build_without_optional_ui_still_returns_valid_app() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.component_duplicate_detector_rejects_reused_labels_and_ids() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.ui_source_ids_follow_configured_ids() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.built_app_exposes_registry_metadata() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.build_config_exposes_added_labels() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.build_returns_app_methods() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.render_subscriber_runs_on_store_commit() catch |err| {
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
