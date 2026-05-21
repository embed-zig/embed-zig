const glib = @import("glib");
const drivers = @import("drivers");

const AssemblerConfig = @import("../../../assembler/Config.zig");
const Builder = @import("../../../spec/Builder.zig");
const component_switch = @import("../../../component/switch.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const SpecType = comptime blk: {
        var builder = Builder.init();
        builder.addSpecSlices(&.{
            @embedFile("switch/board.json"),
            @embedFile("switch/basic_sequence.json"),
        });
        break :blk builder.build();
    };

    const assembler_config: AssemblerConfig = .{
        .max_switches = 1,
        .max_pwms = 1,
        .max_reducers = 2,
        .max_handles = 2,
        .store = .{
            .max_stores = 2,
            .max_state_nodes = 4,
            .max_store_refs = 4,
            .max_depth = 3,
        },
    };
    const AppType = comptime blk: {
        var spec = SpecType.init();
        break :blk spec.buildApp(grt, assembler_config);
    };

    const Runner = struct {
        pub fn init(runner: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = runner;
            _ = allocator;
        }

        pub fn run(runner: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = runner;
            _ = allocator;

            const UserStoryConfigFactoryImpl = struct {
                instance: Instance = undefined,

                pub const SwitchRender = struct {
                    pub fn render(_: *@This(), app: *AppType.ImplType) !void {
                        try component_switch.Render.renderSwitch(
                            app.store().stores.status.get(),
                            app.outputSwitch(.status),
                        );
                    }
                };

                pub const PwmRender = struct {
                    pub fn render(_: *@This(), app: *AppType.ImplType) !void {
                        try component_switch.Render.renderPwm(
                            app.store().stores.dimmer.get(),
                            app.pwm(.dimmer),
                        );
                    }
                };

                pub const Instance = struct {
                    init_config: AppType.InitConfig,
                    switch_render: SwitchRender = .{},
                    pwm_render: PwmRender = .{},

                    pub fn config(instance: *@This()) AppType.InitConfig {
                        return instance.init_config;
                    }

                    pub fn deinit(instance: *@This()) void {
                        _ = instance;
                    }
                };

                pub fn make(factory: *@This(), init_config: AppType.InitConfig) !*Instance {
                    factory.instance = .{ .init_config = init_config };
                    factory.instance.init_config.status_render = AppType.RenderHook.init(&factory.instance.switch_render);
                    factory.instance.init_config.dimmer_render = AppType.RenderHook.init(&factory.instance.pwm_render);
                    return &factory.instance;
                }
            };

            const spec = SpecType.init();
            t.run("switch stories", spec.testRunner(AppType, UserStoryConfigFactoryImpl));
            return t.wait();
        }

        pub fn deinit(runner: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = runner;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
