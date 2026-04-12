const testing_api = @import("testing");

const Assembler = @import("../../../../Assembler.zig");

fn makeBuiltApp(comptime lib: type, comptime Channel: fn (type) type) type {
    const AssemblerType = Assembler.make(lib, .{}, Channel);
    var assembler = AssemblerType.init();
    assembler.addOverlay(.loading, 41, .{});
    assembler.setState("ui/overlay", .{.loading});

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
            wrong_visible,
            wrong_name,
            wrong_blocking,
            timed_out_waiting_for_overlay,
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

            app.store.handle("ui/overlay", Self.onOverlay) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer _ = app.store.unhandle("ui/overlay", Self.onOverlay);

            const initial = app.store.stores.loading.get();
            if (initial.visible != false or !lib.mem.eql(u8, initial.nameSlice(), "") or initial.blocking != false) {
                t.logFatal("invalid initial overlay state");
                return false;
            }

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

            const final = app.store.stores.loading.get();
            if (final.visible != true or !lib.mem.eql(u8, final.nameSlice(), "toast") or final.blocking != false) {
                t.logFatal("invalid final overlay state");
                return false;
            }
            return true;
        }

        pub fn deinit(self: *Self, allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }

        pub fn onOverlay(stores: *BuiltApp.Store.Stores) void {
            callback_mu.lock();
            defer callback_mu.unlock();

            callback_calls += 1;
            const state = stores.loading.get();
            switch (callback_calls) {
                1 => checkStateLocked(state, true, "loading", true),
                2 => checkStateLocked(state, true, "loading", false),
                3 => checkStateLocked(state, true, "popup", false),
                4 => checkStateLocked(state, false, "popup", false),
                5 => checkStateLocked(state, true, "toast", false),
                else => failLocked(.unexpected_callback_count),
            }
        }

        fn driveSequence(app: *BuiltApp) !void {
            try app.show_overlay(.loading, "loading", true);
            try waitForCallbackCount(1);

            try app.show_overlay(.loading, "loading", true);
            lib.Thread.sleep(20 * lib.time.ns_per_ms);
            if (currentCallbackCalls() != 1) return error.UnexpectedCallback;

            try app.set_overlay_blocking(.loading, false);
            try waitForCallbackCount(2);

            try app.set_overlay_name(.loading, "popup");
            try waitForCallbackCount(3);

            try app.hide_overlay(.loading);
            try waitForCallbackCount(4);

            try app.hide_overlay(.loading);
            lib.Thread.sleep(20 * lib.time.ns_per_ms);
            if (currentCallbackCalls() != 4) return error.UnexpectedCallback;

            try app.show_overlay(.loading, "toast", false);
            try waitForCallbackCount(5);
        }

        fn checkStateLocked(state: anytype, expected_visible: bool, expected_name: []const u8, expected_blocking: bool) void {
            if (state.visible != expected_visible) {
                failLocked(.wrong_visible);
                return;
            }
            if (!lib.mem.eql(u8, state.nameSlice(), expected_name)) {
                failLocked(.wrong_name);
                return;
            }
            if (state.blocking != expected_blocking) {
                failLocked(.wrong_blocking);
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
            failLocked(.timed_out_waiting_for_overlay);
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
