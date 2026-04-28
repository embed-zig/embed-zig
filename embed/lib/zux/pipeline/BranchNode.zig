const Emitter = @import("Emitter.zig");
const Message = @import("Message.zig");
const Node = @import("Node.zig");
const glib = @import("glib");

const BranchNode = @This();

const route_count = @typeInfo(Message.Kind).@"enum".fields.len;

pub const RouteMap = [route_count]?Node;

routes: RouteMap,
out: ?Emitter = null,

pub fn emptyRoutes() RouteMap {
    return [_]?Node{null} ** route_count;
}

pub fn init(self: *BranchNode, routes: RouteMap) Node {
    self.* = .{
        .routes = routes,
        .out = null,
    };
    return Node.init(BranchNode, self);
}

pub fn bindOutput(self: *BranchNode, out: Emitter) void {
    self.out = out;
}

pub fn process(self: *BranchNode, message: Message) !usize {
    for (&self.routes) |*route| {
        if (route.*) |*route_node| {
            route_node.out = null;
            if (self.out) |out| {
                route_node.bindOutput(out);
            }
        }
    }

    const kind = message.kind();
    if (kind == .tick) {
        var emitted: usize = 0;
        for (&self.routes) |*route| {
            if (route.*) |*route_node| {
                emitted += try route_node.process(message);
            }
        }

        if (emitted > 0) return emitted;
        if (self.out) |dst| {
            try dst.emit(message);
            return 1;
        }
        return 0;
    }

    if (self.routes[@intFromEnum(kind)]) |*route_node| {
        return route_node.process(message);
    }

    if (self.out) |dst| {
        try dst.emit(message);
        return 1;
    }

    return 0;
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn routesButtonMessageToButtonNode() !void {
            const Forward = struct {
                out: ?Emitter = null,
                called: bool = false,

                pub fn bindOutput(self: *@This(), out: Emitter) void {
                    self.out = out;
                }

                pub fn process(self: *@This(), message: Message) !usize {
                    self.called = true;
                    var next = message;
                    next.origin = .node;
                    try self.out.?.emit(next);
                    return 1;
                }
            };

            const Collector = struct {
                called: bool = false,
                last_origin: Message.Origin = .source,

                pub fn emit(self: *@This(), message: Message) !void {
                    self.called = true;
                    self.last_origin = message.origin;
                }
            };

            var forward_impl = Forward{};
            var collector = Collector{};
            var routes: RouteMap = [_]?Node{null} ** route_count;
            routes[@intFromEnum(Message.Kind.button_gesture)] = Node.init(Forward, &forward_impl);

            var branch_impl: BranchNode = undefined;
            var branch = branch_impl.init(routes);
            branch.bindOutput(Emitter.init(&collector));

            const emitted = try branch.process(.{
                .origin = .source,
                .body = .{
                    .button_gesture = .{
                        .source_id = 1,
                        .gesture = .{ .click = 1 },
                    },
                },
            });

            try grt.std.testing.expect(forward_impl.called);
            try grt.std.testing.expect(collector.called);
            try grt.std.testing.expectEqual(Message.Origin.node, collector.last_origin);
            try grt.std.testing.expectEqual(@as(usize, 1), emitted);
        }

        fn passthroughWhenRouteMapIsEmpty() !void {
            const Collector = struct {
                called: bool = false,
                last_button_id: ?u32 = 0,

                pub fn emit(self: *@This(), message: Message) !void {
                    self.called = true;
                    switch (message.body) {
                        .raw_grouped_button => |event| self.last_button_id = event.button_id,
                        else => {},
                    }
                }
            };

            var collector = Collector{};
            var branch_impl: BranchNode = undefined;
            var branch = branch_impl.init(BranchNode.emptyRoutes());
            branch.bindOutput(Emitter.init(&collector));

            const emitted = try branch.process(.{
                .origin = .source,
                .body = .{
                    .raw_grouped_button = .{
                        .source_id = 7,
                        .button_id = 3,
                        .pressed = false,
                    },
                },
            });

            try grt.std.testing.expect(collector.called);
            try grt.std.testing.expectEqual(@as(?u32, 3), collector.last_button_id);
            try grt.std.testing.expectEqual(@as(usize, 1), emitted);
        }

        fn passthroughWhenMessageTagIsUnmapped() !void {
            const Collector = struct {
                called: bool = false,
                last_button_id: ?u32 = 0,

                pub fn emit(self: *@This(), message: Message) !void {
                    self.called = true;
                    switch (message.body) {
                        .raw_grouped_button => |event| self.last_button_id = event.button_id,
                        else => {},
                    }
                }
            };

            const Noop = struct {
                pub fn bindOutput(_: *@This(), _: Emitter) void {}

                pub fn process(_: *@This(), _: Message) !usize {
                    return 0;
                }
            };

            var noop_impl = Noop{};
            var routes: RouteMap = [_]?Node{null} ** route_count;
            routes[@intFromEnum(Message.Kind.button_gesture)] = Node.init(Noop, &noop_impl);

            var collector = Collector{};
            var branch_impl: BranchNode = undefined;
            var branch = branch_impl.init(routes);
            branch.bindOutput(Emitter.init(&collector));

            const emitted = try branch.process(.{
                .origin = .source,
                .body = .{
                    .raw_grouped_button = .{
                        .source_id = 7,
                        .button_id = 3,
                        .pressed = false,
                    },
                },
            });

            try grt.std.testing.expect(collector.called);
            try grt.std.testing.expectEqual(@as(?u32, 3), collector.last_button_id);
            try grt.std.testing.expectEqual(@as(usize, 1), emitted);
        }

        fn tickBroadcastsToAllRoutes() !void {
            const Forward = struct {
                out: ?Emitter = null,
                called: usize = 0,

                pub fn bindOutput(self: *@This(), out: Emitter) void {
                    self.out = out;
                }

                pub fn process(self: *@This(), message: Message) !usize {
                    self.called += 1;
                    if (self.out) |out| {
                        try out.emit(message);
                    }
                    return 1;
                }
            };

            const Collector = struct {
                count: usize = 0,

                pub fn emit(self: *@This(), _: Message) !void {
                    self.count += 1;
                }
            };

            var first_impl = Forward{};
            var second_impl = Forward{};
            var collector = Collector{};
            var routes: RouteMap = [_]?Node{null} ** route_count;
            routes[@intFromEnum(Message.Kind.button_gesture)] = Node.init(Forward, &first_impl);
            routes[@intFromEnum(Message.Kind.raw_single_button)] = Node.init(Forward, &second_impl);

            var branch_impl: BranchNode = undefined;
            var branch = branch_impl.init(routes);
            branch.bindOutput(Emitter.init(&collector));

            const emitted = try branch.process(.{
                .origin = .timer,
                .timestamp = 1,
                .body = .{
                    .tick = .{},
                },
            });

            try grt.std.testing.expectEqual(@as(usize, 1), first_impl.called);
            try grt.std.testing.expectEqual(@as(usize, 1), second_impl.called);
            try grt.std.testing.expectEqual(@as(usize, 2), collector.count);
            try grt.std.testing.expectEqual(@as(usize, 2), emitted);
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

            inline for (.{
                TestCase.routesButtonMessageToButtonNode,
                TestCase.passthroughWhenRouteMapIsEmpty,
                TestCase.passthroughWhenMessageTagIsUnmapped,
                TestCase.tickBroadcastsToAllRoutes,
            }) |case| {
                case() catch |err| {
                    t.logFatal(@errorName(err));
                    return false;
                };
            }
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
