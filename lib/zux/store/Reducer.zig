const testing_api = @import("testing");
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

        pub fn init(stores: *Stores, reducer: ReducerFn) Self {
            return .{
                .stores = stores,
                .reducer = reducer,
                .out = null,
            };
        }

        pub fn node(self: *Self) Node {
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
            const reduced = try self.reducer(self.stores, message, emit);
            if (message.body == .tick) {
                if (self.out) |out| {
                    try out.emit(message);
                    return reduced + 1;
                }
            }
            return reduced;
        }
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn use_case_shape(testing: anytype, _: lib.mem.Allocator) !void {
            const embed_std = @import("embed_std");
            const store = @import("../Store.zig");

            const ButtonStore = struct {
                pressed: bool = false,
            };

            const AppStore = comptime blk: {
                const B = store.Builder(.{});
                var builder = B.init();
                builder.setStore(.button, ButtonStore);
                break :blk builder.make(embed_std.std);
            };

            const ReducerTy = make(AppStore);

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
            var reducer_impl = ReducerTy.init(&stores, ButtonReducer.reduce);
            var sink = Sink{};

            var node = reducer_impl.node();
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

            try testing.expect(stores.button.pressed);
            try testing.expect(sink.called);
            try testing.expectEqual(@as(?u32, 0), sink.last_button_id);
            try testing.expect(sink.last_pressed);
            try testing.expectEqual(@as(usize, 1), emitted);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            const testing = lib.testing;

            TestCase.use_case_shape(testing, allocator) catch |err| {
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
