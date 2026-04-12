const testing_api = @import("testing");

const common = @import("common.zig");
const drivers = @import("drivers");

const Addr = common.Addr;
const MacAddr = common.MacAddr;
const component_wifi = common.component_wifi;

fn TestCase(comptime lib: type, comptime BuiltApp: type) type {
    return struct {
        const Self = @This();
        const Failure = enum {
            missing_callback_count,
            unexpected_callback_count,
            wrong_source_id,
            wrong_ssid,
            wrong_active,
            wrong_client_count,
            wrong_last_client_mac,
            wrong_last_client_ip,
            wrong_last_client_aid,
            wrong_channel,
        };

        const client1: MacAddr = .{ 1, 2, 3, 4, 5, 6 };
        const client2: MacAddr = .{ 6, 5, 4, 3, 2, 1 };
        const AtomicUsize = lib.atomic.Value(usize);
        const AtomicU8 = lib.atomic.Value(u8);

        var callback_calls: AtomicUsize = AtomicUsize.init(0);
        var callback_failure: AtomicU8 = AtomicU8.init(0);
        const expected_callback_count = 7;

        pub fn init(self: *Self, allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
            reset();
        }

        pub fn run(self: *Self, t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;

            var dummy_sta = common.DummyStaImpl{};
            var dummy_ap = common.DummyApImpl{};
            var app = BuiltApp.init(.{
                .allocator = allocator,
                .sta = drivers.wifi.Sta.make(&dummy_sta),
                .ap = drivers.wifi.Ap.make(&dummy_ap),
            }) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer app.deinit();

            app.store.handle("net/wifi/ap", Self.onAp) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer _ = app.store.unhandle("net/wifi/ap", Self.onAp);

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

        pub fn onAp(stores: *BuiltApp.Store.Stores) void {
            const callback_count = callback_calls.fetchAdd(1, .seq_cst) + 1;
            const state = stores.ap.get();
            switch (callback_count) {
                1 => checkStartedState(state),
                2 => checkClient1JoinedState(state),
                3 => checkLeaseGrantedState(state),
                4 => checkClient2JoinedState(state),
                5 => checkLeaseReleasedState(state),
                6 => checkClient1LeftState(state),
                7 => checkStoppedState(state),
                else => fail(.unexpected_callback_count),
            }
        }

        fn driveSequence(app: *BuiltApp) !void {
            try app.wifi_ap_started(.ap, .{
                .ssid = "esp-ap",
                .channel = 11,
                .security = .wpa2,
            });
            try waitForCallbackCount(1);

            try app.wifi_ap_client_joined(.ap, .{
                .mac = client1,
                .ip = null,
                .aid = 3,
            });
            try waitForCallbackCount(2);

            try app.wifi_ap_lease_granted(.ap, .{
                .client_mac = client1,
                .client_ip = Addr.from4(.{ 192, 168, 4, 10 }),
            });
            try waitForCallbackCount(3);

            try app.wifi_ap_client_joined(.ap, .{
                .mac = client2,
                .ip = Addr.from4(.{ 192, 168, 4, 11 }),
                .aid = 4,
            });
            try waitForCallbackCount(4);

            try app.wifi_ap_lease_released(.ap, .{
                .client_mac = client1,
                .client_ip = Addr.from4(.{ 192, 168, 4, 10 }),
            });
            try waitForCallbackCount(5);

            try app.wifi_ap_client_left(.ap, .{
                .mac = client1,
                .ip = null,
                .aid = 3,
            });
            try waitForCallbackCount(6);

            try app.wifi_ap_stopped(.ap);
            try waitForCallbackCount(7);
        }

        fn checkBaseState(state: component_wifi.state.Ap) bool {
            if (state.source_id != 41) {
                fail(.wrong_source_id);
                return false;
            }
            if (!lib.mem.eql(u8, state.ssid(), "esp-ap")) {
                fail(.wrong_ssid);
                return false;
            }
            if (state.channel != 11) {
                fail(.wrong_channel);
                return false;
            }
            return true;
        }

        fn checkStartedState(state: component_wifi.state.Ap) void {
            if (!checkBaseState(state)) return;
            if (!state.active) {
                fail(.wrong_active);
                return;
            }
            if (state.client_count != 0) {
                fail(.wrong_client_count);
            }
        }

        fn checkClient1JoinedState(state: component_wifi.state.Ap) void {
            if (!checkBaseState(state)) return;
            if (!state.active) {
                fail(.wrong_active);
                return;
            }
            if (state.client_count != 1) {
                fail(.wrong_client_count);
                return;
            }
            if (state.last_client_mac == null or !common.macEql(state.last_client_mac.?, client1)) {
                fail(.wrong_last_client_mac);
                return;
            }
            if (state.last_client_ip != null) {
                fail(.wrong_last_client_ip);
                return;
            }
            if (state.last_client_aid != 3) {
                fail(.wrong_last_client_aid);
            }
        }

        fn checkLeaseGrantedState(state: component_wifi.state.Ap) void {
            if (!checkBaseState(state)) return;
            if (state.client_count != 1) {
                fail(.wrong_client_count);
                return;
            }
            if (state.last_client_mac == null or !common.macEql(state.last_client_mac.?, client1)) {
                fail(.wrong_last_client_mac);
                return;
            }
            if (!common.optionalAddrEql(state.last_client_ip, Addr.from4(.{ 192, 168, 4, 10 }))) {
                fail(.wrong_last_client_ip);
                return;
            }
            if (state.last_client_aid != 3) {
                fail(.wrong_last_client_aid);
            }
        }

        fn checkClient2JoinedState(state: component_wifi.state.Ap) void {
            if (!checkBaseState(state)) return;
            if (state.client_count != 2) {
                fail(.wrong_client_count);
                return;
            }
            if (state.last_client_mac == null or !common.macEql(state.last_client_mac.?, client2)) {
                fail(.wrong_last_client_mac);
                return;
            }
            if (!common.optionalAddrEql(state.last_client_ip, Addr.from4(.{ 192, 168, 4, 11 }))) {
                fail(.wrong_last_client_ip);
                return;
            }
            if (state.last_client_aid != 4) {
                fail(.wrong_last_client_aid);
            }
        }

        fn checkLeaseReleasedState(state: component_wifi.state.Ap) void {
            if (!checkBaseState(state)) return;
            if (state.client_count != 2) {
                fail(.wrong_client_count);
                return;
            }
            if (state.last_client_mac == null or !common.macEql(state.last_client_mac.?, client1)) {
                fail(.wrong_last_client_mac);
                return;
            }
            if (!common.optionalAddrEql(state.last_client_ip, Addr.from4(.{ 192, 168, 4, 10 }))) {
                fail(.wrong_last_client_ip);
                return;
            }
            if (state.last_client_aid != 4) {
                fail(.wrong_last_client_aid);
            }
        }

        fn checkClient1LeftState(state: component_wifi.state.Ap) void {
            if (!checkBaseState(state)) return;
            if (state.client_count != 1) {
                fail(.wrong_client_count);
                return;
            }
            if (state.last_client_mac == null or !common.macEql(state.last_client_mac.?, client1)) {
                fail(.wrong_last_client_mac);
                return;
            }
            if (state.last_client_ip != null) {
                fail(.wrong_last_client_ip);
                return;
            }
            if (state.last_client_aid != 3) {
                fail(.wrong_last_client_aid);
            }
        }

        fn checkStoppedState(state: component_wifi.state.Ap) void {
            if (!checkBaseState(state)) return;
            if (state.active) {
                fail(.wrong_active);
                return;
            }
            if (state.client_count != 0) {
                fail(.wrong_client_count);
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
