const glib = @import("glib");
const AssemblerConfig = @import("../../assembler/Config.zig");
const Builder = @import("../../spec/Builder.zig");

const ProgressSetEvent = struct {
    pub const event_name = "test.progress.set";

    allocator: glib.std.mem.Allocator,
    value: u32,

    pub fn decodeJson(allocator: glib.std.mem.Allocator, value: glib.std.json.Value) !*@This() {
        const object = switch (value) {
            .object => |object| object,
            else => return error.ExpectedObject,
        };
        const value_field = object.get("value") orelse return error.MissingObjectField;
        const progress_value: u32 = switch (value_field) {
            .integer => |int_value| try castU32(int_value),
            else => return error.ExpectedInteger,
        };

        const payload = try allocator.create(@This());
        payload.* = .{
            .allocator = allocator,
            .value = progress_value,
        };
        return payload;
    }

    pub fn deinit(payload: *@This()) void {
        payload.allocator.destroy(payload);
    }
};

const ProgressDeltaEvent = struct {
    pub const event_name = "test.progress.delta";

    allocator: glib.std.mem.Allocator,
    amount: u32,

    pub fn decodeJson(allocator: glib.std.mem.Allocator, value: glib.std.json.Value) !*@This() {
        const object = switch (value) {
            .object => |object| object,
            else => return error.ExpectedObject,
        };
        const amount_field = object.get("amount") orelse return error.MissingObjectField;
        const amount: u32 = switch (amount_field) {
            .integer => |int_value| try castU32(int_value),
            else => return error.ExpectedInteger,
        };

        const payload = try allocator.create(@This());
        payload.* = .{
            .allocator = allocator,
            .amount = amount,
        };
        return payload;
    }

    pub fn deinit(payload: *@This()) void {
        payload.allocator.destroy(payload);
    }
};

const ProgressResetEvent = struct {
    pub const event_name = "test.progress.reset";

    allocator: glib.std.mem.Allocator,

    pub fn decodeJson(allocator: glib.std.mem.Allocator, value: glib.std.json.Value) !*@This() {
        switch (value) {
            .object => {},
            else => return error.ExpectedObject,
        }

        const payload = try allocator.create(@This());
        payload.* = .{
            .allocator = allocator,
        };
        return payload;
    }

    pub fn deinit(payload: *@This()) void {
        payload.allocator.destroy(payload);
    }
};

