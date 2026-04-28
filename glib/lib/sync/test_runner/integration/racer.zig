//! Racer test runner — exercises first-winner semantics and wait behavior.
//!
//! Accepts any type with the same shape as std
//! (std.Thread, std.atomic, std.mem, std.meta).
//! Can be compiled into firmware main.zig — no reliance on file-scope tests.
//!
//! Usage:
//!   try @import("sync").test_runner.integration.racer.run(std);
//!   try @import("sync").test_runner.integration.racer.run(stdz);

const root = @import("../../../sync.zig");
const context_mod = @import("context");
const stdz = @import("stdz");
const testing_api = @import("testing");

pub fn make(comptime std: type, comptime time: type) testing_api.TestRunner {
    const W = struct {
        fn spawnAllocator(t: *testing_api.T, allocator: std.mem.Allocator) !void {
            _ = t;
            try spawnAllocatorTests(std, time, allocator);
        }
        fn zeroTask(t: *testing_api.T, allocator: std.mem.Allocator) !void {
            _ = t;
            try zeroTaskTests(std, time, allocator);
        }
        fn firstWinner(t: *testing_api.T, allocator: std.mem.Allocator) !void {
            _ = t;
            try firstWinnerTests(std, time, allocator);
        }
        fn raceContext(t: *testing_api.T, allocator: std.mem.Allocator) !void {
            _ = t;
            try raceContextTests(std, time, allocator);
        }
        fn cancel(t: *testing_api.T, allocator: std.mem.Allocator) !void {
            _ = t;
            try cancelTests(std, time, allocator);
        }
        fn doneAndWait(t: *testing_api.T, allocator: std.mem.Allocator) !void {
            _ = t;
            try doneAndWaitTests(std, time, allocator);
        }
        fn doneSignalRejection(t: *testing_api.T, allocator: std.mem.Allocator) !void {
            _ = t;
            try doneSignalPublishesRejectionBeforeReadyFlagTests(std, time, allocator);
        }
        fn exhausted(t: *testing_api.T, allocator: std.mem.Allocator) !void {
            _ = t;
            try exhaustedTests(std, time, allocator);
        }
        fn initOom(t: *testing_api.T, allocator: std.mem.Allocator) !void {
            _ = t;
            _ = allocator;
            try initOomTests(std, time);
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
            t.run("spawn_allocator", testing_api.TestRunner.fromFn(std, 48 * 1024, W.spawnAllocator));
            t.run("zero_task", testing_api.TestRunner.fromFn(std, 48 * 1024, W.zeroTask));
            t.run("first_winner", testing_api.TestRunner.fromFn(std, 128 * 1024, W.firstWinner));
            t.run("race_context", testing_api.TestRunner.fromFn(std, 192 * 1024, W.raceContext));
            t.run("cancel", testing_api.TestRunner.fromFn(std, 128 * 1024, W.cancel));
            t.run("done_and_wait", testing_api.TestRunner.fromFn(std, 128 * 1024, W.doneAndWait));
            t.run("done_signal_rejection", testing_api.TestRunner.fromFn(std, 128 * 1024, W.doneSignalRejection));
            t.run("exhausted", testing_api.TestRunner.fromFn(std, 64 * 1024, W.exhausted));
            t.run("init_oom", testing_api.TestRunner.fromFn(std, 40 * 1024, W.initOom));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = allocator;
            std.testing.allocator.destroy(self);
        }
    };

    const runner = std.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}

pub fn run(comptime std: type, comptime time: type) !void {
    try runSequentialSuite(std, time, std.testing.allocator);
}

fn runSequentialSuite(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    try spawnAllocatorTests(std, time, allocator);
    try zeroTaskTests(std, time, allocator);
    try firstWinnerTests(std, time, allocator);
    try raceContextTests(std, time, allocator);
    try cancelTests(std, time, allocator);
    try doneAndWaitTests(std, time, allocator);
    try doneSignalPublishesRejectionBeforeReadyFlagTests(std, time, allocator);
    try exhaustedTests(std, time, allocator);
    try initOomTests(std, time);
}

