const embed = @import("embed");
const glib = @import("glib");
const launcher = @import("launcher");

const consts = @import("consts.zig");
const reducers_mod = @import("reducers.zig");
const renders_mod = @import("renders.zig");
const runtime_mod = @import("runtime.zig");

const zux = embed.zux;

pub fn Make(comptime configured_role: consts.Role) type {
    return struct {
        pub const role = configured_role;

        pub const SpecType = blk: {
            var builder = zux.spec.Builder.init();
            builder.addSpecSlices(&.{
                @embedFile("spec/component.json"),
                @embedFile("spec/state.json"),
                @embedFile("spec/hooks.json"),
            });
            break :blk builder.build();
        };

        fn ZuxAppType(comptime platform_grt: type) type {
            const assembler_config: zux.AssemblerConfig = .{
                .max_single_buttons = 1,
                .max_reducers = 2,
                .max_custom_events = 2,
                .store = .{
                    .max_stores = 8,
                    .max_state_nodes = 16,
                    .max_store_refs = 8,
                    .max_depth = 4,
                },
            };
            var spec = SpecType.init();
            var assembler = spec.assembler(platform_grt, assembler_config);
            reducers_mod.registerCustomEvents(&assembler);
            const BuildConfig = assembler.BuildConfig();
            return assembler.build(spec.defaultBuildConfig(BuildConfig));
        }

        pub fn make(comptime platform_ctx: type, comptime platform_grt: type) type {
            return launcher.make(struct {
                const Self = @This();

                pub const ZuxApp = ZuxAppType(platform_grt);
                const Runtime = runtime_mod.make(platform_grt, ZuxApp, role);
                const Renders = renders_mod.make(platform_grt, ZuxApp, Runtime.Ui);
                const Reducers = reducers_mod.make(platform_grt, ZuxApp);

                pub const title = "ble-speed-test";
                pub const description = "Raw BLE GATT notification/writeNoResp throughput test.";

                allocator: glib.std.mem.Allocator,
                zux_app: ZuxApp,
                reducers: Reducers = undefined,
                runtime: Runtime = undefined,
                renders: Renders = undefined,
                runtime_started: bool = false,

                pub fn init(allocator: glib.std.mem.Allocator, base_config: ZuxApp.InitConfig) !*Self {
                    const self = try allocator.create(Self);
                    errdefer allocator.destroy(self);

                    self.* = .{
                        .allocator = allocator,
                        .zux_app = undefined,
                    };
                    self.reducers = Reducers.init();

                    const initial_speed_test = initialSpeedTestState();
                    var init_config = base_config;
                    init_config.allocator = allocator;
                    init_config.initial_state = .{
                        .display = .{
                            .enabled = true,
                            .brightness = 255,
                        },
                        .boot = .{},
                        .speed_test = initial_speed_test,
                    };
                    init_config.app_reducer = ZuxApp.ReducerHook.init(&self.reducers);
                    init_config.ui_render = ZuxApp.RenderHook.init(&self.renders.ui);
                    init_config.button_render = ZuxApp.RenderHook.init(&self.renders.button);

                    self.zux_app = try ZuxApp.init(init_config);
                    errdefer self.zux_app.deinit();

                    self.runtime = try Runtime.init(.{
                        .allocator = allocator,
                        .zux_app = &self.zux_app,
                        .bt = init_config.bt,
                        .ble_task_options = bleRuntimeTaskOptions(),
                        .ui_config = .{
                            .task_options = uiRuntimeTaskOptions(),
                        },
                    });
                    errdefer self.runtime.deinit();

                    self.renders = Renders.init(.{
                        .allocator = allocator,
                        .zux_app = &self.zux_app,
                        .ui_runtime = &self.runtime.ui,
                    });
                    return self;
                }

                pub fn start(self: *Self) !void {
                    if (self.runtime_started) return;
                    try self.runtime.start();
                    self.runtime_started = true;
                }

                pub fn stop(self: *Self) void {
                    if (!self.runtime_started) return;
                    self.runtime.deinit();
                    self.runtime_started = false;
                }

                pub fn deinit(self: *Self) void {
                    const allocator = self.allocator;
                    if (self.runtime_started) {
                        self.runtime.deinit();
                    }
                    self.zux_app.deinit();
                    self.* = undefined;
                    allocator.destroy(self);
                }

                pub fn createTestRunner() glib.testing.TestRunner {
                    return testRunner(platform_grt);
                }

                fn initialSpeedTestState() @FieldType(ZuxApp.Store.Stores, "speed_test").StateType {
                    const State = @FieldType(ZuxApp.Store.Stores, "speed_test").StateType;
                    return reducers_mod.speed_test.initState(State, role);
                }

                fn bleRuntimeTaskOptions() glib.task.Options {
                    if (@hasDecl(platform_ctx, "bleSpeedTaskOptions")) {
                        return platform_ctx.bleSpeedTaskOptions();
                    }
                    return .{ .min_stack_size = 16 * 1024 };
                }

                fn uiRuntimeTaskOptions() glib.task.Options {
                    if (@hasDecl(platform_ctx, "bleSpeedUiTaskOptions")) {
                        return platform_ctx.bleSpeedUiTaskOptions();
                    }
                    return .{ .min_stack_size = 16 * 1024 };
                }
            });
        }

        pub fn testRunner(comptime platform_grt: type) glib.testing.TestRunner {
            const ZuxApp = ZuxAppType(platform_grt);
            const Runtime = runtime_mod.make(platform_grt, ZuxApp, role);
            const Renders = renders_mod.make(platform_grt, ZuxApp, Runtime.Ui);
            const Reducers = reducers_mod.make(platform_grt, ZuxApp);
            const UserStoryConfigFactoryImpl = struct {
                instance: Instance = undefined,

                pub const Instance = struct {
                    init_config: ZuxApp.InitConfig,
                    zux_app: ZuxApp = undefined,
                    reducers: Reducers = undefined,
                    renders: Renders = undefined,
                    runtime: Runtime = undefined,

                    pub fn config(self_instance: *@This()) ZuxApp.InitConfig {
                        return self_instance.init_config;
                    }

                    pub fn start(self_instance: *@This(), app: *ZuxApp) !void {
                        self_instance.runtime = try Runtime.init(.{
                            .allocator = self_instance.init_config.allocator,
                            .zux_app = app,
                            .bt = self_instance.init_config.bt,
                            .ble_task_options = .{},
                        });
                        self_instance.renders = Renders.init(.{
                            .allocator = self_instance.init_config.allocator,
                            .zux_app = app,
                            .ui_runtime = &self_instance.runtime.ui,
                        });
                    }

                    pub fn deinit(self_instance: *@This()) void {
                        self_instance.runtime.deinit();
                    }
                };

                pub fn make(self_factory: *@This(), init_config: ZuxApp.InitConfig) !*Instance {
                    self_factory.instance = .{ .init_config = init_config };
                    self_factory.instance.reducers = Reducers.init();
                    self_factory.instance.init_config.initial_state = .{
                        .display = .{
                            .enabled = true,
                            .brightness = 255,
                        },
                        .boot = .{},
                        .speed_test = reducers_mod.speed_test.initState(
                            @FieldType(ZuxApp.Store.Stores, "speed_test").StateType,
                            role,
                        ),
                    };
                    self_factory.instance.init_config.app_reducer = ZuxApp.ReducerHook.init(&self_factory.instance.reducers);
                    self_factory.instance.init_config.ui_render = ZuxApp.RenderHook.init(&self_factory.instance.renders.ui);
                    self_factory.instance.init_config.button_render = ZuxApp.RenderHook.init(&self_factory.instance.renders.button);
                    return &self_factory.instance;
                }
            };

            const spec = SpecType.init();
            return spec.testRunner(ZuxApp, UserStoryConfigFactoryImpl);
        }

        pub fn run(comptime platform_ctx: type, comptime platform_grt: type) !void {
            const Launcher = make(platform_ctx, platform_grt);

            try platform_ctx.setup();
            defer platform_ctx.teardown();

            var t = glib.testing.T.new(platform_grt.std, platform_grt.time, .zux_app);
            defer t.deinit();

            t.run("ble-speed-test/stories", Launcher.createTestRunner());
            if (!t.wait()) return error.TestFailed;
        }
    };
}
