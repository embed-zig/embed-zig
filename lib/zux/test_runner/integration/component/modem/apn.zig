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
            wrong_sim,
            wrong_registration,
            wrong_packet,
            wrong_apn,
            wrong_signal_presence,
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
                1 => checkState(state, "internet"),
                2 => checkState(state, "iot"),
                3 => checkState(state, ""),
                else => fail(.unexpected_callback_count),
            }
        }

        fn driveSequence(app: *BuiltApp) !void {
            try app.modem_data_apn_changed(.cell, "internet");
            try waitForCallbackCount(1);

            try app.modem_data_apn_changed(.cell, "iot");
            try waitForCallbackCount(2);

            try app.modem_data_apn_changed(.cell, "");
            try waitForCallbackCount(3);
        }

        fn checkState(state: component_modem.State, expected_apn: []const u8) void {
            if (state.source_id != 51) {
                fail(.wrong_source_id);
                return;
            }
            if (state.sim != .unknown) {
                fail(.wrong_sim);
                return;
            }
            if (state.registration != .offline) {
                fail(.wrong_registration);
                return;
            }
            if (state.packet != .detached) {
                fail(.wrong_packet);
                return;
            }
            if (!lib.mem.eql(u8, state.apn(), expected_apn)) {
                fail(.wrong_apn);
                return;
            }
            if (state.signal != null) {
                fail(.wrong_signal_presence);
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
