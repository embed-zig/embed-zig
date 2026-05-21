const glib = @import("glib");

const AssemblerConfig = @import("../../../assembler/Config.zig");
const Builder = @import("../../../spec/Builder.zig");
const component_audio_system = @import("../../../component/audio_system.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const SpecType = comptime blk: {
        var builder = Builder.init();
        builder.addSpecSlices(&.{
            @embedFile("audio_system/board.json"),
            @embedFile("audio_system/basic_sequence.json"),
        });
        break :blk builder.build();
    };

    const assembler_config: AssemblerConfig = .{
        .max_audio_systems = 1,
        .max_reducers = 1,
        .max_handles = 1,
        .store = .{
            .max_stores = 1,
            .max_state_nodes = 4,
            .max_store_refs = 1,
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

                pub const AudioRender = struct {
                    pub fn render(_: *@This(), app: *AppType.ImplType) !void {
                        try component_audio_system.Render.render(
                            app.store().stores.audio.get(),
                            app.audioSystem(.audio),
                        );
                    }
                };

                pub const Instance = struct {
                    init_config: AppType.InitConfig,
                    render: AudioRender = .{},

                    pub fn config(instance: *@This()) AppType.InitConfig {
                        return instance.init_config;
                    }

                    pub fn deinit(instance: *@This()) void {
                        _ = instance;
                    }
                };

                pub fn make(factory: *@This(), init_config: AppType.InitConfig) !*Instance {
                    factory.instance = .{ .init_config = init_config };
                    factory.instance.init_config.audio_render = AppType.RenderHook.init(&factory.instance.render);
                    return &factory.instance;
                }
            };

            const spec = SpecType.init();
            t.run("audio system stories", spec.testRunner(AppType, UserStoryConfigFactoryImpl));
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
