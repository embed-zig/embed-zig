const testing_api = @import("testing");

const common = @import("common.zig");
const drivers = @import("drivers");

const Addr = common.Addr;
const component_wifi = common.component_wifi;

fn TestCase(comptime lib: type, comptime BuiltApp: type) type {
    return struct {
        const Self = @This();
        const Failure = enum {
            missing_callback_count,
            unexpected_callback_count,
            wrong_source_id,
            wrong_ssid,
            wrong_scanning,
            wrong_connected,
            wrong_has_ip,
            wrong_rssi,
            wrong_address,
            wrong_dns1,
            wrong_reason,
        };
        const AtomicUsize = lib.atomic.Value(usize);
        const AtomicU8 = lib.atomic.Value(u8);

        var callback_calls: AtomicUsize = AtomicUsize.init(0);
        var callback_failure: AtomicU8 = AtomicU8.init(0);
        const expected_callback_count = 5;

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

            app.store.handle("net/wifi/sta", Self.onSta) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer _ = app.store.unhandle("net/wifi/sta", Self.onSta);

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

        pub fn onSta(stores: *BuiltApp.Store.Stores) void {
            const callback_count = callback_calls.fetchAdd(1, .seq_cst) + 1;
            const state = stores.sta.get();
            switch (callback_count) {
                1 => checkScanState(state),
                2 => checkConnectedState(state),
                3 => checkGotIpState(state),
                4 => checkLostIpState(state),
                5 => checkDisconnectedState(state),
                else => fail(.unexpected_callback_count),
            }
        }

        fn driveSequence(app: *BuiltApp) !void {
            try app.wifi_sta_scan_result(.sta, .{
                .ssid = "wifi-lab",
                .bssid = .{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60 },
                .channel = 6,
                .rssi = -47,
                .security = .wpa2,
            });
            try waitForCallbackCount(1);

            try app.wifi_sta_connected(.sta, .{
                .ssid = "wifi-lab",
                .bssid = .{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60 },
                .channel = 6,
                .rssi = -41,
                .security = .wpa2,
            });
            try waitForCallbackCount(2);

            try app.wifi_sta_got_ip(.sta, .{
                .address = Addr.from4(.{ 192, 168, 4, 2 }),
                .gateway = Addr.from4(.{ 192, 168, 4, 1 }),
                .netmask = Addr.from4(.{ 255, 255, 255, 0 }),
                .dns1 = Addr.from4(.{ 1, 1, 1, 1 }),
                .dns2 = Addr.from4(.{ 8, 8, 8, 8 }),
            });
            try waitForCallbackCount(3);

            try app.wifi_sta_lost_ip(.sta);
            try waitForCallbackCount(4);

            try app.wifi_sta_disconnected(.sta, .{
                .reason = 7,
            });
            try waitForCallbackCount(5);
        }

        fn checkBaseState(state: component_wifi.state.Sta) bool {
            if (state.source_id != 31) {
                fail(.wrong_source_id);
                return false;
            }
            if (!lib.mem.eql(u8, state.ssid(), "wifi-lab")) {
                fail(.wrong_ssid);
                return false;
            }
            return true;
        }

        fn checkScanState(state: component_wifi.state.Sta) void {
            if (!checkBaseState(state)) return;
            if (!state.scanning) {
                fail(.wrong_scanning);
                return;
            }
            if (state.connected) {
                fail(.wrong_connected);
                return;
            }
            if (state.has_ip) {
                fail(.wrong_has_ip);
                return;
            }
            if (state.last_rssi != @as(?i16, -47)) {
                fail(.wrong_rssi);
                return;
            }
            if (state.address != null) {
                fail(.wrong_address);
            }
        }

        fn checkConnectedState(state: component_wifi.state.Sta) void {
            if (!checkBaseState(state)) return;
            if (state.scanning) {
                fail(.wrong_scanning);
                return;
            }
            if (!state.connected) {
                fail(.wrong_connected);
                return;
            }
            if (state.has_ip) {
                fail(.wrong_has_ip);
                return;
            }
            if (state.last_rssi != @as(?i16, -41)) {
                fail(.wrong_rssi);
                return;
            }
            if (state.address != null) {
                fail(.wrong_address);
            }
        }

        fn checkGotIpState(state: component_wifi.state.Sta) void {
            if (!checkBaseState(state)) return;
            if (state.scanning) {
                fail(.wrong_scanning);
                return;
            }
            if (!state.connected) {
                fail(.wrong_connected);
                return;
            }
            if (!state.has_ip) {
                fail(.wrong_has_ip);
                return;
            }
            if (!common.optionalAddrEql(state.address, Addr.from4(.{ 192, 168, 4, 2 }))) {
                fail(.wrong_address);
                return;
            }
            if (!common.optionalAddrEql(state.dns1, Addr.from4(.{ 1, 1, 1, 1 }))) {
                fail(.wrong_dns1);
            }
        }

        fn checkLostIpState(state: component_wifi.state.Sta) void {
            if (!checkBaseState(state)) return;
            if (state.scanning) {
                fail(.wrong_scanning);
                return;
            }
            if (!state.connected) {
                fail(.wrong_connected);
                return;
            }
            if (state.has_ip) {
                fail(.wrong_has_ip);
                return;
            }
            if (state.address != null) {
                fail(.wrong_address);
                return;
            }
            if (state.dns1 != null) {
                fail(.wrong_dns1);
            }
        }

        fn checkDisconnectedState(state: component_wifi.state.Sta) void {
            if (!checkBaseState(state)) return;
            if (state.scanning) {
                fail(.wrong_scanning);
                return;
            }
            if (state.connected) {
                fail(.wrong_connected);
                return;
            }
            if (state.has_ip) {
                fail(.wrong_has_ip);
                return;
            }
            if (state.last_disconnect_reason != @as(?u16, 7)) {
                fail(.wrong_reason);
                return;
            }
            if (state.address != null) {
                fail(.wrong_address);
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