const IgnoredEvent = struct {
    pub const event_name = "test.progress.ignored";

    allocator: glib.std.mem.Allocator,
    marker: u32,

    pub fn decodeJson(allocator: glib.std.mem.Allocator, value: glib.std.json.Value) !*@This() {
        const object = switch (value) {
            .object => |object| object,
            else => return error.ExpectedObject,
        };
        const marker_field = object.get("marker") orelse return error.MissingObjectField;
        const marker: u32 = switch (marker_field) {
            .integer => |int_value| try castU32(int_value),
            else => return error.ExpectedInteger,
        };

        const payload = try allocator.create(@This());
        payload.* = .{
            .allocator = allocator,
            .marker = marker,
        };
        return payload;
    }

    pub fn deinit(payload: *@This()) void {
        payload.allocator.destroy(payload);
    }
};

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const SpecType = comptime blk: {
        var builder = Builder.init();
        builder.addSpecSlices(&.{
            @embedFile("custom_event/board.json"),
            @embedFile("custom_event/progress_set_sequence.json"),
            @embedFile("custom_event/progress_delta_sequence.json"),
            @embedFile("custom_event/progress_reset_sequence.json"),
            @embedFile("custom_event/progress_order_sequence.json"),
        });
        break :blk builder.build();
    };

    const assembler_config: AssemblerConfig = .{
        .max_reducers = 1,
        .max_custom_events = 4,
        .store = .{
            .max_stores = 1,
            .max_state_nodes = 7,
            .max_store_refs = 2,
            .max_depth = 4,
        },
    };
    const AppType = comptime blk: {
        var spec = SpecType.init();
        var assembled = spec.assembler(grt, assembler_config);
        assembled.registerCustomEvent(ProgressSetEvent);
        assembled.registerCustomEvent(ProgressDeltaEvent);
        assembled.registerCustomEvent(ProgressResetEvent);
        assembled.registerCustomEvent(IgnoredEvent);
        const BuildConfig = assembled.BuildConfig();
        const build_config: BuildConfig = .{};
        break :blk assembled.build(build_config);
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

                pub const ProgressReducer = struct {
                    const ProgressSetInput = struct {
                        source_id: u32,
                        value: u32,
                    };

                    const ProgressDeltaInput = struct {
                        source_id: u32,
                        amount: u32,
                    };

                    pub fn reduce(
                        reducer: *@This(),
                        stores: *AppType.Store.Stores,
                        message: AppType.Message,
                        emit: AppType.Emitter,
                    ) !void {
                        _ = reducer;
                        _ = emit;

                        switch (message.body) {
                            .custom => |custom| {
                                if (custom.as(ProgressSetEvent)) |payload| {
                                    stores.progress.invoke(ProgressSetInput{
                                        .source_id = custom.source_id,
                                        .value = payload.value,
                                    }, struct {
                                        fn apply(state: *@FieldType(AppType.Store.Stores, "progress").StateType, progress: ProgressSetInput) void {
                                            state.seen = true;
                                            state.source_id = progress.source_id;
                                            state.value = progress.value;
                                            state.updates += 1;
                                            state.last_kind = .set;
                                        }
                                    }.apply);
                                    return;
                                } else |_| {}

                                if (custom.as(ProgressDeltaEvent)) |payload| {
                                    stores.progress.invoke(ProgressDeltaInput{
                                        .source_id = custom.source_id,
                                        .amount = payload.amount,
                                    }, struct {
                                        fn apply(state: *@FieldType(AppType.Store.Stores, "progress").StateType, progress: ProgressDeltaInput) void {
                                            state.seen = true;
                                            state.source_id = progress.source_id;
                                            state.value += progress.amount;
                                            state.updates += 1;
                                            state.last_kind = .delta;
                                        }
                                    }.apply);
                                    return;
                                } else |_| {}

                                if (custom.as(ProgressResetEvent)) |_| {
                                    stores.progress.invoke(custom.source_id, struct {
                                        fn apply(state: *@FieldType(AppType.Store.Stores, "progress").StateType, source_id: u32) void {
                                            state.seen = false;
                                            state.source_id = source_id;
                                            state.value = 0;
                                            state.updates += 1;
                                            state.reset_count += 1;
                                            state.last_kind = .reset;
                                        }
                                    }.apply);
                                    return;
                                } else |_| {}

                                return;
                            },
                            else => return,
                        }
                    }
                };

                pub const Instance = struct {
                    init_config: AppType.InitConfig,
                    progress_reducer: ProgressReducer = .{},

                    pub fn config(instance: *@This()) AppType.InitConfig {
                        return instance.init_config;
                    }

                    pub fn deinit(instance: *@This()) void {
                        _ = instance;
                    }
                };

                pub fn make(factory: *@This(), init_config: AppType.InitConfig) !*Instance {
                    factory.instance = .{ .init_config = init_config };
                    factory.instance.init_config.progress_reducer = AppType.ReducerHook.init(&factory.instance.progress_reducer);
                    return &factory.instance;
                }
            };

            const spec = SpecType.init();
            t.run("custom event stories", spec.testRunner(AppType, UserStoryConfigFactoryImpl));
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

fn castU32(value: i64) !u32 {
    if (value < 0) return error.IntegerOutOfRange;
    if (@as(u64, @intCast(value)) > glib.std.math.maxInt(u32)) return error.IntegerOutOfRange;
    return @intCast(value);
}
