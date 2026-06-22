const embed = @import("embed");
const glib = @import("glib");
const launcher = @import("launcher");
const zux = embed.zux;

const reducers_mod = @import("reducers.zig");
const renders_mod = @import("renders.zig");
const runtime_mod = @import("runtime.zig");

pub const SpecType = blk: {
    var builder = zux.spec.Builder.init();
    builder.addSpecSlices(&.{
        @embedFile("spec/component.json"),
        @embedFile("spec/state.json"),
        @embedFile("spec/hooks.json"),
        @embedFile("spec/user_stories/raw_grouped_button_updates_debug_state.json"),
    });
    break :blk builder.build();
};

fn ZuxAppType(comptime platform_grt: type) type {
    const assembler_config: zux.AssemblerConfig = .{
        .max_adc_buttons = 1,
        .max_displays = 1,
        .max_reducers = 1,
        .max_handles = 1,
        .store = .{
            .max_stores = 3,
            .max_state_nodes = 8,
            .max_store_refs = 4,
            .max_depth = 4,
        },
    };
    var spec = SpecType.init();
    return spec.buildApp(platform_grt, assembler_config);
}

pub fn make(comptime platform_ctx: type, comptime platform_grt: type) type {
    return launcher.make(struct {
        const Self = @This();

        pub const ZuxApp = ZuxAppType(platform_grt);
        const Runtime = runtime_mod.make(platform_grt, ZuxApp);
        const Reducers = reducers_mod.make(ZuxApp);
        const Renders = renders_mod.make(ZuxApp, Runtime);

        pub const title = "adc-group-debug";
        pub const description = "ADC grouped button poller debug display.";

        allocator: glib.std.mem.Allocator,
        zux_app: ZuxApp,
        reducers: Reducers = undefined,
        renders: Renders = undefined,
        runtime: Runtime = undefined,

        pub fn init(allocator: glib.std.mem.Allocator, base_config: ZuxApp.InitConfig) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = .{
                .allocator = allocator,
                .zux_app = undefined,
                .reducers = Reducers.init(),
                .renders = Renders.init(),
            };

            var init_config = base_config;
            init_config.allocator = allocator;
            applyInitialState(&init_config);
            init_config.debug_reducer = ZuxApp.ReducerHook.init(&self.reducers);
            init_config.debug_render = ZuxApp.RenderHook.init(&self.renders.debug);

            self.zux_app = try ZuxApp.init(init_config);
            errdefer self.zux_app.deinit();

            self.runtime = try Runtime.init(.{
                .allocator = allocator,
                .zux_app = &self.zux_app,
                .ui_config = .{
                    .task_options = uiRuntimeTaskOptions(),
                },
            });
            errdefer self.runtime.deinit();

            self.renders.bindRuntime(&self.runtime);
            try self.runtime.start();
            return self;
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.allocator;
            self.runtime.deinit();
            self.zux_app.deinit();
            self.* = undefined;
            allocator.destroy(self);
        }

        pub fn createTestRunner() glib.testing.TestRunner {
            return testRunner(platform_grt);
        }

        fn applyInitialState(init_config: *ZuxApp.InitConfig) void {
            init_config.initial_state = .{
                .keys = .{},
                .display = .{
                    .enabled = true,
                    .brightness = 255,
                },
                .debug = .{
                    .raw_id = 999,
                    .raw_pressed = false,
                    .raw_events = 0,
                    .gesture_id = 999,
                    .gesture_events = 0,
                    .click_count = 0,
                },
            };
        }

        fn uiRuntimeTaskOptions() glib.task.Options {
            if (@hasDecl(platform_ctx, "adcGroupDebugUiTaskOptions")) {
                return platform_ctx.adcGroupDebugUiTaskOptions();
            }
            return .{ .min_stack_size = 16 * 1024 };
        }
    });
}

pub fn testRunner(comptime platform_grt: type) glib.testing.TestRunner {
    const ZuxApp = ZuxAppType(platform_grt);
    const Runtime = runtime_mod.make(platform_grt, ZuxApp);
    const Reducers = reducers_mod.make(ZuxApp);
    const Renders = renders_mod.make(ZuxApp, Runtime);
    const UserStoryConfigFactoryImpl = struct {
        instance: Instance = undefined,

        pub const Instance = struct {
            init_config: ZuxApp.InitConfig,
            reducers: Reducers = undefined,
            renders: Renders = undefined,
            runtime: Runtime = undefined,
            runtime_initialized: bool = false,

            pub fn config(self_instance: *@This()) ZuxApp.InitConfig {
                return self_instance.init_config;
            }

            pub fn start(self_instance: *@This(), app: *ZuxApp) !void {
                self_instance.runtime = try Runtime.init(.{
                    .allocator = self_instance.init_config.allocator,
                    .zux_app = app,
                });
                self_instance.runtime_initialized = true;
                self_instance.renders.bindRuntime(&self_instance.runtime);
                try self_instance.runtime.start();
            }

            pub fn deinit(self_instance: *@This()) void {
                if (self_instance.runtime_initialized) {
                    self_instance.runtime.deinit();
                    self_instance.runtime_initialized = false;
                }
            }
        };

        pub fn make(self_factory: *@This(), init_config: ZuxApp.InitConfig) !*Instance {
            self_factory.instance = .{
                .init_config = init_config,
                .reducers = Reducers.init(),
                .renders = Renders.init(),
            };
            self_factory.instance.init_config.debug_reducer = ZuxApp.ReducerHook.init(&self_factory.instance.reducers);
            self_factory.instance.init_config.debug_render = ZuxApp.RenderHook.init(&self_factory.instance.renders.debug);
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

    t.run("adc-group-debug/stories", Launcher.createTestRunner());
    if (!t.wait()) return error.TestFailed;
}
