const testing_api = @import("testing");

const Assembler = @import("../../../../Assembler.zig");
const component_nfc = @import("../../../../component/Nfc.zig");
const drivers = @import("drivers");

fn makeBuiltApp(comptime lib: type, comptime Channel: fn (type) type) type {
    comptime {
        @setEvalBranchQuota(20_000);
    }
    const AssemblerType = Assembler.make(lib, .{
        .pipeline = .{
            .tick_interval_ns = lib.time.ns_per_ms,
        },
    }, Channel);
    var assembler = AssemblerType.init();
    assembler.addNfc(.reader, 21);
    assembler.setState("io/nfc", .{.reader});

    const BuildConfig = assembler.BuildConfig();
    const build_config: BuildConfig = .{
        .reader = drivers.nfc.Reader,
    };
    return assembler.build(build_config);
}

const DummyReaderImpl = struct {
    pub fn setEventCallback(_: *@This(), _: *const anyopaque, _: drivers.nfc.CallbackFn) void {}
    pub fn clearEventCallback(_: *@This()) void {}
};

fn TestCase(comptime lib: type, comptime BuiltApp: type) type {
    return struct {
        const Self = @This();
        const Failure = enum {
            missing_callback_count,
            unexpected_callback_count,
            wrong_source_id,
            wrong_card_type,
            wrong_uid,
            wrong_payload,
        };
        const AtomicUsize = lib.atomic.Value(usize);
        const AtomicU8 = lib.atomic.Value(u8);

        var callback_calls: AtomicUsize = AtomicUsize.init(0);
        var callback_failure: AtomicU8 = AtomicU8.init(0);

        pub fn init(self: *Self, allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
            reset();
        }

        pub fn run(self: *Self, t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;

            var dummy_reader = DummyReaderImpl{};
            var app = BuiltApp.init(.{
                .allocator = allocator,
                .reader = drivers.nfc.Reader.init(&dummy_reader),
            }) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer app.deinit();

            app.store.handle("io/nfc", Self.onNfc) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer _ = app.store.unhandle("io/nfc", Self.onNfc);

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
            if (currentCallbackCalls() != 2) {
                t.logFatal(@tagName(Failure.missing_callback_count));
                return false;
            }
            return true;
        }

        pub fn deinit(self: *Self, allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }

        pub fn onNfc(stores: *BuiltApp.Store.Stores) void {
            const callback_count = callback_calls.fetchAdd(1, .seq_cst) + 1;
            const state = stores.reader.get();
            switch (callback_count) {
                1 => checkFoundState(state),
                2 => checkReadState(state),
                else => fail(.unexpected_callback_count),
            }
        }

        fn driveSequence(app: *BuiltApp) !void {
            try app.nfc_found(.reader, &.{ 0x04, 0xA1, 0xB2, 0xC3 }, .ndef);
            try waitForCallbackCount(1);

            try app.nfc_read(.reader, &.{ 0x04, 0xA1, 0xB2, 0xC3 }, &.{ 0x03, 0x02, 0xD1, 0x01 }, .ndef);
            try waitForCallbackCount(2);
        }

        fn checkFoundState(state: component_nfc.State) void {
            if (state.source_id != 21) {
                fail(.wrong_source_id);
                return;
            }
            if (state.card_type != .ndef) {
                fail(.wrong_card_type);
                return;
            }
            if (!lib.mem.eql(u8, state.uid(), &.{ 0x04, 0xA1, 0xB2, 0xC3 })) {
                fail(.wrong_uid);
                return;
            }
            if (state.payload().len != 0) {
                fail(.wrong_payload);
            }
        }

        fn checkReadState(state: component_nfc.State) void {
            if (state.source_id != 21) {
                fail(.wrong_source_id);
                return;
            }
            if (state.card_type != .ndef) {
                fail(.wrong_card_type);
                return;
            }
            if (!lib.mem.eql(u8, state.uid(), &.{ 0x04, 0xA1, 0xB2, 0xC3 })) {
                fail(.wrong_uid);
                return;
            }
            if (!lib.mem.eql(u8, state.payload(), &.{ 0x03, 0x02, 0xD1, 0x01 })) {
                fail(.wrong_payload);
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
    const BuiltApp = comptime makeBuiltApp(lib, Channel);
    const Case = TestCase(lib, BuiltApp);

    const Holder = struct {
        var runner: Case = .{};
    };
    return testing_api.TestRunner.make(Case).new(&Holder.runner);
}
