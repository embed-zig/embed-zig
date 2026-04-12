const testing_api = @import("testing");

const Assembler = @import("../../../../Assembler.zig");
const ui_flow = @import("../../../../component/ui/flow.zig");

const PairingFlow = blk: {
    var builder = ui_flow.Builder.init();
    builder.addNode(.idle);
    builder.addNode(.searching);
    builder.addNode(.confirming);
    builder.addNode(.done);
    builder.setInitial(.idle);
    builder.addEdge(.idle, .searching, .start);
    builder.addEdge(.idle, .confirming, .reenter);
    builder.addEdge(.searching, .done, .found);
    builder.addEdge(.confirming, .done, .confirm);
    break :blk builder.build();
};

fn makeBuiltApp(comptime lib: type, comptime Channel: fn (type) type) type {
    const AssemblerType = Assembler.make(lib, .{}, Channel);
    var assembler = AssemblerType.init();
    assembler.addFlow(.pairing, 31, PairingFlow);
    assembler.setState("ui/flow", .{.pairing});

    const BuildConfig = assembler.BuildConfig();
    const build_config: BuildConfig = .{};
    return assembler.build(build_config);
}

fn TestCase(comptime lib: type, comptime BuiltApp: type) type {
    return struct {
        const Self = @This();
        const Failure = enum {
            missing_callback_count,
            unexpected_callback_count,
            wrong_node_id,
            wrong_negative_state,
            timed_out_waiting_for_flow,
        };

        var callback_mu: lib.Thread.Mutex = .{};
        var callback_calls: usize = 0;
        var callback_failure: ?Failure = null;
        const expected_callback_count = 5;

        pub fn init(self: *Self, allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
            reset();
        }

        pub fn run(self: *Self, t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;

            var app = BuiltApp.init(.{
                .allocator = allocator,
            }) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer app.deinit();

            app.store.handle("ui/flow", Self.onFlow) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer _ = app.store.unhandle("ui/flow", Self.onFlow);

            const initial = app.store.stores.pairing.get();
            if (initial.node != .idle) {
                t.logFatal("invalid initial flow state");
                return false;
            }
            if (initial.negative != null) {
                t.logFatal("invalid initial negative flow state");
                return false;
            }
            checkMoves(t, allocator, &app, &.{
                .{ .direction = .forward, .edge = .start },
                .{ .direction = .forward, .edge = .reenter },
            });

            app.start() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };

            driveSequence(&app) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };

            app.stop() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };

            if (currentFailure()) |failure| {
                t.logFatal(@tagName(failure));
                return false;
            }
            if (currentCallbackCalls() != expected_callback_count) {
                t.logFatal(@tagName(Failure.missing_callback_count));
                return false;
            }

            const final = app.store.stores.pairing.get();
            if (final.node != .confirming) {
                t.logFatal("invalid final flow state");
                return false;
            }
            checkMoves(t, allocator, &app, &.{
                .{ .direction = .forward, .edge = .confirm },
                .{ .direction = .reverse, .edge = .reenter },
            });
            return true;
        }

        pub fn deinit(self: *Self, allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }

        pub fn onFlow(stores: *BuiltApp.Store.Stores) void {
            callback_mu.lock();
            defer callback_mu.unlock();

            callback_calls += 1;
            const state = stores.pairing.get();
            switch (callback_calls) {
                1 => checkStateLocked(state, .searching),
                2 => checkNegativeLocked(state, .searching, .{
                    .direction = .reverse,
                    .edge = .reenter,
                }),
                3 => checkStateLocked(state, .done),
                4 => checkStateLocked(state, .idle),
                5 => checkStateLocked(state, .confirming),
                else => failLocked(.unexpected_callback_count),
            }
        }

        fn driveSequence(app: *BuiltApp) !void {
            try app.move_flow(.pairing, .forward, .start);
            try waitForCallbackCount(1);

            try app.move_flow(.pairing, .reverse, .reenter);
            try waitForCallbackCount(2);

            try app.move_flow(.pairing, .forward, .found);
            try waitForCallbackCount(3);

            try app.reset_flow(.pairing);
            try waitForCallbackCount(4);

            try app.reset_flow(.pairing);
            lib.Thread.sleep(20 * lib.time.ns_per_ms);
            if (currentCallbackCalls() != 4) return error.UnexpectedCallback;

            try app.move_flow(.pairing, .forward, .reenter);
            try waitForCallbackCount(5);
        }

        fn checkStateLocked(state: PairingFlow.State, expected_node: PairingFlow.NodeLabel) void {
            if (state.node != expected_node) {
                failLocked(.wrong_node_id);
            }
            if (state.negative != null) {
                failLocked(.wrong_negative_state);
            }
        }

        fn checkNegativeLocked(
            state: PairingFlow.State,
            expected_node: PairingFlow.NodeLabel,
            expected_negative: PairingFlow.State.Negative,
        ) void {
            if (state.node != expected_node) {
                failLocked(.wrong_node_id);
            }
            if (!PairingFlow.State.negativeEql(expected_negative, state.negative)) {
                failLocked(.wrong_negative_state);
            }
        }

        fn checkMoves(
            t: *testing_api.T,
            allocator: lib.mem.Allocator,
            app: *BuiltApp,
            expected: []const BuiltApp.FlowMove(.pairing),
        ) void {
            const moves = app.available_moves(.pairing, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return;
            };
            defer allocator.free(moves);

            if (moves.len != expected.len) {
                t.logFatal("invalid available flow move count");
                return;
            }

            for (expected, 0..) |expected_move, i| {
                const actual = moves[i];
                if (actual.direction != expected_move.direction or actual.edge != expected_move.edge) {
                    t.logFatal("invalid available flow move");
                    return;
                }
            }
        }

        fn reset() void {
            callback_mu.lock();
            defer callback_mu.unlock();
            callback_calls = 0;
            callback_failure = null;
        }

        fn failLocked(next: Failure) void {
            if (callback_failure == null) {
                callback_failure = next;
            }
        }

        fn currentCallbackCalls() usize {
            callback_mu.lock();
            defer callback_mu.unlock();
            return callback_calls;
        }

        fn currentFailure() ?Failure {
            callback_mu.lock();
            defer callback_mu.unlock();
            return callback_failure;
        }

        fn waitForCallbackCount(expected: usize) !void {
            var attempts: usize = 0;
            while (attempts < 300) : (attempts += 1) {
                if (currentCallbackCalls() >= expected) return;
                lib.Thread.sleep(10 * lib.time.ns_per_ms);
            }
            callback_mu.lock();
            defer callback_mu.unlock();
            failLocked(.timed_out_waiting_for_flow);
            return error.TimedOut;
        }
    };
}

pub fn make(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
    const BuiltApp = comptime makeBuiltApp(lib, Channel);
    const Case = TestCase(lib, BuiltApp);

    const Holder = struct {
        var runner: Case = .{};
    };
    return testing_api.TestRunner.make(Case).new(&Holder.runner);
}
