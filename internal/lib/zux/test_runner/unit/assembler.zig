const glib = @import("glib");

const Assembler = @import("../../Assembler.zig");
const Store = @import("../../Store.zig");
const Emitter = @import("../../pipeline/Emitter.zig");
const Message = @import("../../pipeline/Message.zig");
const registry_unique = @import("../../assembler/registry/unique.zig");
const overlay = @import("../../component/ui/overlay.zig");
const route = @import("../../component/ui/route.zig");
const selection = @import("../../component/ui/selection.zig");
const ui_flow = @import("../../component/ui/flow.zig");

const PairingFlow = blk: {
    var builder = ui_flow.Builder.init();
    builder.addNode("idle");
    builder.addNode("searching");
    builder.setInitial("idle");
    builder.addEdge("idle", "searching", "start");
    break :blk builder.build();
};

pub fn make(comptime lib: type, comptime Channel: fn (type) type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            const testing = lib.testing;

            const TestCase = struct {
                fn make_uses_store_and_node_builder_config() !void {
                    const AssemblerType = Assembler.make(lib, .{
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
                    }, Channel);

                    const assembler = comptime AssemblerType.init();
                    try testing.expect(AssemblerType.Lib == lib);
                    try testing.expectEqual(@as(usize, 8), assembler.store_builder.store_bindings.len);
                    try testing.expectEqual(@as(usize, 32), assembler.store_builder.state_bindings.len);
                    try testing.expectEqual(@as(usize, 24), assembler.node_builder.ops.len);
                    try testing.expectEqual(AssemblerType.Config.max_reducers, assembler.reducer_bindings.len);
                    try testing.expectEqual(@as(usize, 4), assembler.adc_button_registry.periphs.len);
                    try testing.expectEqual(@as(usize, 6), assembler.gpio_button_registry.periphs.len);
                    try testing.expectEqual(@as(usize, 2), assembler.imu_registry.periphs.len);
                    try testing.expectEqual(@as(usize, 3), assembler.ledstrip_registry.periphs.len);
                    try testing.expectEqual(@as(usize, 2), assembler.modem_registry.periphs.len);
                    try testing.expectEqual(@as(usize, 2), assembler.nfc_registry.periphs.len);
                    try testing.expectEqual(@as(usize, 2), assembler.wifi_sta_registry.periphs.len);
                    try testing.expectEqual(@as(usize, 2), assembler.wifi_ap_registry.periphs.len);
                    try testing.expectEqual(@as(usize, 2), assembler.flow_registry.periphs.len);
                    try testing.expectEqual(@as(usize, 2), assembler.overlay_registry.periphs.len);
                    try testing.expectEqual(@as(usize, 2), assembler.router_registry.periphs.len);
                    try testing.expectEqual(@as(usize, 2), assembler.selection_registry.periphs.len);
                    try testing.expectEqual(@as(usize, 0), assembler.store_builder.store_count);
                    try testing.expectEqual(@as(usize, 0), assembler.node_builder.len);
                    try testing.expectEqual(@as(usize, 0), assembler.adc_button_registry.len);
                    try testing.expectEqual(@as(usize, 0), assembler.gpio_button_registry.len);
                    try testing.expectEqual(@as(usize, 0), assembler.imu_registry.len);
                    try testing.expectEqual(@as(usize, 0), assembler.ledstrip_registry.len);
                    try testing.expectEqual(@as(usize, 0), assembler.modem_registry.len);
                    try testing.expectEqual(@as(usize, 0), assembler.nfc_registry.len);
                    try testing.expectEqual(@as(usize, 0), assembler.wifi_sta_registry.len);
                    try testing.expectEqual(@as(usize, 0), assembler.wifi_ap_registry.len);
                    try testing.expectEqual(@as(usize, 0), assembler.flow_registry.len);
                    try testing.expectEqual(@as(usize, 0), assembler.overlay_registry.len);
                    try testing.expectEqual(@as(usize, 0), assembler.router_registry.len);
                    try testing.expectEqual(@as(usize, 0), assembler.selection_registry.len);
                    try testing.expectEqual(@as(usize, 0), assembler.reducer_count);
                }

                fn reexports_store_and_node_builder_methods() !void {
                    const WifiStore = struct { enabled: bool = false };
                    const ReducerFactory = struct {
                        fn factory(
                            comptime StoresType: type,
                            comptime MessageType: type,
                            comptime EmitterType: type,
                        ) Store.Reducer.ReducerFnType(StoresType, MessageType, EmitterType) {
                            return struct {
                                fn reduce(stores: *StoresType, message: MessageType, emit: EmitterType) !usize {
                                    _ = stores;
                                    _ = message;
                                    _ = emit;
                                    return 0;
                                }
                            }.reduce;
                        }
                    }.factory;

                    const assembler = comptime blk: {
                        const AssemblerType = Assembler.make(lib, .{}, Channel);
                        var next = AssemblerType.init();
                        next.setStore(.wifi, WifiStore);
                        next.setState("ui/home", .{.wifi});
                        next.addReducer(.wifi_reducer, ReducerFactory);
                        next.addNode(.root);
                        next.beginSwitch();
                        next.addCase(.tick);
                        next.addNode(.tick_node);
                        next.endSwitch();
                        break :blk next;
                    };

                    try testing.expectEqual(@as(usize, 1), assembler.store_builder.store_count);
                    try testing.expectEqual(@as(usize, 1), assembler.store_builder.state_binding_count);
                    try testing.expectEqual(@as(usize, 2), assembler.node_builder.tag_len);
                    try testing.expectEqual(@as(usize, 1), assembler.node_builder.switch_count);
                    try testing.expectEqual(@as(usize, 5), assembler.node_builder.len);
                    try testing.expectEqual(@as(usize, 1), assembler.reducer_count);
                    try testing.expect(lib.mem.eql(u8, "wifi_reducer", assembler.reducer_bindings[0].name));
                    try testing.expectEqual(@as(usize, 0), assembler.adc_button_registry.len);
                    try testing.expectEqual(@as(usize, 0), assembler.gpio_button_registry.len);
                    try testing.expectEqual(@as(usize, 0), assembler.ledstrip_registry.len);
                }

                fn build_auto_wires_configured_reducers() !void {
                    const CounterState = struct {
                        ticks: usize = 0,
                    };
                    const CounterStore = Store.Object.make(lib, CounterState, .counter);
                    const CounterReducerFactory = struct {
                        fn factory(
                            comptime StoresType: type,
                            comptime MessageType: type,
                            comptime EmitterType: type,
                        ) Store.Reducer.ReducerFnType(StoresType, MessageType, EmitterType) {
                            return struct {
                                fn reduce(stores: *StoresType, message: MessageType, emit: EmitterType) !usize {
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
                                        else => return 0,
                                    }
                                }
                            }.reduce;
                        }
                    }.factory;

                    const Built = comptime blk: {
                        const AssemblerType = Assembler.make(lib, .{
                            .max_reducers = 2,
                        }, Channel);
                        var next = AssemblerType.init();
                        next.setStore(.counter, CounterStore);
                        next.addReducer(.counter, CounterReducerFactory);
                        const BuildConfig = next.BuildConfig();
                        const build_config: BuildConfig = .{};
                        break :blk next.build(build_config);
                    };

                    try testing.expect(@hasField(Built.Root.Config, "counter"));

                    var app = try Built.init(.{
                        .allocator = testing.allocator,
                    });
                    defer app.deinit();

                    try testing.expectEqual(@as(usize, 0), app.store.stores.counter.get().ticks);
                    _ = try app.impl.runtime.root.process(.{
                        .origin = .manual,
                        .timestamp_ns = 0,
                        .body = .{
                            .tick = .{
                                .seq = 1,
                            },
                        },
                    });
                    try testing.expectEqual(@as(usize, 1), app.store.stores.counter.get().ticks);
                }

                fn manual_start_disables_auto_ticks_and_dispatch_processes_messages() !void {
                    const CounterState = struct {
                        ticks: usize = 0,
                        pressed: bool = false,
                    };
                    const CounterStore = Store.Object.make(lib, CounterState, .counter);
                    const CounterReducerFactory = struct {
                        fn factory(
                            comptime StoresType: type,
                            comptime MessageType: type,
                            comptime EmitterType: type,
                        ) Store.Reducer.ReducerFnType(StoresType, MessageType, EmitterType) {
                            return struct {
                                fn reduce(stores: *StoresType, message: MessageType, emit: EmitterType) !usize {
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
                            }.reduce;
                        }
                    }.factory;

                    const Built = comptime blk: {
                        const AssemblerType = Assembler.make(lib, .{
                            .max_reducers = 1,
                        }, Channel);
                        var next = AssemblerType.init();
                        next.setStore(.counter, CounterStore);
                        next.addReducer(.counter, CounterReducerFactory);
                        const BuildConfig = next.BuildConfig();
                        const build_config: BuildConfig = .{};
                        break :blk next.build(build_config);
                    };

                    var app = try Built.init(.{
                        .allocator = testing.allocator,
                    });
                    defer app.deinit();

                    try app.start(.{ .ticker = .manual });
                    lib.Thread.sleep(3 * lib.time.ns_per_ms);
                    try testing.expectEqual(@as(usize, 0), app.store.stores.counter.get().ticks);

                    try app.dispatch(.{
                        .origin = .timer,
                        .timestamp_ns = 0,
                        .body = .{
                            .tick = .{
                                .seq = 1,
                            },
                        },
                    });
                    try testing.expectEqual(@as(usize, 1), app.store.stores.counter.get().ticks);

                    try app.dispatch(.{
                        .origin = .manual,
                        .timestamp_ns = 0,
                        .body = .{
                            .raw_single_button = .{
                                .source_id = 7,
                                .pressed = true,
                            },
                        },
                    });
                    switch (app.impl.last_event.?) {
                        .raw_single_button => |event_value| {
                            try testing.expectEqual(@as(u32, 7), event_value.source_id);
                            try testing.expect(event_value.pressed);
                        },
                        else => return error.UnexpectedMessage,
                    }

                    try app.dispatch(.{
                        .origin = .timer,
                        .timestamp_ns = 1,
                        .body = .{
                            .tick = .{
                                .seq = 2,
                            },
                        },
                    });
                    try testing.expectEqual(@as(usize, 2), app.store.stores.counter.get().ticks);
                    try testing.expect(app.store.stores.counter.get().pressed);

                    try app.stop();
                    try testing.expectError(error.NotStarted, app.dispatch(.{
                        .origin = .timer,
                        .timestamp_ns = 0,
                        .body = .{
                            .tick = .{
                                .seq = 2,
                            },
                        },
                    }));
                }

                fn add_grouped_button_records_registry_entry() !void {
                    const assembler = comptime blk: {
                        const AssemblerType = Assembler.make(lib, .{
                            .max_adc_buttons = 2,
                        }, Channel);
                        var next = AssemblerType.init();
                        next.addGroupedButton(.buttons, 7, 3);
                        break :blk next;
                    };

                    try testing.expectEqual(@as(usize, 1), assembler.adc_button_registry.len);
                    try testing.expectEqual(@as(u32, 7), assembler.adc_button_registry.periphs[0].id);
                    try testing.expectEqual(@as(usize, 3), assembler.adc_button_registry.periphs[0].button_count);
                }

                fn build_config_exposes_added_labels() !void {
                    const BuildConfig = comptime blk: {
                        const AssemblerType = Assembler.make(lib, .{
                            .max_adc_buttons = 2,
                            .max_imu = 1,
                            .max_led_strips = 1,
                            .max_modem = 1,
                            .max_nfc = 1,
                            .max_wifi_sta = 1,
                            .max_wifi_ap = 1,
                        }, Channel);
                        var next = AssemblerType.init();
                        next.addGroupedButton(.buttons, 7, 3);
                        next.addImu(.imu, 13);
                        next.addLedStrip(.strip, 9, 4);
                        next.addModem(.modem, 15);
                        next.addNfc(.nfc, 17);
                        next.addWifiSta(.sta, 19);
                        next.addWifiAp(.ap, 21);
                        break :blk next.BuildConfig();
                    };

                    try testing.expect(@hasField(BuildConfig, "buttons"));
                    try testing.expect(@hasField(BuildConfig, "imu"));
                    try testing.expect(@hasField(BuildConfig, "strip"));
                    try testing.expect(@hasField(BuildConfig, "modem"));
                    try testing.expect(@hasField(BuildConfig, "nfc"));
                    try testing.expect(@hasField(BuildConfig, "sta"));
                    try testing.expect(@hasField(BuildConfig, "ap"));
                }

                fn add_led_strip_records_registry_entry() !void {
                    const assembler = comptime blk: {
                        const AssemblerType = Assembler.make(lib, .{
                            .max_led_strips = 2,
                        }, Channel);
                        var next = AssemblerType.init();
                        next.addLedStrip(.strip, 9, 4);
                        break :blk next;
                    };

                    try testing.expectEqual(@as(usize, 1), assembler.ledstrip_registry.len);
                    try testing.expectEqual(@as(u32, 9), assembler.ledstrip_registry.periphs[0].id);
                    try testing.expectEqual(@as(usize, 4), assembler.ledstrip_registry.periphs[0].pixel_count);
                }

                fn add_component_registries_record_entries() !void {
                    const assembler = comptime blk: {
                        const AssemblerType = Assembler.make(lib, .{
                            .max_imu = 1,
                            .max_modem = 1,
                            .max_nfc = 1,
                            .max_wifi_sta = 1,
                            .max_wifi_ap = 1,
                        }, Channel);
                        var next = AssemblerType.init();
                        next.addImu(.imu, 13);
                        next.addModem(.modem, 15);
                        next.addNfc(.nfc, 17);
                        next.addWifiSta(.sta, 19);
                        next.addWifiAp(.ap, 21);
                        break :blk next;
                    };

                    try testing.expectEqual(@as(usize, 1), assembler.imu_registry.len);
                    try testing.expectEqual(@as(u32, 13), assembler.imu_registry.periphs[0].id);
                    try testing.expectEqual(@as(usize, 1), assembler.modem_registry.len);
                    try testing.expectEqual(@as(u32, 15), assembler.modem_registry.periphs[0].id);
                    try testing.expectEqual(@as(usize, 1), assembler.nfc_registry.len);
                    try testing.expectEqual(@as(u32, 17), assembler.nfc_registry.periphs[0].id);
                    try testing.expectEqual(@as(usize, 1), assembler.wifi_sta_registry.len);
                    try testing.expectEqual(@as(u32, 19), assembler.wifi_sta_registry.periphs[0].id);
                    try testing.expectEqual(@as(usize, 1), assembler.wifi_ap_registry.len);
                    try testing.expectEqual(@as(u32, 21), assembler.wifi_ap_registry.periphs[0].id);
                }

                fn add_ui_registries_record_entries() !void {
                    const assembler = comptime blk: {
                        const AssemblerType = Assembler.make(lib, .{
                            .max_flows = 1,
                            .max_overlays = 1,
                            .max_routers = 1,
                            .max_selections = 1,
                        }, Channel);
                        var next = AssemblerType.init();
                        next.addFlow(.pairing, 31, PairingFlow);
                        next.addOverlay(.loading, 41, overlay.State{});
                        next.addRouter(.nav, 51, route.Router.Item{
                            .screen_id = 5,
                            .arg0 = 1,
                        });
                        next.addSelection(.menu, 61, selection.State{
                            .count = 3,
                            .loop = false,
                        });
                        break :blk next;
                    };

                    try testing.expectEqual(@as(usize, 1), assembler.flow_registry.len);
                    try testing.expectEqual(@as(u32, 31), assembler.flow_registry.periphs[0].id);
                    try testing.expect(@hasDecl(assembler.flow_registry.periphs[0].FlowType, "Reducer"));
                    try testing.expectEqual(@as(usize, 1), assembler.overlay_registry.len);
                    try testing.expectEqual(@as(u32, 41), assembler.overlay_registry.periphs[0].id);
                    try testing.expect(!assembler.overlay_registry.periphs[0].initial_state.visible);
                    try testing.expectEqual(@as(usize, 1), assembler.router_registry.len);
                    try testing.expectEqual(@as(u32, 51), assembler.router_registry.periphs[0].id);
                    try testing.expectEqual(@as(u32, 5), assembler.router_registry.periphs[0].initial_item.screen_id);
                    try testing.expectEqual(@as(usize, 1), assembler.selection_registry.len);
                    try testing.expectEqual(@as(u32, 61), assembler.selection_registry.periphs[0].id);
                    try testing.expectEqual(@as(usize, 3), assembler.selection_registry.periphs[0].initial_state.count);
                    try testing.expectEqual(@as(usize, 3), assembler.store_builder.store_count);
                }

                fn component_duplicate_detector_rejects_reused_labels_and_ids() !void {
                    const assembler = comptime blk: {
                        const AssemblerType = Assembler.make(lib, .{
                            .max_gpio_buttons = 1,
                            .max_flows = 1,
                            .max_overlays = 1,
                            .max_routers = 1,
                            .max_selections = 1,
                        }, Channel);
                        var next = AssemblerType.init();
                        next.addSingleButton(.shared, 7);
                        next.addFlow(.pairing, 31, PairingFlow);
                        next.addOverlay(.loading, 41, overlay.State{});
                        next.addRouter(.nav, 51, .{ .screen_id = 1 });
                        next.addSelection(.menu, 61, selection.State{ .count = 2 });
                        break :blk next;
                    };

                    try testing.expect(!registry_unique.isUniqueAcross(
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
                    try testing.expect(!registry_unique.isUniqueAcross(
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
                    try testing.expect(registry_unique.isUniqueAcross(
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
                        const AssemblerType = Assembler.make(lib, .{}, Channel);
                        var next = AssemblerType.init();
                        const BuildConfig = next.BuildConfig();
                        const build_config: BuildConfig = .{};
                        break :blk next.build(build_config);
                    };

                    try testing.expectEqual(@as(usize, 0), @typeInfo(Built.FlowLabel).@"enum".fields.len);
                    try testing.expectEqual(@as(usize, 0), @typeInfo(Built.RouterLabel).@"enum".fields.len);
                    try testing.expectEqual(@as(usize, 0), @typeInfo(Built.OverlayLabel).@"enum".fields.len);
                    try testing.expectEqual(@as(usize, 0), @typeInfo(Built.SelectionLabel).@"enum".fields.len);

                    var app = try Built.init(.{
                        .allocator = testing.allocator,
                    });
                    try app.start(.{});
                    try app.stop();
                    app.deinit();
                }

                fn ui_source_ids_follow_configured_ids() !void {
                    const Built = comptime blk: {
                        const AssemblerType = Assembler.make(lib, .{
                            .max_flows = 2,
                            .max_overlays = 2,
                            .max_routers = 2,
                            .max_selections = 2,
                        }, Channel);
                        var next = AssemblerType.init();
                        next.addFlow(.pairing_a, 31, PairingFlow);
                        next.addFlow(.pairing_b, 32, PairingFlow);
                        next.addOverlay(.loading_a, 41, overlay.State{});
                        next.addOverlay(.loading_b, 42, overlay.State{});
                        next.addRouter(.nav_a, 51, route.Router.Item{
                            .screen_id = 1,
                        });
                        next.addRouter(.nav_b, 52, route.Router.Item{
                            .screen_id = 2,
                        });
                        next.addSelection(.menu_a, 61, selection.State{
                            .count = 2,
                        });
                        next.addSelection(.menu_b, 62, selection.State{
                            .count = 2,
                        });

                        const BuildConfig = next.BuildConfig();
                        const build_config: BuildConfig = .{};
                        break :blk next.build(build_config);
                    };

                    var app = try Built.init(.{
                        .allocator = testing.allocator,
                    });
                    defer app.deinit();

                    try app.start(.{});
                    defer app.stop() catch {};

                    try app.push_route(.nav_a, .{ .screen_id = 8 });
                    switch (app.impl.last_event.?) {
                        .ui_route_push => |event_value| {
                            try testing.expectEqual(@as(u32, 51), event_value.source_id);
                        },
                        else => return error.UnexpectedMessage,
                    }

                    try app.push_route(.nav_b, .{ .screen_id = 9 });
                    switch (app.impl.last_event.?) {
                        .ui_route_push => |event_value| {
                            try testing.expectEqual(@as(u32, 52), event_value.source_id);
                        },
                        else => return error.UnexpectedMessage,
                    }

                    try app.move_flow(.pairing_a, .forward, .start);
                    switch (app.impl.last_event.?) {
                        .ui_flow_move => |event_value| {
                            try testing.expectEqual(@as(u32, 31), event_value.source_id);
                        },
                        else => return error.UnexpectedMessage,
                    }

                    try app.move_flow(.pairing_b, .forward, .start);
                    switch (app.impl.last_event.?) {
                        .ui_flow_move => |event_value| {
                            try testing.expectEqual(@as(u32, 32), event_value.source_id);
                        },
                        else => return error.UnexpectedMessage,
                    }

                    try app.reset_flow(.pairing_b);
                    switch (app.impl.last_event.?) {
                        .ui_flow_reset => |event_value| {
                            try testing.expectEqual(@as(u32, 32), event_value.source_id);
                        },
                        else => return error.UnexpectedMessage,
                    }

                    try app.show_overlay(.loading_a, "base", false);
                    switch (app.impl.last_event.?) {
                        .ui_overlay_show => |event_value| {
                            try testing.expectEqual(@as(u32, 41), event_value.source_id);
                        },
                        else => return error.UnexpectedMessage,
                    }

                    try app.show_overlay(.loading_b, "busy", true);
                    switch (app.impl.last_event.?) {
                        .ui_overlay_show => |event_value| {
                            try testing.expectEqual(@as(u32, 42), event_value.source_id);
                        },
                        else => return error.UnexpectedMessage,
                    }

                    try app.hide_overlay(.loading_b);
                    switch (app.impl.last_event.?) {
                        .ui_overlay_hide => |event_value| {
                            try testing.expectEqual(@as(u32, 42), event_value.source_id);
                        },
                        else => return error.UnexpectedMessage,
                    }

                    try app.next_selection(.menu_a);
                    switch (app.impl.last_event.?) {
                        .ui_selection_next => |event_value| {
                            try testing.expectEqual(@as(u32, 61), event_value.source_id);
                        },
                        else => return error.UnexpectedMessage,
                    }

                    try app.next_selection(.menu_b);
                    switch (app.impl.last_event.?) {
                        .ui_selection_next => |event_value| {
                            try testing.expectEqual(@as(u32, 62), event_value.source_id);
                        },
                        else => return error.UnexpectedMessage,
                    }

                    try app.reset_selection(.menu_b);
                    switch (app.impl.last_event.?) {
                        .ui_selection_reset => |event_value| {
                            try testing.expectEqual(@as(u32, 62), event_value.source_id);
                        },
                        else => return error.UnexpectedMessage,
                    }
                }

                fn built_app_exposes_registry_metadata() !void {
                    const Built = comptime blk: {
                        const AssemblerType = Assembler.make(lib, .{
                            .max_adc_buttons = 1,
                            .max_flows = 1,
                            .max_overlays = 1,
                            .max_routers = 1,
                            .max_selections = 1,
                        }, Channel);
                        var next = AssemblerType.init();
                        next.addGroupedButton(.buttons, 7, 3);
                        next.addFlow(.pairing, 31, PairingFlow);
                        next.addOverlay(.loading, 41, overlay.State{});
                        next.addRouter(.nav, 51, .{ .screen_id = 5 });
                        next.addSelection(.menu, 61, .{ .count = 2, .loop = false });

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

                    try testing.expect(@hasDecl(Built, "Registries"));
                    try testing.expect(@hasDecl(Built, "registries"));
                    try testing.expectEqual(@as(usize, 1), Built.registries.adc_button.len);
                    try testing.expectEqual(@as(usize, 1), Built.registries.flow.len);
                    try testing.expectEqual(@as(usize, 1), Built.registries.overlay.len);
                    try testing.expectEqual(@as(usize, 1), Built.registries.router.len);
                    try testing.expectEqual(@as(usize, 1), Built.registries.selection.len);
                    try testing.expectEqual(@as(u32, 7), meta.grouped_button_id);
                    try testing.expectEqual(@as(u32, 31), meta.flow_id);
                    try testing.expectEqual(@as(u32, 41), meta.overlay_id);
                    try testing.expectEqual(@as(u32, 51), meta.router_id);
                    try testing.expectEqual(@as(u32, 61), meta.selection_id);
                }

                fn build_returns_app_methods() !void {
                    const drivers = @import("drivers");
                    const ledstrip_mod = @import("ledstrip");

                    const Built = comptime blk: {
                        const AssemblerType = Assembler.make(lib, .{
                            .max_adc_buttons = 2,
                            .max_led_strips = 1,
                            .pipeline = .{
                                .tick_interval_ns = 7 * lib.time.ns_per_ms,
                                .spawn_config = .{
                                    .stack_size = 64 * 1024,
                                },
                            },
                        }, Channel);
                        var next = AssemblerType.init();
                        next.addGroupedButton(.buttons, 7, 3);
                        next.addLedStrip(.strip, 11, 4);
                        next.addFlow(.pairing, 31, PairingFlow);
                        next.addOverlay(.loading, 41, overlay.State{});
                        next.addRouter(.nav, 51, route.Router.Item{
                            .screen_id = 5,
                        });
                        next.addSelection(.menu, 61, selection.State{
                            .count = 2,
                            .loop = false,
                        });

                        const BuildConfig = next.BuildConfig();
                        const build_config: BuildConfig = .{
                            .buttons = @import("drivers").button.Grouped,
                            .strip = ledstrip_mod.LedStrip,
                        };
                        break :blk next.build(build_config);
                    };

                    try testing.expect(@hasDecl(Built, "PeriphLabel"));
                    try testing.expect(@hasDecl(Built, "InitConfig"));
                    try testing.expect(@hasDecl(Built, "start"));
                    try testing.expect(@hasDecl(Built, "stop"));
                    try testing.expect(@hasDecl(Built, "press_single_button"));
                    try testing.expect(@hasDecl(Built, "release_single_button"));
                    try testing.expect(@hasDecl(Built, "press_grouped_button"));
                    try testing.expect(@hasDecl(Built, "release_grouped_button"));
                    try testing.expect(@hasDecl(Built, "set_led_strip_animated"));
                    try testing.expect(@hasDecl(Built, "set_led_strip_pixels"));
                    try testing.expect(@hasDecl(Built, "set_led_strip_flash"));
                    try testing.expect(@hasDecl(Built, "set_led_strip_pingpong"));
                    try testing.expect(@hasDecl(Built, "set_led_strip_rotate"));
                    try testing.expect(@hasDecl(Built, "router"));
                    try testing.expect(@hasDecl(Built, "push_route"));
                    try testing.expect(@hasDecl(Built, "move_flow"));
                    try testing.expect(@hasDecl(Built, "available_moves"));
                    try testing.expect(@hasDecl(Built, "show_overlay"));
                    try testing.expect(@hasDecl(Built, "next_selection"));
                    try testing.expectEqual(@as(usize, 1), Built.poller_count);
                    try testing.expectEqual(@as(usize, 4), Built.pixel_count);
                    try testing.expectEqual(@as(usize, 4), Built.LedStrip(.strip).pixel_count);
                    try testing.expectEqual(@as(usize, 4), Built.LedStrip(.strip).FrameType.pixel_count);
                    try testing.expectEqual(@as(u64, 7 * lib.time.ns_per_ms), Built.ImplType.pipeline_config.tick_interval_ns);
                    if (@hasField(@TypeOf(Built.ImplType.pipeline_config.spawn_config), "stack_size")) {
                        try testing.expectEqual(
                            @as(usize, 64 * 1024),
                            Built.ImplType.pipeline_config.spawn_config.stack_size,
                        );
                    }
                    try testing.expectEqualStrings("buttons", @typeInfo(Built.PeriphLabel).@"enum".fields[0].name);
                    try testing.expect(@hasField(Built.Store.Stores, "buttons"));
                    try testing.expect(@hasField(Built.Store.Stores, "strip"));
                    try testing.expect(@hasField(Built.Store.Stores, "pairing"));
                    try testing.expect(@hasField(Built.Store.Stores, "loading"));
                    try testing.expect(@hasField(Built.Store.Stores, "nav"));
                    try testing.expect(@hasField(Built.Store.Stores, "menu"));

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
                        .allocator = testing.allocator,
                        .buttons = drivers.button.Grouped.init(MockGrouped, &mock_grouped),
                        .strip = dummy_strip.handle(),
                    });
                    try app.start(.{});
                    try testing.expectEqual(@as(u32, 5), app.router(.nav).currentPage());
                    const moves = try app.available_moves(.pairing, testing.allocator);
                    defer testing.allocator.free(moves);
                    try testing.expectEqual(@as(usize, 1), moves.len);
                    try testing.expect(moves[0].direction == .forward);
                    try testing.expect(moves[0].edge == .start);
                    try testing.expectError(error.InvalidPeriphKind, app.press_single_button(.buttons));
                    try testing.expectError(error.InvalidPeriphKind, app.release_single_button(.buttons));
                    try testing.expectError(error.InvalidPeriphKind, app.set_led_strip_pixels(.buttons, Built.FrameType{}, 1));
                    try app.press_grouped_button(.buttons, 1);
                    switch (app.impl.last_event.?) {
                        .raw_grouped_button => |event_value| {
                            try testing.expectEqual(@as(u32, 7), event_value.source_id);
                            try testing.expectEqual(@as(?u32, 1), event_value.button_id);
                            try testing.expect(event_value.pressed);
                        },
                        else => return error.UnexpectedMessage,
                    }
                    try app.release_grouped_button(.buttons);
                    switch (app.impl.last_event.?) {
                        .raw_grouped_button => |event_value| {
                            try testing.expectEqual(@as(u32, 7), event_value.source_id);
                            try testing.expectEqual(@as(?u32, 1), event_value.button_id);
                            try testing.expect(!event_value.pressed);
                        },
                        else => return error.UnexpectedMessage,
                    }
                    try app.set_led_strip_pixels(.strip, Built.FrameType{}, 200);
                    switch (app.impl.last_event.?) {
                        .ledstrip_set_pixels => |event_value| {
                            try testing.expectEqual(@as(u32, 11), event_value.source_id);
                            try testing.expectEqual(@as(usize, 4), event_value.pixels.len);
                            try testing.expectEqual(@as(u8, 200), event_value.brightness);
                        },
                        else => return error.UnexpectedMessage,
                    }
                    try app.set_led_strip_animated(.strip, Built.FrameType{}, 128, 42);
                    switch (app.impl.last_event.?) {
                        .ledstrip_set => |event_value| {
                            try testing.expectEqual(@as(u32, 11), event_value.source_id);
                            try testing.expectEqual(@as(u8, 128), event_value.brightness);
                            try testing.expectEqual(@as(u32, 42), event_value.duration);
                        },
                        else => return error.UnexpectedMessage,
                    }
                    try app.set_led_strip_flash(.strip, Built.FrameType{}, 111, 5_000_000, 12_000_000);
                    switch (app.impl.last_event.?) {
                        .ledstrip_flash => |event_value| {
                            try testing.expectEqual(@as(u32, 11), event_value.source_id);
                            try testing.expectEqual(@as(u8, 111), event_value.brightness);
                            try testing.expectEqual(@as(u64, 5_000_000), event_value.duration_ns);
                            try testing.expectEqual(@as(u64, 12_000_000), event_value.interval_ns);
                        },
                        else => return error.UnexpectedMessage,
                    }
                    try app.set_led_strip_pingpong(.strip, Built.FrameType{}, Built.FrameType{}, 99, 9_000_000, 21_000_000);
                    switch (app.impl.last_event.?) {
                        .ledstrip_pingpong => |event_value| {
                            try testing.expectEqual(@as(u32, 11), event_value.source_id);
                            try testing.expectEqual(@as(u8, 99), event_value.brightness);
                            try testing.expectEqual(@as(u64, 9_000_000), event_value.duration_ns);
                            try testing.expectEqual(@as(u64, 21_000_000), event_value.interval_ns);
                        },
                        else => return error.UnexpectedMessage,
                    }
                    try app.set_led_strip_rotate(.strip, Built.FrameType{}, 77, 3_000_000, 7_000_000);
                    switch (app.impl.last_event.?) {
                        .ledstrip_rotate => |event_value| {
                            try testing.expectEqual(@as(u32, 11), event_value.source_id);
                            try testing.expectEqual(@as(u8, 77), event_value.brightness);
                            try testing.expectEqual(@as(u64, 3_000_000), event_value.duration_ns);
                            try testing.expectEqual(@as(u64, 7_000_000), event_value.interval_ns);
                        },
                        else => return error.UnexpectedMessage,
                    }
                    try app.push_route(.nav, .{ .screen_id = 9 });
                    switch (app.impl.last_event.?) {
                        .ui_route_push => |event_value| {
                            try testing.expectEqual(@as(u32, 51), event_value.source_id);
                            try testing.expectEqual(@as(u32, 9), event_value.item.screen_id);
                        },
                        else => return error.UnexpectedMessage,
                    }
                    try app.move_flow(.pairing, .forward, .start);
                    switch (app.impl.last_event.?) {
                        .ui_flow_move => |event_value| {
                            try testing.expectEqual(@as(u32, 31), event_value.source_id);
                            try testing.expect(event_value.direction == .forward);
                        },
                        else => return error.UnexpectedMessage,
                    }
                    try app.show_overlay(.loading, "sync", true);
                    switch (app.impl.last_event.?) {
                        .ui_overlay_show => |event_value| {
                            try testing.expectEqual(@as(u32, 41), event_value.source_id);
                            try testing.expectEqual(@as(u8, 4), event_value.name_len);
                            try testing.expect(event_value.blocking);
                        },
                        else => return error.UnexpectedMessage,
                    }
                    try app.next_selection(.menu);
                    switch (app.impl.last_event.?) {
                        .ui_selection_next => |event_value| {
                            try testing.expectEqual(@as(u32, 61), event_value.source_id);
                        },
                        else => return error.UnexpectedMessage,
                    }
                    try app.stop();
                    try testing.expectError(error.NotStarted, app.release_grouped_button(.buttons));
                    app.deinit();
                }

                fn render_subscriber_runs_on_store_commit() !void {
                    const CounterStore = Store.Object.make(lib, struct {
                        value: u32 = 0,
                    }, .counter);
                    const RenderNamespace = struct {
                        var call_count: usize = 0;
                        var last_value: u32 = 0;

                        fn factory(comptime Built: type, comptime path: []const u8) *const fn (*Built) anyerror!void {
                            _ = path;

                            return struct {
                                fn render(app: *Built) !void {
                                    call_count += 1;
                                    last_value = app.runtime.store.stores.counter.get().value;
                                }
                            }.render;
                        }
                    };
                    const RenderFactory = RenderNamespace.factory;

                    const Built = comptime blk: {
                        const AssemblerType = Assembler.make(lib, .{
                            .max_handles = 1,
                            .store = .{
                                .max_stores = 1,
                                .max_state_nodes = 4,
                                .max_store_refs = 4,
                                .max_depth = 4,
                            },
                        }, Channel);
                        var next = AssemblerType.init();
                        next.setStore(.counter, CounterStore);
                        next.setState("ui", .{.counter});
                        next.addRender("ui", RenderFactory);
                        const BuildConfig = next.BuildConfig();
                        const build_config: BuildConfig = .{};
                        break :blk next.build(build_config);
                    };

                    RenderNamespace.call_count = 0;
                    RenderNamespace.last_value = 0;

                    var app = try Built.init(.{
                        .allocator = testing.allocator,
                    });
                    defer app.deinit();

                    app.impl.runtime.store.stores.counter.patch(.{
                        .value = 7,
                    });
                    try testing.expectEqual(@as(usize, 0), RenderNamespace.call_count);

                    app.impl.runtime.store.stores.counter.tick();

                    try testing.expectEqual(@as(usize, 1), RenderNamespace.call_count);
                    try testing.expectEqual(@as(u32, 7), RenderNamespace.last_value);
                }
            };

            TestCase.make_uses_store_and_node_builder_config() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.reexports_store_and_node_builder_methods() catch |err| {
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

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
