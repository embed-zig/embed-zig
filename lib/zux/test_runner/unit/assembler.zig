const testing_api = @import("testing");

const Assembler = @import("../../Assembler.zig");

pub fn make(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            const testing = lib.testing;

            const TestCase = struct {
                fn make_uses_store_and_node_builder_config() !void {
                    const embed_std = @import("embed_std");
                    const AssemblerType = Assembler.make(embed_std.std, .{
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
                    }, Channel);

                    const assembler = comptime AssemblerType.init();
                    try testing.expect(AssemblerType.Lib == embed_std.std);
                    try testing.expectEqual(@as(usize, 8), assembler.store_builder.store_bindings.len);
                    try testing.expectEqual(@as(usize, 32), assembler.store_builder.state_bindings.len);
                    try testing.expectEqual(@as(usize, 24), assembler.node_builder.ops.len);
                    try testing.expectEqual(@as(usize, 4), assembler.adc_button_registry.periphs.len);
                    try testing.expectEqual(@as(usize, 6), assembler.gpio_button_registry.periphs.len);
                    try testing.expectEqual(@as(usize, 2), assembler.imu_registry.periphs.len);
                    try testing.expectEqual(@as(usize, 3), assembler.ledstrip_registry.periphs.len);
                    try testing.expectEqual(@as(usize, 2), assembler.modem_registry.periphs.len);
                    try testing.expectEqual(@as(usize, 2), assembler.nfc_registry.periphs.len);
                    try testing.expectEqual(@as(usize, 2), assembler.wifi_sta_registry.periphs.len);
                    try testing.expectEqual(@as(usize, 2), assembler.wifi_ap_registry.periphs.len);
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
                }

                fn reexports_store_and_node_builder_methods() !void {
                    const embed_std = @import("embed_std");

                    const WifiStore = struct { enabled: bool = false };

                    const assembler = comptime blk: {
                        const AssemblerType = Assembler.make(embed_std.std, .{}, Channel);
                        var next = AssemblerType.init();
                        next.setStore(.wifi, WifiStore);
                        next.setState("ui/home", .{.wifi});
                        next.node(.root);
                        next.beginSwitch();
                        next.case(.tick);
                        next.node(.tick_node);
                        next.endSwitch();
                        break :blk next;
                    };

                    try testing.expectEqual(@as(usize, 1), assembler.store_builder.store_count);
                    try testing.expectEqual(@as(usize, 1), assembler.store_builder.state_binding_count);
                    try testing.expectEqual(@as(usize, 2), assembler.node_builder.tag_len);
                    try testing.expectEqual(@as(usize, 1), assembler.node_builder.switch_count);
                    try testing.expectEqual(@as(usize, 5), assembler.node_builder.len);
                    try testing.expectEqual(@as(usize, 0), assembler.adc_button_registry.len);
                    try testing.expectEqual(@as(usize, 0), assembler.gpio_button_registry.len);
                    try testing.expectEqual(@as(usize, 0), assembler.ledstrip_registry.len);
                }

                fn add_grouped_button_records_registry_entry() !void {
                    const embed_std = @import("embed_std");

                    const assembler = comptime blk: {
                        const AssemblerType = Assembler.make(embed_std.std, .{
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
                    const embed_std = @import("embed_std");

                    const BuildConfig = comptime blk: {
                        const AssemblerType = Assembler.make(embed_std.std, .{
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
                    const embed_std = @import("embed_std");

                    const assembler = comptime blk: {
                        const AssemblerType = Assembler.make(embed_std.std, .{
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
                    const embed_std = @import("embed_std");

                    const assembler = comptime blk: {
                        const AssemblerType = Assembler.make(embed_std.std, .{
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

                fn build_returns_app_methods() !void {
                    const drivers = @import("drivers");
                    const embed_std = @import("embed_std");
                    const ledstrip_mod = @import("ledstrip");

                    const Built = comptime blk: {
                        const AssemblerType = Assembler.make(embed_std.std, .{
                            .max_adc_buttons = 2,
                            .max_led_strips = 1,
                            .pipeline = .{
                                .tick_interval_ns = 7 * embed_std.std.time.ns_per_ms,
                                .spawn_config = .{
                                    .stack_size = 64 * 1024,
                                },
                            },
                        }, Channel);
                        var next = AssemblerType.init();
                        next.addGroupedButton(.buttons, 7, 3);
                        next.addLedStrip(.strip, 11, 4);

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
                    try testing.expectEqual(@as(usize, 1), Built.poller_count);
                    try testing.expectEqual(@as(usize, 4), Built.pixel_count);
                    try testing.expectEqual(@as(u64, 7 * embed_std.std.time.ns_per_ms), Built.ImplType.pipeline_config.tick_interval_ns);
                    if (@hasField(@TypeOf(Built.ImplType.pipeline_config.spawn_config), "stack_size")) {
                        try testing.expectEqual(
                            @as(usize, 64 * 1024),
                            Built.ImplType.pipeline_config.spawn_config.stack_size,
                        );
                    }
                    try testing.expectEqualStrings("buttons", @typeInfo(Built.PeriphLabel).@"enum".fields[0].name);
                    try testing.expect(@hasField(Built.Store.Stores, "buttons"));
                    try testing.expect(@hasField(Built.Store.Stores, "strip"));

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
                    try app.start();
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
                    try app.stop();
                    try testing.expectError(error.NotStarted, app.release_grouped_button(.buttons));
                    app.deinit();
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
            TestCase.build_config_exposes_added_labels() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.build_returns_app_methods() catch |err| {
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
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
