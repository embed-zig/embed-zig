const glib = @import("glib");

const gpio_event = @import("event.zig");
const GpioState = @import("State.zig");
const Emitter = @import("../../pipeline/Emitter.zig");
const Message = @import("../../pipeline/Message.zig");

const Reducer = @This();

pub fn init() Reducer {
    return .{};
}

pub fn reduce(self: *Reducer, store: anytype, message: Message, emit: Emitter) !void {
    _ = self;
    _ = emit;

    switch (message.body) {
        .raw_gpio_changed => |value| {
            store.invoke(value, struct {
                fn apply(state: *GpioState, event_value: gpio_event.RawChanged) void {
                    state.source_id = event_value.source_id;
                    state.level = event_value.level;
                    state.last_edge = event_value.edge;
                    state.generation +%= 1;
                }
            }.apply);
        },
        else => return,
    }
}

pub fn deinit(self: *Reducer) void {
    _ = self;
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn reduceTracksLevelEdgeAndGeneration() !void {
            const StoreObject = @import("../../store/Object.zig");

            const GpioStore = StoreObject.make(grt, GpioState, .gpio);
            var store = GpioStore.init(grt.std.testing.allocator, .{});
            defer store.deinit();
            var reducer = Reducer.init();
            defer reducer.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var sink = NoopSink{};
            const emit = Emitter.init(&sink);

            try reducer.reduce(&store, .{
                .origin = .source,
                .body = .{
                    .raw_gpio_changed = .{
                        .source_id = 31,
                        .edge = .rising,
                        .level = .high,
                    },
                },
            }, emit);
            store.tick();

            const state = store.get();
            try grt.std.testing.expectEqual(@as(u32, 31), state.source_id);
            try grt.std.testing.expectEqual(@import("drivers").Gpio.Level.high, state.level);
            try grt.std.testing.expectEqual(@as(?@import("drivers").Gpio.Edge, .rising), state.last_edge);
            try grt.std.testing.expectEqual(@as(u64, 1), state.generation);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.reduceTracksLevelEdgeAndGeneration() catch |err| {
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
