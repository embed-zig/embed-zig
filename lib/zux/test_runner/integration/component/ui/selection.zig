const testing_api = @import("testing");

const Assembler = @import("../../../../Assembler.zig");

fn makeBuiltApp(comptime lib: type, comptime Channel: fn (type) type) type {
    const AssemblerType = Assembler.make(lib, .{}, Channel);
    var assembler = AssemblerType.init();
    assembler.addSelection(.menu, 61, .{
        .count = 3,
        .loop = true,
    });
    assembler.setState("ui/selection", .{.menu});

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
            wrong_index,
            wrong_count,
            wrong_loop,
            timed_out_waiting_for_selection,
        };

        var callback_mu: lib.Thread.Mutex = .{};
        var callback_calls: usize = 0;
        var callback_failure: ?Failure = null;
        const expected_callback_count = 8;

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

            app.store.handle("ui/selection", Self.onSelection) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer _ = app.store.unhandle("ui/selection", Self.onSelection);

            const initial = app.store.stores.menu.get();
            if (initial.index != 0 or initial.count != 3 or initial.loop != true) {
                t.logFatal("invalid initial selection state");
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

            const final = app.store.stores.menu.get();
            if (final.index != 0 or final.count != 2 or final.loop != false) {
                t.logFatal("invalid final selection state");
                return false;
            }
            return true;
        }

        pub fn deinit(self: *Self, allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }

        pub fn onSelection(stores: *BuiltApp.Store.Stores) void {
            callback_mu.lock();
            defer callback_mu.unlock();

            callback_calls += 1;
            const state = stores.menu.get();
            switch (callback_calls) {
                1 => checkStateLocked(state, 1, 3, true),
                2 => checkStateLocked(state, 2, 3, true),
                3 => checkStateLocked(state, 0, 3, true),
                4 => checkStateLocked(state, 0, 3, false),
                5 => checkStateLocked(state, 0, 5, false),
                6 => checkStateLocked(state, 4, 5, false),
                7 => checkStateLocked(state, 1, 2, false),
                8 => checkStateLocked(state, 0, 2, false),
                else => failLocked(.unexpected_callback_count),
            }
        }

        fn driveSequence(app: *BuiltApp) !void {
            try app.next_selection(.menu);
            try waitForCallbackCount(1);

            try app.next_selection(.menu);
            try waitForCallbackCount(2);

            try app.next_selection(.menu);
            try waitForCallbackCount(3);

            try app.set_selection_loop(.menu, false);
            try waitForCallbackCount(4);

            try app.prev_selection(.menu);
            lib.Thread.sleep(20 * lib.time.ns_per_ms);
            if (currentCallbackCalls() != 4) return error.UnexpectedCallback;

            try app.set_selection_count(.menu, 5);
            try waitForCallbackCount(5);

            try app.set_selection(.menu, 4);
            try waitForCallbackCount(6);

            try app.set_selection_count(.menu, 2);
            try waitForCallbackCount(7);

            try app.reset_selection(.menu);
            try waitForCallbackCount(8);
        }

        fn checkStateLocked(state: anytype, expected_index: usize, expected_count: usize, expected_loop: bool) void {
            if (state.index != expected_index) {
                failLocked(.wrong_index);
                return;
            }
            if (state.count != expected_count) {
                failLocked(.wrong_count);
                return;
            }
            if (state.loop != expected_loop) {
                failLocked(.wrong_loop);
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
            failLocked(.timed_out_waiting_for_selection);
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
