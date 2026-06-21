//! Racer test runner — exercises first-winner semantics and wait behavior.
//!
//! Accepts any type with the same shape as std
//! (std.sync, std.task, std.atomic, std.mem, std.meta).
//! Can be compiled into firmware main.zig — no reliance on file-scope tests.
//!
//! Usage:
//!   try @import("sync").test_runner.integration.racer.run(std);
//!   try @import("sync").test_runner.integration.racer.run(stdz);

const root = @import("../../../sync.zig");
const context_mod = @import("context");
const stdz = @import("stdz");
const testing_api = @import("testing");

const racer_task_name = "testing/sync/racer";
const racer_task_options: @import("task").Options = .{ .min_stack_size = 64 * 1024 };

pub fn make(comptime std: type, comptime time: type) testing_api.TestRunner {
    const W = struct {
        fn spawnOptions(t: *testing_api.T, allocator: std.mem.Allocator) !void {
            _ = t;
            try spawnOptionsTests(std, time, allocator);
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
            t.run("spawn_options", testing_api.TestRunner.fromFn(std, 48 * 1024, W.spawnOptions));
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
    try spawnOptionsTests(std, time, allocator);
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
    const Context = context_mod.makeWithTask(std, time, testSync(), std.task);
    const R = root.RacerWithTask(std, time, testSync(), std.task, u32);

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
    const R = root.RacerWithTask(std, time, testSync(), std.task, u32);
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
    try racer.spawn(racer_task_options, racer_task_name, struct {
        fn run(
            ctx: R.State,
            _: type,
            started_count: *U32Atomic,
            gate: *BoolAtomic,
            attempted: *BoolAtomic,
            result: *BoolAtomic,
            value: u32,
        ) void {
            _ = started_count.fetchAdd(1, .acq_rel);
            while (!gate.load(.acquire)) {
                time.sleep(time.duration.MilliSecond);
            }
            result.store(ctx.success(value), .release);
            attempted.store(true, .release);
        }
    }.run, .{ std, &started, &release_second, &second_attempted, &second_won, 2 });

    try racer.spawn(racer_task_options, racer_task_name, struct {
        fn run(
            ctx: R.State,
            _: type,
            started_count: *U32Atomic,
            gate: *BoolAtomic,
            attempted: *BoolAtomic,
            result: *BoolAtomic,
            value: u32,
        ) void {
            _ = started_count.fetchAdd(1, .acq_rel);
            while (!gate.load(.acquire)) {
                time.sleep(time.duration.MilliSecond);
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
    const Context = context_mod.makeWithTask(std, time, testSync(), std.task);
    var context = try Context.init(allocator);
    defer context.deinit();
    const R = root.RacerWithTask(std, time, testSync(), std.task, u32);
    const log = std.log.scoped(.racer);

    {
        var racer = try R.init(allocator);
        defer racer.deinit();

        try racer.spawn(racer_task_options, racer_task_name, struct {
            fn run(state: R.State, _: type) void {
                time.sleep(5 * time.duration.MilliSecond);
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

        try racer.spawn(racer_task_options, racer_task_name, struct {
            fn run(state: R.State, _: type) void {
                _ = state;
                time.sleep(20 * time.duration.MilliSecond);
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

        try racer.spawn(racer_task_options, racer_task_name, struct {
            fn run(state: R.State, _: type) void {
                time.sleep(5 * time.duration.MilliSecond);
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

        try racer.spawn(racer_task_options, racer_task_name, struct {
            fn run(state: R.State, _: type) void {
                time.sleep(5 * time.duration.MilliSecond);
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

        try racer.spawn(racer_task_options, racer_task_name, struct {
            fn run(state: R.State, _: type) void {
                _ = state;
                time.sleep(50 * time.duration.MilliSecond);
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

        try racer.spawn(racer_task_options, racer_task_name, struct {
            fn run(state: R.State, _: type) void {
                _ = state;
                time.sleep(20 * time.duration.MilliSecond);
            }
        }.run, .{std});

        var cancel_ctx = try context.withCancel(context.background());
        defer cancel_ctx.deinit();

        var cancel_thread = try JoinTaskType(std).spawn("testing/sync/racer/cancel", struct {
            fn run(cc: *context_mod.Context, _: type) void {
                time.sleep(5 * time.duration.MilliSecond);
                cc.cancelWithCause(error.BrokenPipe);
            }
        }.run, .{ &cancel_ctx, std });
        defer cancel_thread.join();

        try testing.expectError(error.BrokenPipe, racer.raceContext(cancel_ctx));
    }
}

fn exhaustedTests(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const testing = std.testing;
    const R = root.RacerWithTask(std, time, testSync(), std.task, u32);

    var racer = try R.init(allocator);
    defer racer.deinit();

    try racer.spawn(racer_task_options, racer_task_name, struct {
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
    const Context = context_mod.makeWithTask(std, time, testSync(), std.task);
    const R = root.RacerWithTask(std, time, testSync(), std.task, u32);
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
        try racer.spawn(racer_task_options, racer_task_name, struct {
            fn run(ctx: R.State, _: type, f: *Flags) void {
                while (!ctx.done()) {
                    time.sleep(time.duration.MilliSecond);
                }

                f.saw_done.store(true, .release);
                f.success_rejected.store(!ctx.success(99), .release);
                f.finished.store(true, .release);
            }
        }.run, .{ std, &flags });

        var cancel_thread = try JoinTaskType(std).spawn("testing/sync/racer/cancel", struct {
            fn run(r: *R, _: type) void {
                time.sleep(5 * time.duration.MilliSecond);
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
        try racer.spawn(racer_task_options, racer_task_name, struct {
            fn run(ctx: R.State, _: type, f: *Flags) void {
                while (!ctx.done()) {
                    time.sleep(time.duration.MilliSecond);
                }

                f.saw_done.store(true, .release);
                f.success_rejected.store(!ctx.success(123), .release);
                f.finished.store(true, .release);
            }
        }.run, .{ std, &flags });

        var cancel_thread = try JoinTaskType(std).spawn("testing/sync/racer/cancel", struct {
            fn run(r: *R, _: type) void {
                time.sleep(5 * time.duration.MilliSecond);
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
        try racer.spawn(racer_task_options, racer_task_name, struct {
            fn run(ctx: R.State, _: type, fin: *BoolAtomic) void {
                while (!ctx.done()) {
                    time.sleep(time.duration.MilliSecond);
                }
                time.sleep(5 * time.duration.MilliSecond);
                fin.store(true, .release);
            }
        }.run, .{ std, &finished });

        var cancel_thread = try JoinTaskType(std).spawn("testing/sync/racer/cancel", struct {
            fn run(r: *R, _: type) void {
                time.sleep(5 * time.duration.MilliSecond);
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

fn doneAndWaitWorker(ctx: anytype, _: type, tm: type, f: anytype) void {
    while (!ctx.done()) {
        tm.sleep(tm.duration.MilliSecond);
    }

    // `saw_done` acts as the publication fence for the test thread, so publish
    // the rejection result first.
    f.winner_rejected.store(!ctx.success(99), .release);
    f.saw_done.store(true, .release);

    while (!f.allow_exit.load(.acquire)) {
        tm.sleep(tm.duration.MilliSecond);
    }

    f.finished.store(true, .release);
}

fn doneAndWaitTests(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const testing = std.testing;
    const R = root.RacerWithTask(std, time, testSync(), std.task, u32);
    const Flags = DoneAndWaitFlags(std);

    var racer = try R.init(allocator);
    defer racer.deinit();

    var flags = Flags{};
    errdefer flags.allow_exit.store(true, .release);

    try racer.spawn(racer_task_options, racer_task_name, doneAndWaitWorker, .{ std, time, &flags });

    try racer.spawn(racer_task_options, racer_task_name, struct {
        fn run(ctx: R.State, _: type) void {
            time.sleep(5 * time.duration.MilliSecond);
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
    const R = root.RacerWithTask(std, time, testSync(), std.task, u32);
    const Flags = DoneAndWaitFlags(std);

    var racer = try R.init(allocator);
    defer racer.deinit();

    var flags = Flags{};
    errdefer flags.allow_exit.store(true, .release);

    try racer.spawn(racer_task_options, racer_task_name, doneAndWaitWorker, .{ std, time, &flags });
    try racer.spawn(racer_task_options, racer_task_name, struct {
        fn run(ctx: R.State, _: type) void {
            time.sleep(5 * time.duration.MilliSecond);
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

fn spawnOptionsTests(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const tst = std.testing;
    const CapturingTask = CapturingTaskType(std);
    const R = root.RacerWithTask(std, time, testSync(), CapturingTask, u32);

    var racer = try R.init(allocator);
    defer racer.deinit();

    const expected_stack_size = 72 * 1024;
    CapturingTask.last_min_stack_size = 0;
    try racer.spawn(.{ .min_stack_size = expected_stack_size }, "testing/sync/racer/options", struct {
        fn run(ctx: R.State) void {
            _ = ctx;
        }
    }.run, .{});

    try tst.expectEqual(@as(usize, expected_stack_size), CapturingTask.last_min_stack_size);
}

fn initOomTests(comptime std: type, comptime time: type) !void {
    const testing = std.testing;
    const R = root.RacerWithTask(std, time, testSync(), std.task, u32);
    const FailingAllocator = FailingAllocatorType(std);

    var failing_allocator = FailingAllocator{};

    try testing.expectError(error.OutOfMemory, R.init(failing_allocator.allocator()));
}

fn waitForTrue(comptime std: type, comptime time: type, flag: *std.atomic.Value(bool), timeout: time.duration.Duration) !void {
    var elapsed: time.duration.Duration = 0;
    while (elapsed < timeout) : (elapsed += time.duration.MilliSecond) {
        if (flag.load(.acquire)) return;
        time.sleep(time.duration.MilliSecond);
    }
    return error.TimeoutWaitingForFlag;
}

fn waitForCount(comptime std: type, comptime time: type, count: *std.atomic.Value(u32), expected: u32, timeout: time.duration.Duration) !void {
    var elapsed: time.duration.Duration = 0;
    while (elapsed < timeout) : (elapsed += time.duration.MilliSecond) {
        if (count.load(.acquire) >= expected) return;
        time.sleep(time.duration.MilliSecond);
    }
    return error.TimeoutWaitingForCount;
}

fn allocatorAlignment(comptime std: type) type {
    const alloc_ptr_type = @TypeOf(std.testing.allocator.vtable.alloc);
    const alloc_fn_type = @typeInfo(alloc_ptr_type).pointer.child;
    return @typeInfo(alloc_fn_type).@"fn".params[2].type.?;
}

fn JoinTaskType(comptime std: type) type {
    return struct {
        handle: std.task.Handle,

        fn spawn(comptime name: []const u8, comptime f: anytype, args: anytype) std.task.SpawnError!@This() {
            const TaskContext = struct {
                args: @TypeOf(args),

                fn run(ctx: *@This()) void {
                    const task_args = ctx.args;
                    std.testing.allocator.destroy(ctx);
                    call(task_args);
                }

                fn call(task_args: @TypeOf(args)) void {
                    const Return = @typeInfo(@TypeOf(f)).@"fn".return_type orelse
                        @compileError("racer helper task must have an explicit return type");

                    switch (@typeInfo(Return)) {
                        .void => @call(.auto, f, task_args),
                        .error_union => |eu| {
                            if (eu.payload != void)
                                @compileError("racer helper task must return void or !void");
                            _ = @call(.auto, f, task_args) catch {};
                        },
                        else => @compileError("racer helper task must return void or !void"),
                    }
                }
            };

            const ctx = std.testing.allocator.create(TaskContext) catch return error.OutOfMemory;
            errdefer std.testing.allocator.destroy(ctx);
            ctx.* = .{ .args = args };

            return .{
                .handle = try std.task.go(
                    name,
                    racer_task_options,
                    std.task.Routine.init(ctx, TaskContext.run),
                ),
            };
        }

        fn join(self: @This()) void {
            self.handle.join();
        }
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

fn CapturingTaskType(comptime std: type) type {
    _ = std;
    return struct {
        pub const Handle = struct {
            pub fn detach(self: @This()) void {
                _ = self;
            }

            pub fn join(self: @This()) void {
                _ = self;
            }
        };
        pub const Options = @import("task").Options;
        pub const Routine = @import("task").Routine;
        pub const SpawnError = error{};

        pub var last_min_stack_size: usize = 0;

        pub fn go(_: []const u8, options: Options, routine: Routine) SpawnError!Handle {
            last_min_stack_size = options.min_stack_size;
            routine.run();
            return .{};
        }

        pub fn currentToken() usize {
            return 1;
        }
    };
}

fn testSync() type {
    const native_std = @import("std");
    return struct {
        pub const Mutex = root.Mutex.make(native_std.Thread.Mutex);
        pub const Condition = root.Condition.make(native_std.Thread.Condition);
        pub const RwLock = root.RwLock.make(native_std.Thread.RwLock);
    };
}
