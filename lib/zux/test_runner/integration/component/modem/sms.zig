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
            missing_sms,
            wrong_index,
            wrong_storage,
            wrong_sender,
            wrong_text,
            wrong_encoding,
        };
        const AtomicUsize = lib.atomic.Value(usize);
        const AtomicU8 = lib.atomic.Value(u8);

        var callback_calls: AtomicUsize = AtomicUsize.init(0);
        var callback_failure: AtomicU8 = AtomicU8.init(0);
        const expected_callback_count = 2;

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
                1 => checkSms(state, 9, .sim, "10010", "hi", .utf8),
                2 => checkSms(state, 10, .modem, "+8613800138000", "hello modem", .ucs2),
                else => fail(.unexpected_callback_count),
            }
        }

        fn driveSequence(app: *BuiltApp) !void {
            try app.modem_sms_received(.cell, .{
                .index = 9,
                .storage = .sim,
                .sender = "10010",
                .text = "hi",
                .encoding = .utf8,
            });
            try waitForCallbackCount(1);

            try app.modem_sms_received(.cell, .{
                .index = 10,
                .storage = .modem,
                .sender = "+8613800138000",
                .text = "hello modem",
                .encoding = .ucs2,
            });
            try waitForCallbackCount(2);
        }

        fn checkSms(
            state: component_modem.State,
            expected_index: u16,
            expected_storage: component_modem.SmsStorage,
            expected_sender: []const u8,
            expected_text: []const u8,
            expected_encoding: component_modem.SmsEncoding,
        ) void {
            if (state.source_id != 51) {
                fail(.wrong_source_id);
                return;
            }
            const sms = state.sms orelse {
                fail(.missing_sms);
                return;
            };
            if (sms.index != expected_index) {
                fail(.wrong_index);
                return;
            }
            if (sms.storage != expected_storage) {
                fail(.wrong_storage);
                return;
            }
            if (!lib.mem.eql(u8, sms.sender(), expected_sender)) {
                fail(.wrong_sender);
                return;
            }
            if (!lib.mem.eql(u8, sms.text(), expected_text)) {
                fail(.wrong_text);
                return;
            }
            if (sms.encoding != expected_encoding) {
                fail(.wrong_encoding);
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