fn zeroTaskTests(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const testing = std.testing;
    const Context = context_mod.make(std, time);
    const R = root.Racer(std, time, u32);

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

fn firstWinnerTests(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const testing = std.testing;
    const R = root.Racer(std, time, u32);
    const BoolAtomic = std.atomic.Value(bool);
    const U32Atomic = std.atomic.Value(u32);

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
                l.Thread.sleep(@intCast(time.duration.MilliSecond));
            }
            result.store(ctx.success(value), .release);
            attempted.store(true, .release);
        }
    }.run, .{ std, &started, &release_second, &second_attempted, &second_won, 2 });

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
                l.Thread.sleep(@intCast(time.duration.MilliSecond));
            }
            result.store(ctx.success(value), .release);
            attempted.store(true, .release);
        }
    }.run, .{ std, &started, &release_first, &first_attempted, &first_won, 1 });

    try waitForCount(std, time, &started, 2, 200 * time.duration.MilliSecond);
    release_first.store(true, .release);
    try waitForTrue(std, time, &first_attempted, 200 * time.duration.MilliSecond);
    try testing.expect(first_won.load(.acquire));

    switch (racer.race()) {
        .winner => |value| try testing.expectEqual(@as(u32, 1), value),
        .exhausted => return error.ExpectedWinner,
    }

    release_second.store(true, .release);
    try waitForTrue(std, time, &second_attempted, 200 * time.duration.MilliSecond);
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

fn raceContextTests(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const testing = std.testing;
    const Context = context_mod.make(std, time);
    var context = try Context.init(allocator);
    defer context.deinit();
    const R = root.Racer(std, time, u32);
    const log = std.log.scoped(.racer);

    {
        var racer = try R.init(allocator);
        defer racer.deinit();

        try racer.spawn(.{}, struct {
            fn run(state: R.State, l: type) void {
                l.Thread.sleep(@intCast(5 * time.duration.MilliSecond));
                _ = state.success(3);
            }
        }.run, .{std});

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
                l.Thread.sleep(@intCast(20 * time.duration.MilliSecond));
            }
        }.run, .{std});

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
                l.Thread.sleep(@intCast(5 * time.duration.MilliSecond));
                _ = state.success(11);
            }
        }.run, .{std});

        var timeout_ctx = try context.withTimeout(context.background(), 200 * time.duration.MilliSecond);
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
                l.Thread.sleep(@intCast(5 * time.duration.MilliSecond));
                _ = state.success(21);
            }
        }.run, .{std});

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
                l.Thread.sleep(@intCast(50 * time.duration.MilliSecond));
            }
        }.run, .{std});

        var timeout_ctx = try context.withTimeout(context.background(), 5 * time.duration.MilliSecond);
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
                l.Thread.sleep(@intCast(20 * time.duration.MilliSecond));
            }
        }.run, .{std});

        var cancel_ctx = try context.withCancel(context.background());
        defer cancel_ctx.deinit();

        var cancel_thread = try std.Thread.spawn(.{}, struct {
            fn run(cc: *context_mod.Context, l: type) void {
                l.Thread.sleep(@intCast(5 * time.duration.MilliSecond));
                cc.cancelWithCause(error.BrokenPipe);
            }
        }.run, .{ &cancel_ctx, std });
        defer cancel_thread.join();

        try testing.expectError(error.BrokenPipe, racer.raceContext(cancel_ctx));
    }
}

