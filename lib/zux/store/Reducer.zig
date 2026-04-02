const Emitter = @import("../pipeline/Emitter.zig");
const Message = @import("../pipeline/Message.zig");
const Node = @import("../pipeline/Node.zig");

pub fn make(comptime Store: type) type {
    return struct {
        stores: *Store.Stores,
        reducer: ReducerFn,
        out: ?Emitter = null,

        const Self = @This();

        pub const StoreType = Store;
        pub const Stores = Store.Stores;
        pub const ReducerFn = *const fn (stores: *Stores, message: Message, emit: Emitter) anyerror!usize;

        pub fn init(self: *Self, stores: *Stores, reducer: ReducerFn) Node {
            self.* = .{
                .stores = stores,
                .reducer = reducer,
                .out = null,
            };
            return Node.init(Self, self);
        }

        pub fn bindOutput(self: *Self, out: Emitter) void {
            self.out = out;
        }

        pub fn process(self: *Self, message: Message) !usize {
            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };

            var noop = NoopSink{};
            const emit = self.out orelse Emitter.init(&noop);
            return self.reducer(self.stores, message, emit);
        }
    };
}

test "zux/store/Reducer/unit_tests/use_case_shape" {
    const std = @import("std");
    const embed_std = @import("embed_std");
    const Store = @import("../Store.zig");

    const ButtonStore = struct {
        pressed: bool = false,
    };

    const AppStore = Store.make(embed_std.std, .{
        .stores = .{
            .button = ButtonStore,
        },
        .state = .{},
    });

    const Reducer = make(AppStore);

    const Sink = struct {
        called: bool = false,
        last_button_id: ?u32 = 999,
        last_pressed: bool = false,

        pub fn emit(self: *@This(), message: Message) !void {
            self.called = true;
            switch (message.body) {
                .raw_grouped_button => |group| {
                    self.last_button_id = group.button_id;
                    self.last_pressed = group.pressed;
                },
                else => {},
            }
        }
    };

    const ButtonReducer = struct {
        fn reduce(stores: *AppStore.Stores, message: Message, emit: Emitter) !usize {
            switch (message.body) {
                .raw_single_button => |button| {
                    stores.button.pressed = button.pressed;

                    if (button.pressed) {
                        try emit.emit(.{
                            .origin = .node,
                            .body = .{
                                .raw_grouped_button = .{
                                    .source_id = button.source_id,
                                    .button_id = 0,
                                    .pressed = true,
                                },
                            },
                        });
                        return 1;
                    }

                    return 0;
                },
                else => return 0,
            }
        }
    };

    var stores: AppStore.Stores = .{
        .button = .{},
    };
    var reducer_impl: Reducer = undefined;
    var sink = Sink{};

    var node = reducer_impl.init(&stores, ButtonReducer.reduce);
    node.bindOutput(Emitter.init(&sink));

    const emitted = try node.process(.{
        .origin = .source,
        .body = .{
            .raw_single_button = .{
                .source_id = 1,
                .pressed = true,
            },
        },
    });

    try std.testing.expect(stores.button.pressed);
    try std.testing.expect(sink.called);
    try std.testing.expectEqual(@as(?u32, 0), sink.last_button_id);
    try std.testing.expect(sink.last_pressed);
    try std.testing.expectEqual(@as(usize, 1), emitted);
}
