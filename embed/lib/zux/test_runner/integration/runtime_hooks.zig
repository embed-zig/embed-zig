const glib = @import("glib");
const AssemblerConfig = @import("../../assembler/Config.zig");
const Builder = @import("../../spec/Builder.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const SpecType = comptime blk: {
        var builder = Builder.init();
        builder.addSpecSlices(&.{
            \\{
            \\  "kind": "Doc",
            \\  "spec": [
            \\    {
            \\      "kind": "Store",
            \\      "spec": {
            \\        "label": "counter",
            \\        "state": {
            \\          "ticks": "u32"
            \\        }
            \\      }
            \\    },
            \\    {
            \\      "kind": "StatePath",
            \\      "spec": {
            \\        "path": "app/state",
            \\        "labels": [
            \\          "counter"
            \\        ]
            \\      }
            \\    },
            \\    {
            \\      "kind": "Reducer",
            \\      "spec": {
            \\        "label": "counter_reducer",
            \\        "fn_name": "CounterHook.reduce"
            \\      }
            \\    },
            \\    {
            \\      "kind": "Render",
            \\      "spec": {
            \\        "label": "counter_render",
            \\        "state_path": "app/state",
            \\        "fn_name": "CounterRender.render"
            \\      }
            \\    }
            \\  ]
            \\}
            ,
            \\{
            \\  "kind": "UserStory",
            \\  "spec": {
            \\    "name": "first hook instance",
            \\    "description": "private reducer state accumulates within one story",
            \\    "initial_state": {
            \\      "counter": {
            \\        "ticks": 0
            \\      }
            \\    },
            \\    "steps": [
            \\      {
            \\        "tick": {
            \\          "interval": 1,
            \\          "n": 2
            \\        },
            \\        "outputs": [
            \\          {
            \\            "label": "counter",
            \\            "state": {
            \\              "ticks": 3
            \\            }
            \\          }
            \\        ]
            \\      }
            \\    ]
            \\  }
            \\}
            ,
            \\{
            \\  "kind": "UserStory",
            \\  "spec": {
            \\    "name": "second hook instance",
            \\    "description": "private reducer state starts fresh for the next story",
            \\    "initial_state": {
            \\      "counter": {
            \\        "ticks": 0
            \\      }
            \\    },
            \\    "steps": [
            \\      {
            \\        "tick": {
            \\          "interval": 1,
            \\          "n": 1
            \\        },
            \\        "outputs": [
            \\          {
            \\            "label": "counter",
            \\            "state": {
            \\              "ticks": 1
            \\            }
            \\          }
            \\        ]
            \\      }
            \\    ]
            \\  }
            \\}
            ,
        });
        break :blk builder.build();
    };

    const assembler_config: AssemblerConfig = .{
        .max_reducers = 1,
        .max_handles = 1,
        .store = .{
            .max_stores = 1,
            .max_state_nodes = 4,
            .max_store_refs = 4,
            .max_depth = 4,
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

                pub const CounterHook = struct {
                    private_ticks: u32 = 0,

                    pub fn reduce(
                        hook: *@This(),
                        stores: *AppType.Store.Stores,
                        message: AppType.Message,
                        emit: AppType.Emitter,
                    ) !usize {
                        _ = emit;
                        switch (message.body) {
                            .tick => {
                                hook.private_ticks += 1;
                                stores.counter.invoke(hook.private_ticks, struct {
                                    fn apply(state: *@FieldType(AppType.Store.Stores, "counter").StateType, amount: u32) void {
                                        state.ticks += amount;
                                    }
                                }.apply);
                                return 1;
                            },
                            else => return 0,
                        }
                    }
                };

                pub const CounterRender = struct {
                    pub fn render(render_hook: *@This(), app: *AppType.ImplType) !void {
                        _ = render_hook;
                        _ = app;
                    }
                };

                pub const Instance = struct {
                    init_config: AppType.InitConfig,
                    counter_hook: CounterHook = .{},
                    counter_render: CounterRender = .{},

                    pub fn config(instance: *@This()) AppType.InitConfig {
                        return instance.init_config;
                    }

                    pub fn deinit(instance: *@This()) void {
                        _ = instance;
                    }
                };

                pub fn make(factory: *@This(), init_config: AppType.InitConfig) !*Instance {
                    factory.instance = .{ .init_config = init_config };
                    factory.instance.init_config.counter_reducer = AppType.ReducerHook.init(&factory.instance.counter_hook);
                    factory.instance.init_config.counter_render = AppType.RenderHook.init(&factory.instance.counter_render);
                    return &factory.instance;
                }
            };
            const spec = SpecType.init();
            t.run("runtime hook stories", spec.testRunner(AppType, UserStoryConfigFactoryImpl));
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