fn exhaustedTests(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const testing = std.testing;
    const R = root.Racer(std, time, u32);

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

fn cancelTests(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const testing = std.testing;
    const Context = context_mod.make(std, time);
    const R = root.Racer(std, time, u32);
    const BoolAtomic = std.atomic.Value(bool);

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
                    l.Thread.sleep(@intCast(time.duration.MilliSecond));
                }

                f.saw_done.store(true, .release);
                f.success_rejected.store(!ctx.success(99), .release);
                f.finished.store(true, .release);
            }
        }.run, .{ std, &flags });

        var cancel_thread = try std.Thread.spawn(.{}, struct {
            fn run(r: *R, l: type) void {
                l.Thread.sleep(@intCast(5 * time.duration.MilliSecond));
                r.cancel();
            }
        }.run, .{ &racer, std });
        defer cancel_thread.join();

        switch (racer.race()) {
            .winner => return error.UnexpectedWinner,
            .exhausted => {},
        }

        try testing.expect(racer.done());
        try testing.expectEqual(@as(?u32, null), racer.value());
        try waitForTrue(std, time, &flags.saw_done, 200 * time.duration.MilliSecond);
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
                    l.Thread.sleep(@intCast(time.duration.MilliSecond));
                }

                f.saw_done.store(true, .release);
                f.success_rejected.store(!ctx.success(123), .release);
                f.finished.store(true, .release);
            }
        }.run, .{ std, &flags });

        var cancel_thread = try std.Thread.spawn(.{}, struct {
            fn run(r: *R, l: type) void {
                l.Thread.sleep(@intCast(5 * time.duration.MilliSecond));
                r.cancel();
            }
        }.run, .{ &racer, std });
        defer cancel_thread.join();

        switch (try racer.raceContext(context.background())) {
            .winner => return error.UnexpectedWinner,
            .exhausted => {},
        }

        try testing.expect(racer.done());
        try testing.expectEqual(@as(?u32, null), racer.value());
        try waitForTrue(std, time, &flags.saw_done, 200 * time.duration.MilliSecond);
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
                    l.Thread.sleep(@intCast(time.duration.MilliSecond));
                }
                l.Thread.sleep(@intCast(5 * time.duration.MilliSecond));
                fin.store(true, .release);
            }
        }.run, .{ std, &finished });

        var cancel_thread = try std.Thread.spawn(.{}, struct {
            fn run(r: *R, l: type) void {
                l.Thread.sleep(@intCast(5 * time.duration.MilliSecond));
                r.cancel();
            }
        }.run, .{ &racer, std });

        racer.wait();
        cancel_thread.join();

        try testing.expect(racer.done());
        try testing.expect(finished.load(.acquire));
        try testing.expectEqual(@as(?u32, null), racer.value());
    }
}

fn DoneAndWaitFlags(comptime std: type) type {
    const BoolAtomic = std.atomic.Value(bool);
    return struct {
        saw_done: BoolAtomic = BoolAtomic.init(false),
        allow_exit: BoolAtomic = BoolAtomic.init(false),
        finished: BoolAtomic = BoolAtomic.init(false),
        winner_rejected: BoolAtomic = BoolAtomic.init(false),
    };
}

fn doneAndWaitWorker(ctx: anytype, l: type, tm: type, f: anytype) void {
    while (!ctx.done()) {
        l.Thread.sleep(@intCast(tm.duration.MilliSecond));
    }

    // `saw_done` acts as the publication fence for the test thread, so publish
    // the rejection result first.
    f.winner_rejected.store(!ctx.success(99), .release);
    f.saw_done.store(true, .release);

    while (!f.allow_exit.load(.acquire)) {
        l.Thread.sleep(@intCast(tm.duration.MilliSecond));
    }

    f.finished.store(true, .release);
}

fn doneAndWaitTests(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const testing = std.testing;
    const R = root.Racer(std, time, u32);
    const Flags = DoneAndWaitFlags(std);

    var racer = try R.init(allocator);
    defer racer.deinit();

    var flags = Flags{};
    errdefer flags.allow_exit.store(true, .release);

    try racer.spawn(.{}, doneAndWaitWorker, .{ std, time, &flags });

    try racer.spawn(.{}, struct {
        fn run(ctx: R.State, l: type) void {
            l.Thread.sleep(@intCast(5 * time.duration.MilliSecond));
            _ = ctx.success(7);
        }
    }.run, .{std});

    switch (racer.race()) {
        .winner => |value| try testing.expectEqual(@as(u32, 7), value),
        .exhausted => return error.ExpectedWinner,
    }

    try testing.expect(racer.done());
    try testing.expectEqual(@as(?u32, 7), racer.value());

    try waitForTrue(std, time, &flags.saw_done, 200 * time.duration.MilliSecond);
    try testing.expect(!flags.finished.load(.acquire));
    try testing.expect(flags.winner_rejected.load(.acquire));

    flags.allow_exit.store(true, .release);
    racer.wait();
    racer.wait();

    try testing.expect(flags.finished.load(.acquire));
}

