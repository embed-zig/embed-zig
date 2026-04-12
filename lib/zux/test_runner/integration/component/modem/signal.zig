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
            missing_signal,
            wrong_rssi,
            wrong_ber,
            wrong_rat,
            wrong_apn,
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
                1 => checkSignal(state, -89, 7, .lte),
                2 => checkSignal(state, -74, 3, .lte_m),
                3 => checkSignal(state, -61, null, .nr5g),
                else => fail(.unexpected_callback_count),
            }
        }

        fn driveSequence(app: *BuiltApp) !void {
            try app.modem_network_signal_changed(.cell, common.signal(-89, 7, .lte));
            try waitForCallbackCount(1);

            try app.modem_network_signal_changed(.cell, common.signal(-74, 3, .lte_m));
            try waitForCallbackCount(2);

            try app.modem_network_signal_changed(.cell, common.signal(-61, null, .nr5g));
            try waitForCallbackCount(3);
        }

        fn checkSignal(
            state: component_modem.State,
            expected_rssi_dbm: i16,
            expected_ber: ?u8,
            expected_rat: component_modem.Rat,
        ) void {
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
            const signal = state.signal orelse {
                fail(.missing_signal);
                return;
            };
            if (signal.rssi_dbm != expected_rssi_dbm) {
                fail(.wrong_rssi);
                return;
            }
            if (signal.ber != expected_ber) {
                fail(.wrong_ber);
                return;
            }
            if (signal.rat != expected_rat) {
                fail(.wrong_rat);
                return;
            }
            if (state.apn().len != 0) {
                fail(.wrong_apn);
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
