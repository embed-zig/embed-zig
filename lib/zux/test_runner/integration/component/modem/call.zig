const testing_api = @import("testing");

const common = @import("common.zig");

const component_modem = common.component_modem;

fn TestCase(comptime lib: type, comptime BuiltApp: type) type {
    return struct {
        const Self = @This();
        const Failure = enum {
            missing_callback_count,
            unexpected_callback_count,
            wrong_source_id,
            missing_call,
            wrong_call_id,
            wrong_direction,
            wrong_state,
            wrong_number,
            wrong_end_reason,
        };
        const AtomicUsize = lib.atomic.Value(usize);
        const AtomicU8 = lib.atomic.Value(u8);

        var callback_calls: AtomicUsize = AtomicUsize.init(0);
        var callback_failure: AtomicU8 = AtomicU8.init(0);
        const expected_callback_count = 3;

        pub fn init(self: *Self, allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
            reset();
        }

        pub fn run(self: *Self, t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;

            var dummy_modem = common.DummyModemImpl{};
            var app = BuiltApp.init(.{
                .allocator = allocator,
                .cell = common.makeAdapter(&dummy_modem),
            }) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer app.deinit();

            app.store.handle("net/modem", Self.onModem) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer _ = app.store.unhandle("net/modem", Self.onModem);

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
            return true;
        }

        pub fn deinit(self: *Self, allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }

        pub fn onModem(stores: *BuiltApp.Store.Stores) void {
            const callback_count = callback_calls.fetchAdd(1, .seq_cst) + 1;
            const state = stores.cell.get();
            switch (callback_count) {
                1 => checkCallState(state, .incoming, null),
                2 => checkCallState(state, .active, null),
                3 => checkCallState(state, null, .remote_hangup),
                else => fail(.unexpected_callback_count),
            }
        }

        fn driveSequence(app: *BuiltApp) !void {
            try app.modem_call_incoming(.cell, .{
                .call_id = 7,
                .direction = .incoming,
                .number = "10086",
            });
            try waitForCallbackCount(1);

            try app.modem_call_state_changed(.cell, .{
                .call_id = 7,
                .direction = .incoming,
                .state = .active,
                .number = "10086",
            });
            try waitForCallbackCount(2);

            try app.modem_call_ended(.cell, .{
                .call_id = 7,
                .reason = .remote_hangup,
            });
            try waitForCallbackCount(3);
        }

        fn checkCallState(
            state: component_modem.State,
            expected_state: ?component_modem.CallState,
            expected_end_reason: ?component_modem.CallEndReason,
        ) void {
            if (state.source_id != 51) {
                fail(.wrong_source_id);
                return;
            }
            const call = state.call orelse {
                fail(.missing_call);
                return;
            };
            if (call.call_id != 7) {
                fail(.wrong_call_id);
                return;
            }
            if (call.direction != .incoming) {
                fail(.wrong_direction);
                return;
            }
            if (call.state != expected_state) {
                fail(.wrong_state);
                return;
            }
            if (call.end_reason != expected_end_reason) {
                fail(.wrong_end_reason);
                return;
            }
            if (!lib.mem.eql(u8, call.number(), "10086")) {
                fail(.wrong_number);
            }
        }

        fn reset() void {
            callback_calls.store(0, .seq_cst);
            callback_failure.store(0, .seq_cst);
        }

        fn fail(next: Failure) void {
            const encoded: u8 = @as(u8, @intFromEnum(next)) + 1;
            _ = callback_failure.cmpxchgStrong(0, encoded, .seq_cst, .seq_cst);
        }

        fn currentCallbackCalls() usize {
            return callback_calls.load(.seq_cst);
        }

        fn currentFailure() ?Failure {
            const encoded = callback_failure.load(.seq_cst);
            if (encoded == 0) return null;
            return @enumFromInt(encoded - 1);
        }

        fn waitForCallbackCount(expected: usize) !void {
            var attempts: usize = 0;
            while (attempts < 300) : (attempts += 1) {
                if (currentFailure() != null) return error.CallbackFailed;
                if (currentCallbackCalls() >= expected) return;
                lib.Thread.sleep(10 * lib.time.ns_per_ms);
            }
            fail(.missing_callback_count);
            return error.TimedOut;
        }
    };
}

pub fn make(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
    const BuiltApp = comptime common.makeBuiltApp(lib, Channel);
    const Case = TestCase(lib, BuiltApp);

    const Holder = struct {
        var runner: Case = .{};
    };
    return testing_api.TestRunner.make(Case).new(&Holder.runner);
}
