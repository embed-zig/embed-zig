const glib = @import("glib");

const AssemblerConfig = @import("../../../assembler/Config.zig");
const Builder = @import("../../../spec/Builder.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const SpecType = comptime blk: {
        var builder = Builder.init();
        builder.addSpecSlices(&.{
            @embedFile("gpio/board.json"),
            @embedFile("gpio/basic_sequence.json"),
        });
        break :blk builder.build();
    };

    const assembler_config: AssemblerConfig = .{
        .max_gpio = 1,
        .max_reducers = 1,
        .store = .{
            .max_stores = 1,
            .max_state_nodes = 2,
            .max_store_refs = 2,
            .max_depth = 2,
        },
    };
    const AppType = comptime blk: {
        var spec = SpecType.init();
        break :blk spec.buildApp(grt, assembler_config);
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const UserStoryConfigFactoryImpl = struct {
                instance: Instance = undefined,

                pub const Instance = struct {
                    init_config: AppType.InitConfig,

                    pub fn config(instance: *@This()) AppType.InitConfig {
                        return instance.init_config;
                    }

                    pub fn deinit(instance: *@This()) void {
                        _ = instance;
                    }
                };

                pub fn make(factory: *@This(), init_config: AppType.InitConfig) !*Instance {
                    factory.instance = .{ .init_config = init_config };
                    return &factory.instance;
                }
            };

            const spec = SpecType.init();
            t.run("gpio stories", spec.testRunner(AppType, UserStoryConfigFactoryImpl));
            return t.wait();
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
