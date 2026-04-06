const Emitter = @import("Emitter.zig");
const Message = @import("Message.zig");
const testing_api = @import("testing");

const Node = @This();

impl: *anyopaque,
in: Emitter,
out: ?Emitter = null,
vtable: *const VTable,
type_id: *const anyopaque,

fn TypeIdHolder(comptime T: type) type {
    return struct {
        comptime _phantom: type = T,
        var id: u8 = 0;
    };
}

fn typeId(comptime T: type) *const anyopaque {
    return @ptrCast(&TypeIdHolder(T).id);
}

pub const VTable = struct {
    process: *const fn (node: *Node, message: Message) anyerror!usize,
    bindOutput: *const fn (node: *Node, out: Emitter) void,
};

pub fn as(self: Node, comptime T: type) error{TypeMismatch}!*T {
    if (self.type_id == typeId(T)) return @ptrCast(@alignCast(self.impl));
    return error.TypeMismatch;
}

pub fn process(self: *Node, message: Message) !usize {
    return self.vtable.process(self, message);
}

pub fn emit(self: *Node, message: Message) !void {
    _ = try self.process(message);
}

pub fn bindOutput(self: *Node, out: Emitter) void {
    self.out = out;
    self.vtable.bindOutput(self, out);
}

pub fn init(comptime T: type, impl: *T) Node {
    comptime {
        _ = @as(*const fn (*T, Message) anyerror!usize, &T.process);
        _ = @as(*const fn (*T, Emitter) void, &T.bindOutput);
    }

    const gen = struct {
        fn processImpl(ctx: *anyopaque, message: Message) anyerror!usize {
            const self: *T = @ptrCast(@alignCast(ctx));
            return self.process(message);
        }

        fn emitNode(ctx: *anyopaque, message: Message) anyerror!void {
            _ = try processImpl(ctx, message);
        }

        fn processFn(node: *Node, message: Message) anyerror!usize {
            return processImpl(node.impl, message);
        }

        const emitter_vtable = Emitter.VTable{
            .emit = emitNode,
        };

        fn bindOutputFn(node: *Node, out: Emitter) void {
            const self: *T = @ptrCast(@alignCast(node.impl));
            self.bindOutput(out);
        }

        const vtable = VTable{
            .process = processFn,
            .bindOutput = bindOutputFn,
        };
    };

    var node: Node = .{
        .impl = @ptrCast(impl),
        .in = undefined,
        .out = null,
        .vtable = &gen.vtable,
        .type_id = typeId(T),
    };
    node.in = .{
        .ctx = @ptrCast(impl),
        .vtable = &gen.emitter_vtable,
    };
    return node;
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn initBindAndProcess(testing: anytype) !void {
            const Impl = struct {
                called: bool = false,

                pub fn bindOutput(_: *@This(), _: Emitter) void {}

                pub fn process(self: *@This(), _: Message) !usize {
                    self.called = true;
                    return 1;
                }
            };

            var impl = Impl{};

            var node = Node.init(Impl, &impl);
            try testing.expect((try node.as(Impl)) == &impl);
            try testing.expectError(error.TypeMismatch, node.as(struct { x: u8 }));
            const emitted = try node.process(.{
                .origin = .source,
                .body = .{
                    .raw_single_button = .{
                        .source_id = 1,
                        .pressed = true,
                    },
                },
            });

            try testing.expect(impl.called);
            try testing.expectEqual(@as(usize, 1), emitted);
        }

        fn cascadeThroughBoundOutputs(testing: anytype) !void {
            const Forward = struct {
                out: ?Emitter = null,
                called: bool = false,
                delta_ns: i128,

                pub fn bindOutput(self: *@This(), out: Emitter) void {
                    self.out = out;
                }

                pub fn process(self: *@This(), message: Message) !usize {
                    self.called = true;
                    var next = message;
                    next.timestamp_ns += self.delta_ns;
                    try self.out.?.emit(next);
                    return 1;
                }
            };

            const Collector = struct {
                called: bool = false,
                last_timestamp_ns: i128 = 0,

                pub fn emit(self: *@This(), message: Message) !void {
                    self.called = true;
                    self.last_timestamp_ns = message.timestamp_ns;
                }
            };

            var first_impl = Forward{ .delta_ns = 2 };
            var second_impl = Forward{ .delta_ns = 3 };
            var collector = Collector{};

            var first = Node.init(Forward, &first_impl);
            var second = Node.init(Forward, &second_impl);

            first.bindOutput(Emitter.init(&second));
            second.bindOutput(Emitter.init(&collector));

            const emitted = try first.process(.{
                .origin = .source,
                .timestamp_ns = 5,
                .body = .{
                    .raw_single_button = .{
                        .source_id = 1,
                        .pressed = true,
                    },
                },
            });

            try testing.expect(first_impl.called);
            try testing.expect(second_impl.called);
            try testing.expect(collector.called);
            try testing.expectEqual(@as(i128, 10), collector.last_timestamp_ns);
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
            _ = allocator;
            const testing = lib.testing;

            TestCase.initBindAndProcess(testing) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.cascadeThroughBoundOutputs(testing) catch |err| {
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
