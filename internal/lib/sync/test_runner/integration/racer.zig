//! Racer test runner — exercises first-winner semantics and wait behavior.
//!
//! Accepts any type with the same shape as std
//! (lib.Thread, lib.atomic, lib.mem, lib.meta).
//! Can be compiled into firmware main.zig — no reliance on file-scope tests.
//!
//! Usage:
//!   try @import("sync").test_runner.integration.racer.run(std);
//!   try @import("sync").test_runner.integration.racer.run(stdz);

const root = @import("../../../sync.zig");
const context_mod = @import("context");
const stdz = @import("stdz");
const testing_api = @import("testing");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const W = struct {
        fn spawnAllocator(t: *testing_api.T, allocator: lib.mem.Allocator) !void {
            _ = t;
            try spawnAllocatorTests(lib, allocator);
        }
        fn zeroTask(t: *testing_api.T, allocator: lib.mem.Allocator) !void {
            _ = t;
            try zeroTaskTests(lib, allocator);
        }
        fn firstWinner(t: *testing_api.T, allocator: lib.mem.Allocator) !void {
            _ = t;
            try firstWinnerTests(lib, allocator);
        }
        fn raceContext(t: *testing_api.T, allocator: lib.mem.Allocator) !void {
            _ = t;
            try raceContextTests(lib, allocator);
        }
        fn cancel(t: *testing_api.T, allocator: lib.mem.Allocator) !void {
            _ = t;
            try cancelTests(lib, allocator);
        }
        fn doneAndWait(t: *testing_api.T, allocator: lib.mem.Allocator) !void {
            _ = t;
            try doneAndWaitTests(lib, allocator);
        }
        fn doneSignalRejection(t: *testing_api.T, allocator: lib.mem.Allocator) !void {
            _ = t;
            try doneSignalPublishesRejectionBeforeReadyFlagTests(lib, allocator);
        }
        fn exhausted(t: *testing_api.T, allocator: lib.mem.Allocator) !void {
            _ = t;
            try exhaustedTests(lib, allocator);
        }
        fn initOom(t: *testing_api.T, allocator: lib.mem.Allocator) !void {
            _ = t;
            _ = allocator;
            try initOomTests(lib);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            t.parallel();
            // Worker stacks: only this thread runs the suite body; spawned helpers use `Thread.spawn` defaults.
            t.run("spawn_allocator", testing_api.TestRunner.fromFn(lib, 48 * 1024, W.spawnAllocator));
            t.run("zero_task", testing_api.TestRunner.fromFn(lib, 48 * 1024, W.zeroTask));
            t.run("first_winner", testing_api.TestRunner.fromFn(lib, 128 * 1024, W.firstWinner));
            t.run("race_context", testing_api.TestRunner.fromFn(lib, 192 * 1024, W.raceContext));
            t.run("cancel", testing_api.TestRunner.fromFn(lib, 128 * 1024, W.cancel));
            t.run("done_and_wait", testing_api.TestRunner.fromFn(lib, 128 * 1024, W.doneAndWait));
            t.run("done_signal_rejection", testing_api.TestRunner.fromFn(lib, 128 * 1024, W.doneSignalRejection));
            t.run("exhausted", testing_api.TestRunner.fromFn(lib, 64 * 1024, W.exhausted));
            t.run("init_oom", testing_api.TestRunner.fromFn(lib, 40 * 1024, W.initOom));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}

pub fn run(comptime lib: type) !void {
    try runSequentialSuite(lib, lib.testing.allocator);
}

fn runSequentialSuite(comptime lib: type, allocator: lib.mem.Allocator) !void {
    try spawnAllocatorTests(lib, allocator);
    try zeroTaskTests(lib, allocator);
    try firstWinnerTests(lib, allocator);
    try raceContextTests(lib, allocator);
    try cancelTests(lib, allocator);
    try doneAndWaitTests(lib, allocator);
    try doneSignalPublishesRejectionBeforeReadyFlagTests(lib, allocator);
    try exhaustedTests(lib, allocator);
    try initOomTests(lib);
}

fn zeroTaskTests(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const testing = lib.testing;
    const Context = context_mod.make(lib);
    const R = root.Racer(lib, u32);

    {
        var racer = try R.init(allocator);
        defer racer.deinit();

        switch (racer.race()) {
            .winner => return error.UnexpectedWinner,
            .exhausted => {},
        }

        try testing.expect(!racer.done());
        try testing.expectEqual(@as(?u32, null), racer.value());

        racer.wait();
        racer.wait();
    }

    {
        var context = try Context.init(allocator);
        defer context.deinit();

        var racer = try R.init(allocator);
        defer racer.deinit();

        switch (try racer.raceContext(context.background())) {
            .winner => return error.UnexpectedWinner,
            .exhausted => {},
        }

        racer.cancel();
        try testing.expect(racer.done());

        switch (racer.race()) {
            .winner => return error.UnexpectedWinner,
            .exhausted => {},
        }

        switch (try racer.raceContext(context.background())) {
            .winner => return error.UnexpectedWinner,
            .exhausted => {},
        }

        try testing.expectEqual(@as(?u32, null), racer.value());
        racer.wait();
    }
}

fn firstWinnerTests(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const testing = lib.testing;
    const R = root.Racer(lib, u32);
    const BoolAtomic = lib.atomic.Value(bool);
    const U32Atomic = lib.atomic.Value(u32);

    var racer = try R.init(allocator);
    defer racer.deinit();

    var started = U32Atomic.init(0);
    var release_first = BoolAtomic.init(false);
    var release_second = BoolAtomic.init(false);
    var first_attempted = BoolAtomic.init(false);
    var first_won = BoolAtomic.init(false);
    var second_attempted = BoolAtomic.init(false);
    var second_won = BoolAtomic.init(false);
    try racer.spawn(.{}, struct {
        fn run(
            ctx: R.State,
            l: type,
            started_count: *U32Atomic,
            gate: *BoolAtomic,
            attempted: *BoolAtomic,
            result: *BoolAtomic,
            value: u32,
        ) void {
            _ = started_count.fetchAdd(1, .acq_rel);
            while (!gate.load(.acquire)) {
                l.Thread.sleep(l.time.ns_per_ms);
            }
            result.store(ctx.success(value), .release);
            attempted.store(true, .release);
        }
    }.run, .{ lib, &started, &release_second, &second_attempted, &second_won, 2 });

    try racer.spawn(.{}, struct {
        fn run(
            ctx: R.State,
            l: type,
            started_count: *U32Atomic,
            gate: *BoolAtomic,
            attempted: *BoolAtomic,
            result: *BoolAtomic,
            value: u32,
        ) void {
            _ = started_count.fetchAdd(1, .acq_rel);
            while (!gate.load(.acquire)) {
                l.Thread.sleep(l.time.ns_per_ms);
            }
            result.store(ctx.success(value), .release);
            attempted.store(true, .release);
        }
    }.run, .{ lib, &started, &release_first, &first_attempted, &first_won, 1 });

    try waitForCount(lib, &started, 2, 200);
    release_first.store(true, .release);
    try waitForTrue(lib, &first_attempted, 200);
    try testing.expect(first_won.load(.acquire));

    switch (racer.race()) {
        .winner => |value| try testing.expectEqual(@as(u32, 1), value),
        .exhausted => return error.ExpectedWinner,
    }

    release_second.store(true, .release);
    try waitForTrue(lib, &second_attempted, 200);
    try testing.expect(!second_won.load(.acquire));

    switch (racer.race()) {
        .winner => |value| try testing.expectEqual(@as(u32, 1), value),
        .exhausted => return error.ExpectedWinner,
    }

    try testing.expect(racer.done());
    try testing.expectEqual(@as(?u32, 1), racer.value());

    racer.wait();
    racer.wait();
}

fn raceContextTests(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const testing = lib.testing;
    const Context = context_mod.make(lib);
    var context = try Context.init(allocator);
    defer context.deinit();
    const R = root.Racer(lib, u32);
    const log = lib.log.scoped(.racer);

    {
        var racer = try R.init(allocator);
        defer racer.deinit();

        try racer.spawn(.{}, struct {
            fn run(state: R.State, l: type) void {
                l.Thread.sleep(5 * l.time.ns_per_ms);
                _ = state.success(3);
            }
        }.run, .{lib});

        switch (try racer.raceContext(context.background())) {
            .winner => |value| try testing.expectEqual(@as(u32, 3), value),
            .exhausted => return error.ExpectedWinner,
        }
    }

    {
        var racer = try R.init(allocator);
        defer racer.deinit();

        try racer.spawn(.{}, struct {
            fn run(state: R.State, l: type) void {
                _ = state;
                l.Thread.sleep(20 * l.time.ns_per_ms);
            }
        }.run, .{lib});

        var cancel_ctx = try context.withCancel(context.background());
        defer cancel_ctx.deinit();
        cancel_ctx.cancel();

        try testing.expectError(error.Canceled, racer.raceContext(cancel_ctx));
    }

    {
        var racer = try R.init(allocator);
        defer racer.deinit();

        try racer.spawn(.{}, struct {
            fn run(state: R.State, l: type) void {
                l.Thread.sleep(5 * l.time.ns_per_ms);
                _ = state.success(11);
            }
        }.run, .{lib});

        var timeout_ctx = try context.withTimeout(context.background(), 200 * lib.time.ns_per_ms);
        defer timeout_ctx.deinit();

        if (timeout_ctx.deadline() == null) return error.ExpectedDeadline;

        if (racer.raceContext(timeout_ctx)) |result| {
            switch (result) {
                .winner => |value| try testing.expectEqual(@as(u32, 11), value),
                .exhausted => return error.ExpectedWinner,
            }
        } else |err| {
            log.err("raceContext: timeout winner actual error={}", .{err});
            return err;
        }
    }

    {
        var racer = try R.init(allocator);
        defer racer.deinit();

        try racer.spawn(.{}, struct {
            fn run(state: R.State, l: type) void {
                l.Thread.sleep(5 * l.time.ns_per_ms);
                _ = state.success(21);
            }
        }.run, .{lib});

        switch (racer.race()) {
            .winner => |value| try testing.expectEqual(@as(u32, 21), value),
            .exhausted => return error.ExpectedWinner,
        }

        var cancel_ctx = try context.withCancel(context.background());
        defer cancel_ctx.deinit();
        cancel_ctx.cancelWithCause(error.BrokenPipe);

        // This is intentional: an already-canceled external context takes
        // precedence over a previously published winner for raceContext().
        try testing.expectError(error.BrokenPipe, racer.raceContext(cancel_ctx));

        switch (racer.race()) {
            .winner => |value| try testing.expectEqual(@as(u32, 21), value),
            .exhausted => return error.ExpectedWinner,
        }
    }

    {
        var racer = try R.init(allocator);
        defer racer.deinit();

        try racer.spawn(.{}, struct {
            fn run(state: R.State, l: type) void {
                _ = state;
                l.Thread.sleep(50 * l.time.ns_per_ms);
            }
        }.run, .{lib});

        var timeout_ctx = try context.withTimeout(context.background(), 5 * lib.time.ns_per_ms);
        defer timeout_ctx.deinit();

        if (timeout_ctx.deadline() == null) return error.ExpectedDeadline;

        if (racer.raceContext(timeout_ctx)) |result| {
            switch (result) {
                .winner => |value| log.err("raceContext: short timeout returned winner={}", .{value}),
                .exhausted => log.err("raceContext: short timeout returned exhausted", .{}),
            }
            return error.TestExpectedError;
        } else |err| {
            if (err != error.DeadlineExceeded) return error.TestUnexpectedError;
        }
    }

    {
        var racer = try R.init(allocator);
        defer racer.deinit();

        try racer.spawn(.{}, struct {
            fn run(state: R.State, l: type) void {
                _ = state;
                l.Thread.sleep(20 * l.time.ns_per_ms);
            }
        }.run, .{lib});

        var cancel_ctx = try context.withCancel(context.background());
        defer cancel_ctx.deinit();

        var cancel_thread = try lib.Thread.spawn(.{}, struct {
            fn run(cc: *context_mod.Context, l: type) void {
                l.Thread.sleep(5 * l.time.ns_per_ms);
                cc.cancelWithCause(error.BrokenPipe);
            }
        }.run, .{ &cancel_ctx, lib });
        defer cancel_thread.join();

        try testing.expectError(error.BrokenPipe, racer.raceContext(cancel_ctx));
    }
}

fn exhaustedTests(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const testing = lib.testing;
    const R = root.Racer(lib, u32);

    var racer = try R.init(allocator);
    defer racer.deinit();

    try racer.spawn(.{}, struct {
        fn run(ctx: R.State) void {
            _ = ctx;
        }
    }.run, .{});

    switch (racer.race()) {
        .winner => return error.UnexpectedWinner,
        .exhausted => {},
    }

    switch (racer.race()) {
        .winner => return error.UnexpectedWinner,
        .exhausted => {},
    }

    try testing.expect(!racer.done());
    try testing.expectEqual(@as(?u32, null), racer.value());

    racer.wait();
    racer.wait();
}

fn cancelTests(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const testing = lib.testing;
    const Context = context_mod.make(lib);
    const R = root.Racer(lib, u32);
    const BoolAtomic = lib.atomic.Value(bool);

    const Flags = struct {
        saw_done: BoolAtomic = BoolAtomic.init(false),
        success_rejected: BoolAtomic = BoolAtomic.init(false),
        finished: BoolAtomic = BoolAtomic.init(false),
    };

    {
        var racer = try R.init(allocator);
        defer racer.deinit();

        var flags = Flags{};
        try racer.spawn(.{}, struct {
            fn run(ctx: R.State, l: type, f: *Flags) void {
                while (!ctx.done()) {
                    l.Thread.sleep(l.time.ns_per_ms);
                }

                f.saw_done.store(true, .release);
                f.success_rejected.store(!ctx.success(99), .release);
                f.finished.store(true, .release);
            }
        }.run, .{ lib, &flags });

        var cancel_thread = try lib.Thread.spawn(.{}, struct {
            fn run(r: *R, l: type) void {
                l.Thread.sleep(5 * l.time.ns_per_ms);
                r.cancel();
            }
        }.run, .{ &racer, lib });
        defer cancel_thread.join();

        switch (racer.race()) {
            .winner => return error.UnexpectedWinner,
            .exhausted => {},
        }

        try testing.expect(racer.done());
        try testing.expectEqual(@as(?u32, null), racer.value());
        try waitForTrue(lib, &flags.saw_done, 200);
        try testing.expect(flags.success_rejected.load(.acquire));
        try testing.expect(flags.finished.load(.acquire));

        racer.wait();
        racer.wait();
    }

    {
        var context = try Context.init(allocator);
        defer context.deinit();

        var racer = try R.init(allocator);
        defer racer.deinit();

        var flags = Flags{};
        try racer.spawn(.{}, struct {
            fn run(ctx: R.State, l: type, f: *Flags) void {
                while (!ctx.done()) {
                    l.Thread.sleep(l.time.ns_per_ms);
                }

                f.saw_done.store(true, .release);
                f.success_rejected.store(!ctx.success(123), .release);
                f.finished.store(true, .release);
            }
        }.run, .{ lib, &flags });

        var cancel_thread = try lib.Thread.spawn(.{}, struct {
            fn run(r: *R, l: type) void {
                l.Thread.sleep(5 * l.time.ns_per_ms);
                r.cancel();
            }
        }.run, .{ &racer, lib });
        defer cancel_thread.join();

        switch (try racer.raceContext(context.background())) {
            .winner => return error.UnexpectedWinner,
            .exhausted => {},
        }

        try testing.expect(racer.done());
        try testing.expectEqual(@as(?u32, null), racer.value());
        try waitForTrue(lib, &flags.saw_done, 200);
        try testing.expect(flags.success_rejected.load(.acquire));
        try testing.expect(flags.finished.load(.acquire));

        racer.wait();
        racer.wait();
    }

    {
        var racer = try R.init(allocator);
        defer racer.deinit();

        var finished = BoolAtomic.init(false);
        try racer.spawn(.{}, struct {
            fn run(ctx: R.State, l: type, fin: *BoolAtomic) void {
                while (!ctx.done()) {
                    l.Thread.sleep(l.time.ns_per_ms);
                }
                l.Thread.sleep(5 * l.time.ns_per_ms);
                fin.store(true, .release);
            }
        }.run, .{ lib, &finished });

        var cancel_thread = try lib.Thread.spawn(.{}, struct {
            fn run(r: *R, l: type) void {
                l.Thread.sleep(5 * l.time.ns_per_ms);
                r.cancel();
            }
        }.run, .{ &racer, lib });

        racer.wait();
        cancel_thread.join();

        try testing.expect(racer.done());
        try testing.expect(finished.load(.acquire));
        try testing.expectEqual(@as(?u32, null), racer.value());
    }
}

fn DoneAndWaitFlags(comptime lib: type) type {
    const BoolAtomic = lib.atomic.Value(bool);
    return struct {
        saw_done: BoolAtomic = BoolAtomic.init(false),
        allow_exit: BoolAtomic = BoolAtomic.init(false),
        finished: BoolAtomic = BoolAtomic.init(false),
        winner_rejected: BoolAtomic = BoolAtomic.init(false),
    };
}

fn doneAndWaitWorker(ctx: anytype, l: type, f: anytype) void {
    while (!ctx.done()) {
        l.Thread.sleep(l.time.ns_per_ms);
    }

    // `saw_done` acts as the publication fence for the test thread, so publish
    // the rejection result first.
    f.winner_rejected.store(!ctx.success(99), .release);
    f.saw_done.store(true, .release);

    while (!f.allow_exit.load(.acquire)) {
        l.Thread.sleep(l.time.ns_per_ms);
    }

    f.finished.store(true, .release);
}

fn doneAndWaitTests(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const testing = lib.testing;
    const R = root.Racer(lib, u32);
    const Flags = DoneAndWaitFlags(lib);

    var racer = try R.init(allocator);
    defer racer.deinit();

    var flags = Flags{};
    errdefer flags.allow_exit.store(true, .release);

    try racer.spawn(.{}, doneAndWaitWorker, .{ lib, &flags });

    try racer.spawn(.{}, struct {
        fn run(ctx: R.State, l: type) void {
            l.Thread.sleep(5 * l.time.ns_per_ms);
            _ = ctx.success(7);
        }
    }.run, .{lib});

    switch (racer.race()) {
        .winner => |value| try testing.expectEqual(@as(u32, 7), value),
        .exhausted => return error.ExpectedWinner,
    }

    try testing.expect(racer.done());
    try testing.expectEqual(@as(?u32, 7), racer.value());

    try waitForTrue(lib, &flags.saw_done, 200);
    try testing.expect(!flags.finished.load(.acquire));
    try testing.expect(flags.winner_rejected.load(.acquire));

    flags.allow_exit.store(true, .release);
    racer.wait();
    racer.wait();

    try testing.expect(flags.finished.load(.acquire));
}

fn doneSignalPublishesRejectionBeforeReadyFlagTests(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const testing = lib.testing;
    const R = root.Racer(lib, u32);
    const Flags = DoneAndWaitFlags(lib);

    var racer = try R.init(allocator);
    defer racer.deinit();

    var flags = Flags{};
    errdefer flags.allow_exit.store(true, .release);

    try racer.spawn(.{}, doneAndWaitWorker, .{ lib, &flags });
    try racer.spawn(.{}, struct {
        fn run(ctx: R.State, l: type) void {
            l.Thread.sleep(5 * l.time.ns_per_ms);
            _ = ctx.success(7);
        }
    }.run, .{lib});

    switch (racer.race()) {
        .winner => |value| try testing.expectEqual(@as(u32, 7), value),
        .exhausted => return error.ExpectedWinner,
    }

    try waitForTrue(lib, &flags.saw_done, 200);
    try testing.expect(flags.winner_rejected.load(.acquire));
    try testing.expect(!flags.finished.load(.acquire));

    flags.allow_exit.store(true, .release);
    racer.wait();
    try testing.expect(flags.finished.load(.acquire));
}

fn spawnAllocatorTests(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const tst = lib.testing;
    const CapturingThread = CapturingThreadType(lib);
    const PassthroughAllocator = PassthroughAllocatorType(lib);
    const CapturingThreadLib = struct {
        pub const mem = lib.mem;
        pub const atomic = lib.atomic;
        pub const testing = lib.testing;
        pub const debug = lib.debug;
        pub const Thread = CapturingThread;
    };
    const R = root.Racer(CapturingThreadLib, u32);

    var racer = try R.init(allocator);
    defer racer.deinit();

    CapturingThread.last_allocator = null;
    try racer.spawn(.{}, struct {
        fn run(ctx: R.State) void {
            _ = ctx;
        }
    }.run, .{});

    const seen_default = CapturingThread.last_allocator orelse return error.ExpectedDefaultAllocator;
    try tst.expect(lib.meta.eql(seen_default, allocator));

    var explicit_allocator_state = PassthroughAllocator.init(allocator);
    const explicit_allocator = explicit_allocator_state.allocator();

    CapturingThread.last_allocator = null;
    try racer.spawn(.{ .allocator = explicit_allocator }, struct {
        fn run(ctx: R.State) void {
            _ = ctx;
        }
    }.run, .{});

    const seen_explicit = CapturingThread.last_allocator orelse return error.ExpectedExplicitAllocator;
    try tst.expect(lib.meta.eql(seen_explicit, explicit_allocator));
}

fn initOomTests(comptime lib: type) !void {
    const testing = lib.testing;
    const R = root.Racer(lib, u32);
    const FailingAllocator = FailingAllocatorType(lib);

    var failing_allocator = FailingAllocator{};

    try testing.expectError(error.OutOfMemory, R.init(failing_allocator.allocator()));
}

fn waitForTrue(comptime lib: type, flag: *lib.atomic.Value(bool), timeout_ms: u64) !void {
    var elapsed_ms: u64 = 0;
    while (elapsed_ms < timeout_ms) : (elapsed_ms += 1) {
        if (flag.load(.acquire)) return;
        lib.Thread.sleep(lib.time.ns_per_ms);
    }
    return error.TimeoutWaitingForFlag;
}

fn waitForCount(comptime lib: type, count: *lib.atomic.Value(u32), expected: u32, timeout_ms: u64) !void {
    var elapsed_ms: u64 = 0;
    while (elapsed_ms < timeout_ms) : (elapsed_ms += 1) {
        if (count.load(.acquire) >= expected) return;
        lib.Thread.sleep(lib.time.ns_per_ms);
    }
    return error.TimeoutWaitingForCount;
}

fn allocatorAlignment(comptime lib: type) type {
    const alloc_ptr_type = @TypeOf(lib.testing.allocator.vtable.alloc);
    const alloc_fn_type = @typeInfo(alloc_ptr_type).pointer.child;
    return @typeInfo(alloc_fn_type).@"fn".params[2].type.?;
}

fn PassthroughAllocatorType(comptime lib: type) type {
    const Allocator = lib.mem.Allocator;
    const Alignment = allocatorAlignment(lib);

    return struct {
        backing: Allocator,

        const Self = @This();

        pub fn init(backing: Allocator) Self {
            return .{ .backing = backing };
        }

        pub fn allocator(self: *Self) Allocator {
            return .{
                .ptr = self,
                .vtable = &vtable,
            };
        }

        fn alloc(ptr: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.backing.rawAlloc(len, alignment, ret_addr);
        }

        fn resize(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.backing.rawResize(memory, alignment, new_len, ret_addr);
        }

        fn remap(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        }

        fn free(ptr: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.backing.rawFree(memory, alignment, ret_addr);
        }

        const vtable: Allocator.VTable = .{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        };
    };
}

fn FailingAllocatorType(comptime lib: type) type {
    const Allocator = lib.mem.Allocator;
    const Alignment = allocatorAlignment(lib);

    return struct {
        const Self = @This();

        pub fn allocator(self: *Self) Allocator {
            return .{
                .ptr = self,
                .vtable = &vtable,
            };
        }

        fn alloc(_: *anyopaque, _: usize, _: Alignment, _: usize) ?[*]u8 {
            return null;
        }

        fn resize(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) bool {
            return false;
        }

        fn remap(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) ?[*]u8 {
            return null;
        }

        fn free(_: *anyopaque, _: []u8, _: Alignment, _: usize) void {}

        const vtable: Allocator.VTable = .{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        };
    };
}

fn CapturingThreadType(comptime lib: type) type {
    return struct {
        pub const Mutex = lib.Thread.Mutex;
        pub const Condition = lib.Thread.Condition;
        pub const SpawnError = error{};
        pub const SpawnConfig = struct {
            allocator: ?lib.mem.Allocator = null,
        };

        pub var last_allocator: ?lib.mem.Allocator = null;

        const Self = @This();

        pub fn spawn(config: SpawnConfig, comptime f: anytype, args: anytype) SpawnError!Self {
            last_allocator = config.allocator;
            @call(.auto, f, args);
            return .{};
        }

        pub fn detach(self: Self) void {
            _ = self;
        }
    };
}
