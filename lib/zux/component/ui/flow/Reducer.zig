const testing_api = @import("testing");

const Builder = @import("Builder.zig");
const Dag = @import("Dag.zig");
const flow_event = @import("event.zig");
const Emitter = @import("../../../pipeline/Emitter.zig");
const Message = @import("../../../pipeline/Message.zig");
const Subscriber = @import("../../../store/Subscriber.zig");

pub fn make(
    comptime lib: type,
    comptime FlowState: type,
    comptime dag: Dag,
    comptime NodeLabel: type,
) type {
    comptime dag.validate();

    const AtomicU64 = lib.atomic.Value(u64);
    const Mutex = lib.Thread.Mutex;
    const RwLock = lib.Thread.RwLock;
    const SubscriberList = lib.ArrayList(*Subscriber);

    return struct {
        const Self = @This();

        pub const StateType = FlowState;

        allocator: lib.mem.Allocator,

        running_mu: Mutex = .{},
        running_state: FlowState = .{},

        released_mu: RwLock = .{},
        released_state: FlowState = .{},

        subscribers_mu: Mutex = .{},
        subscribers: SubscriberList = .empty,
        subscribers_notifying: bool = false,
        tick_count: AtomicU64 = AtomicU64.init(0),

        pub fn init(allocator: lib.mem.Allocator, initial: FlowState) Self {
            return .{
                .allocator = allocator,
                .running_state = initial,
                .released_state = initial,
            };
        }

        pub fn deinit(self: *Self) void {
            self.subscribers_mu.lock();
            if (self.subscribers_notifying) {
                self.subscribers_mu.unlock();
                @panic("zux.component.ui.flow.deinit cannot run during subscriber notification");
            }
            self.subscribers.deinit(self.allocator);
            self.subscribers = .empty;
            self.subscribers_mu.unlock();
        }

        pub fn get(self: *Self) FlowState {
            self.released_mu.lockShared();
            defer self.released_mu.unlockShared();
            return self.released_state;
        }

        pub fn subscribe(self: *Self, subscriber: *Subscriber) error{OutOfMemory}!void {
            self.subscribers_mu.lock();
            defer self.subscribers_mu.unlock();
            if (self.subscribers_notifying) {
                @panic("zux.component.ui.flow.subscribe cannot mutate subscribers during notification");
            }

            for (self.subscribers.items) |existing| {
                if (existing == subscriber) return;
            }
            try self.subscribers.append(self.allocator, subscriber);
        }

        pub fn unsubscribe(self: *Self, subscriber: *Subscriber) bool {
            self.subscribers_mu.lock();
            defer self.subscribers_mu.unlock();
            if (self.subscribers_notifying) {
                @panic("zux.component.ui.flow.unsubscribe cannot mutate subscribers during notification");
            }

            for (self.subscribers.items, 0..) |existing, i| {
                if (existing != subscriber) continue;
                _ = self.subscribers.orderedRemove(i);
                return true;
            }
            return false;
        }

        pub fn tick(self: *Self) void {
            const tick_count = self.tick_count.fetchAdd(1, .acq_rel) + 1;
            self.running_mu.lock();
            self.released_mu.lock();

            if (stateEql(self.running_state, self.released_state)) {
                self.released_mu.unlock();
                self.running_mu.unlock();
                return;
            }

            self.released_state = self.running_state;
            self.released_mu.unlock();
            self.running_mu.unlock();

            self.subscribers_mu.lock();
            if (self.subscribers_notifying) {
                self.subscribers_mu.unlock();
                @panic("zux.component.ui.flow.tick cannot reenter subscriber notification");
            }
            self.subscribers_notifying = true;
            const subscribers = self.subscribers.items;
            self.subscribers_mu.unlock();
            defer {
                self.subscribers_mu.lock();
                self.subscribers_notifying = false;
                self.subscribers_mu.unlock();
            }

            for (subscribers) |subscriber| {
                subscriber.notify(.{
                    .label = "ui_flow",
                    .tick_count = tick_count,
                });
            }
        }

        pub fn move(self: *Self, direction: flow_event.Direction, edge_id: u32) bool {
            self.running_mu.lock();
            defer self.running_mu.unlock();

            const edge = edgeLabel(edge_id) orelse return false;
            const next_node_id = switch (direction) {
                .forward => dag.forward(nodeId(self.running_state.node), edge_id),
                .reverse => dag.reverse(nodeId(self.running_state.node), edge_id),
            } orelse {
                return self.running_state.setNegative(direction, edge);
            };

            const next_node = nodeLabel(next_node_id);
            const negative_cleared = self.running_state.clearNegative();
            if (self.running_state.node == next_node and !negative_cleared) return false;

            self.running_state.node = next_node;
            return true;
        }

        pub fn reset(self: *Self) bool {
            self.running_mu.lock();
            defer self.running_mu.unlock();

            const initial_node = nodeLabel(dag.initial_node_id);
            const negative_cleared = self.running_state.clearNegative();
            if (self.running_state.node == initial_node and !negative_cleared) return false;

            self.running_state.node = initial_node;
            return true;
        }

        pub fn reduce(store: anytype, message: Message, emit: Emitter) !usize {
            _ = emit;

            return switch (message.body) {
                .ui_flow_move => |move_event| if (store.move(move_event.direction, move_event.edge_id)) 1 else 0,
                .ui_flow_reset => if (store.reset()) 1 else 0,
                else => 0,
            };
        }

        fn nodeId(node: NodeLabel) u32 {
            return @intFromEnum(node);
        }

        fn nodeLabel(node_id: u32) NodeLabel {
            const count = @typeInfo(NodeLabel).@"enum".fields.len;
            if (count == 0 or node_id >= @as(u32, @intCast(count))) unreachable;
            return @enumFromInt(node_id);
        }

        fn edgeLabel(edge_id: u32) ?@FieldType(FlowState.Negative, "edge") {
            const EdgeLabel = @FieldType(FlowState.Negative, "edge");
            const count = @typeInfo(EdgeLabel).@"enum".fields.len;
            if (count == 0 or edge_id >= @as(u32, @intCast(count))) return null;
            return @enumFromInt(edge_id);
        }

        fn stateEql(a: FlowState, b: FlowState) bool {
            return a.node == b.node and FlowState.negativeEql(a.negative, b.negative);
        }
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const LinearFlow = comptime blk: {
        var builder = Builder.init();
        builder.addNode(.idle);
        builder.addNode(.searching);
        builder.addNode(.paired);
        builder.setInitial(.idle);
        builder.addEdge(.idle, .searching, .start);
        builder.addEdge(.searching, .paired, .found);
        break :blk builder.build();
    };
    const BranchFlow = comptime blk: {
        var builder = Builder.init();
        builder.addNode(.idle);
        builder.addNode(.manual);
        builder.addNode(.auto);
        builder.addNode(.done);
        builder.setInitial(.idle);
        builder.addEdge(.idle, .manual, .choose_manual);
        builder.addEdge(.idle, .auto, .choose_auto);
        builder.addEdge(.manual, .done, .finish_manual);
        builder.addEdge(.auto, .done, .finish_auto);
        break :blk builder.build();
    };

    const LinearFlowStore = LinearFlow.Reducer(lib);
    const BranchFlowStore = BranchFlow.Reducer(lib);

    const TestCase = struct {
        fn move_respects_allowed_edges_and_reset(testing: anytype, allocator: lib.mem.Allocator) !void {
            var flow = LinearFlowStore.init(allocator, .{});
            defer flow.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var noop = NoopSink{};
            const emit = Emitter.init(&noop);

            try testing.expectEqual(LinearFlow.NodeLabel.idle, flow.get().node);
            try testing.expect(LinearFlow.State.negativeEql(null, flow.get().negative));

            try testing.expectEqual(@as(usize, 0), try LinearFlowStore.reduce(&flow, .{
                .origin = .manual,
                .body = .{
                    .ui_flow_move = .{
                        .direction = .forward,
                        .edge_id = 99,
                    },
                },
            }, emit));
            flow.tick();
            try testing.expectEqual(LinearFlow.NodeLabel.idle, flow.get().node);
            try testing.expect(LinearFlow.State.negativeEql(null, flow.get().negative));

            try testing.expectEqual(@as(usize, 1), try LinearFlowStore.reduce(&flow, .{
                .origin = .manual,
                .body = .{
                    .ui_flow_move = .{
                        .direction = .forward,
                        .edge_id = @intFromEnum(LinearFlow.EdgeLabel.found),
                    },
                },
            }, emit));
            flow.tick();
            try testing.expectEqual(LinearFlow.NodeLabel.idle, flow.get().node);
            try testing.expect(LinearFlow.State.negativeEql(.{
                .direction = .forward,
                .edge = .found,
            }, flow.get().negative));

            try testing.expectEqual(@as(usize, 0), try LinearFlowStore.reduce(&flow, .{
                .origin = .manual,
                .body = .{
                    .ui_flow_move = .{
                        .direction = .forward,
                        .edge_id = @intFromEnum(LinearFlow.EdgeLabel.found),
                    },
                },
            }, emit));

            try testing.expectEqual(@as(usize, 1), try LinearFlowStore.reduce(&flow, .{
                .origin = .manual,
                .body = .{
                    .ui_flow_move = .{
                        .direction = .forward,
                        .edge_id = @intFromEnum(LinearFlow.EdgeLabel.start),
                    },
                },
            }, emit));
            flow.tick();
            try testing.expectEqual(LinearFlow.NodeLabel.searching, flow.get().node);
            try testing.expect(LinearFlow.State.negativeEql(null, flow.get().negative));

            try testing.expectEqual(@as(usize, 1), try LinearFlowStore.reduce(&flow, .{
                .origin = .manual,
                .body = .{
                    .ui_flow_move = .{
                        .direction = .reverse,
                        .edge_id = @intFromEnum(LinearFlow.EdgeLabel.found),
                    },
                },
            }, emit));
            flow.tick();
            try testing.expectEqual(LinearFlow.NodeLabel.searching, flow.get().node);
            try testing.expect(LinearFlow.State.negativeEql(.{
                .direction = .reverse,
                .edge = .found,
            }, flow.get().negative));

            try testing.expectEqual(@as(usize, 1), try LinearFlowStore.reduce(&flow, .{
                .origin = .manual,
                .body = .{
                    .ui_flow_reset = .{},
                },
            }, emit));
            flow.tick();
            try testing.expectEqual(LinearFlow.NodeLabel.idle, flow.get().node);
            try testing.expect(LinearFlow.State.negativeEql(null, flow.get().negative));
        }

        fn branch_forward_and_reverse_moves_work(testing: anytype, allocator: lib.mem.Allocator) !void {
            var flow = BranchFlowStore.init(allocator, .{});
            defer flow.deinit();

            const NoopSink = struct {
                pub fn emit(_: *@This(), _: Message) !void {}
            };
            var noop = NoopSink{};
            const emit = Emitter.init(&noop);

            try testing.expectEqual(BranchFlow.NodeLabel.idle, flow.get().node);

            try testing.expectEqual(@as(usize, 1), try BranchFlowStore.reduce(&flow, .{
                .origin = .manual,
                .body = .{
                    .ui_flow_move = .{
                        .direction = .forward,
                        .edge_id = @intFromEnum(BranchFlow.EdgeLabel.choose_auto),
                    },
                },
            }, emit));
            flow.tick();
            try testing.expectEqual(BranchFlow.NodeLabel.auto, flow.get().node);
            try testing.expect(BranchFlow.State.negativeEql(null, flow.get().negative));

            try testing.expectEqual(@as(usize, 1), try BranchFlowStore.reduce(&flow, .{
                .origin = .manual,
                .body = .{
                    .ui_flow_move = .{
                        .direction = .forward,
                        .edge_id = @intFromEnum(BranchFlow.EdgeLabel.choose_manual),
                    },
                },
            }, emit));
            flow.tick();
            try testing.expectEqual(BranchFlow.NodeLabel.auto, flow.get().node);
            try testing.expect(BranchFlow.State.negativeEql(.{
                .direction = .forward,
                .edge = .choose_manual,
            }, flow.get().negative));

            try testing.expectEqual(@as(usize, 1), try BranchFlowStore.reduce(&flow, .{
                .origin = .manual,
                .body = .{
                    .ui_flow_move = .{
                        .direction = .forward,
                        .edge_id = @intFromEnum(BranchFlow.EdgeLabel.finish_auto),
                    },
                },
            }, emit));
            flow.tick();
            try testing.expectEqual(BranchFlow.NodeLabel.done, flow.get().node);
            try testing.expect(BranchFlow.State.negativeEql(null, flow.get().negative));

            try testing.expectEqual(@as(usize, 1), try BranchFlowStore.reduce(&flow, .{
                .origin = .manual,
                .body = .{
                    .ui_flow_move = .{
                        .direction = .reverse,
                        .edge_id = @intFromEnum(BranchFlow.EdgeLabel.finish_auto),
                    },
                },
            }, emit));
            flow.tick();
            try testing.expectEqual(BranchFlow.NodeLabel.auto, flow.get().node);
            try testing.expect(BranchFlow.State.negativeEql(null, flow.get().negative));
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

            TestCase.move_respects_allowed_edges_and_reset(testing, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.branch_forward_and_reverse_moves_work(testing, allocator) catch |err| {
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