fn doneSignalPublishesRejectionBeforeReadyFlagTests(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const testing = std.testing;
    const R = root.Racer(std, time, u32);
    const Flags = DoneAndWaitFlags(std);

    var racer = try R.init(allocator);
    defer racer.deinit();

    var flags = Flags{};
    errdefer flags.allow_exit.store(true, .release);

    try racer.spawn(.{}, doneAndWaitWorker, .{ std, time, &flags });
    try racer.spawn(.{}, struct {
        fn run(ctx: R.State, l: type) void {
            l.Thread.sleep(@intCast(5 * time.duration.MilliSecond));
            _ = ctx.success(7);
        }
    }.run, .{std});

    switch (racer.race()) {
        .winner => |value| try testing.expectEqual(@as(u32, 7), value),
        .exhausted => return error.ExpectedWinner,
    }

    try waitForTrue(std, time, &flags.saw_done, 200 * time.duration.MilliSecond);
    try testing.expect(flags.winner_rejected.load(.acquire));
    try testing.expect(!flags.finished.load(.acquire));

    flags.allow_exit.store(true, .release);
    racer.wait();
    try testing.expect(flags.finished.load(.acquire));
}

fn spawnAllocatorTests(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const tst = std.testing;
    const CapturingThread = CapturingThreadType(std);
    const PassthroughAllocator = PassthroughAllocatorType(std);
    const CapturingThreadLib = struct {
        pub const mem = std.mem;
        pub const atomic = std.atomic;
        pub const testing = std.testing;
        pub const debug = std.debug;
        pub const Thread = CapturingThread;
    };
    const R = root.Racer(CapturingThreadLib, time, u32);

    var racer = try R.init(allocator);
    defer racer.deinit();

    CapturingThread.last_allocator = null;
    try racer.spawn(.{}, struct {
        fn run(ctx: R.State) void {
            _ = ctx;
        }
    }.run, .{});

    const seen_default = CapturingThread.last_allocator orelse return error.ExpectedDefaultAllocator;
    try tst.expect(std.meta.eql(seen_default, allocator));

    var explicit_allocator_state = PassthroughAllocator.init(allocator);
    const explicit_allocator = explicit_allocator_state.allocator();

    CapturingThread.last_allocator = null;
    try racer.spawn(.{ .allocator = explicit_allocator }, struct {
        fn run(ctx: R.State) void {
            _ = ctx;
        }
    }.run, .{});

    const seen_explicit = CapturingThread.last_allocator orelse return error.ExpectedExplicitAllocator;
    try tst.expect(std.meta.eql(seen_explicit, explicit_allocator));
}

fn initOomTests(comptime std: type, comptime time: type) !void {
    const testing = std.testing;
    const R = root.Racer(std, time, u32);
    const FailingAllocator = FailingAllocatorType(std);

    var failing_allocator = FailingAllocator{};

    try testing.expectError(error.OutOfMemory, R.init(failing_allocator.allocator()));
}

fn waitForTrue(comptime std: type, comptime time: type, flag: *std.atomic.Value(bool), timeout: time.duration.Duration) !void {
    var elapsed: time.duration.Duration = 0;
    while (elapsed < timeout) : (elapsed += time.duration.MilliSecond) {
        if (flag.load(.acquire)) return;
        std.Thread.sleep(@intCast(time.duration.MilliSecond));
    }
    return error.TimeoutWaitingForFlag;
}

fn waitForCount(comptime std: type, comptime time: type, count: *std.atomic.Value(u32), expected: u32, timeout: time.duration.Duration) !void {
    var elapsed: time.duration.Duration = 0;
    while (elapsed < timeout) : (elapsed += time.duration.MilliSecond) {
        if (count.load(.acquire) >= expected) return;
        std.Thread.sleep(@intCast(time.duration.MilliSecond));
    }
    return error.TimeoutWaitingForCount;
}

fn allocatorAlignment(comptime std: type) type {
    const alloc_ptr_type = @TypeOf(std.testing.allocator.vtable.alloc);
    const alloc_fn_type = @typeInfo(alloc_ptr_type).pointer.child;
    return @typeInfo(alloc_fn_type).@"fn".params[2].type.?;
}

fn PassthroughAllocatorType(comptime std: type) type {
    const Allocator = std.mem.Allocator;
    const Alignment = allocatorAlignment(std);

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

fn FailingAllocatorType(comptime std: type) type {
    const Allocator = std.mem.Allocator;
    const Alignment = allocatorAlignment(std);

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

fn CapturingThreadType(comptime std: type) type {
    return struct {
        pub const Mutex = std.Thread.Mutex;
        pub const Condition = std.Thread.Condition;
        pub const SpawnError = error{};
        pub const SpawnConfig = struct {
            allocator: ?std.mem.Allocator = null,
        };

        pub var last_allocator: ?std.mem.Allocator = null;

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
