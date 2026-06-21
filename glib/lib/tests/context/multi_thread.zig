const stdz = @import("stdz");
const testing_mod = @import("testing");
const context_root = @import("context");
const task_mod = @import("task");
const time_mod = @import("time");

const Context = context_root.Context;
const waiter_task_options: task_mod.Options = .{ .min_stack_size = 4 * 1024 };
const create_deinit_task_options: task_mod.Options = .{ .min_stack_size = 8 * 1024 };
const deadline_reader_task_options: task_mod.Options = .{ .min_stack_size = 4 * 1024 };

pub fn make(comptime std: type, comptime time: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("cancel_wakes_waiter", testing_mod.TestRunner.fromFn(std, 48 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try multiThreadCancelWakesWaiterCase(std, time, case_allocator);
                }
            }.run));
            t.run("custom_cause_wakes_waiter", testing_mod.TestRunner.fromFn(std, 48 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try multiThreadCustomCauseWakesWaiterCase(std, time, case_allocator);
                }
            }.run));
            t.run("parent_cancel_wakes_child_waiter", testing_mod.TestRunner.fromFn(std, 48 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try multiThreadParentCancelWakesChildWaiterCase(std, time, case_allocator);
                }
            }.run));
            t.run("concurrent_create_and_deinit", testing_mod.TestRunner.fromFn(std, 64 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try multiThreadConcurrentCreateAndDeinitCase(std, time, case_allocator);
                }
            }.run));
            t.run("deadline_reparent_keeps_child_deadline", testing_mod.TestRunner.fromFn(std, 64 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try multiThreadDeadlineReparentKeepsChildDeadlineCase(std, time, case_allocator);
                }
            }.run));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_mod.TestRunner.make(Runner).new(&Holder.runner);
}

fn multiThreadCancelWakesWaiterCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const bg = ctx_api.background();
    var cc = try ctx_api.withCancel(bg);
    defer cc.deinit();

    const Worker = struct {
        ctx: *Context,

        fn run(self: *@This()) void {
            const cause = self.ctx.wait(null);
            std.debug.assert(cause != null);
            std.debug.assert(cause.? == error.Canceled);
        }
    };
    var worker: Worker = .{ .ctx = &cc };
    const t = try std.task.go("testing/context/waiter", waiter_task_options, task_mod.Routine.init(&worker, Worker.run));

    time.sleep(5 * time_mod.duration.MilliSecond);
    cc.cancel();
    t.join();

    const e = cc.err() orelse return error.MultiThreadCancelMissing;
    if (e != error.Canceled) return error.MultiThreadCancelWrong;
}

fn multiThreadCustomCauseWakesWaiterCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const bg = ctx_api.background();
    var cc = try ctx_api.withCancel(bg);
    defer cc.deinit();

    const Worker = struct {
        ctx: *Context,

        fn run(self: *@This()) void {
            const cause = self.ctx.wait(null);
            std.debug.assert(cause != null);
            std.debug.assert(cause.? == error.BrokenPipe);
        }
    };
    var worker: Worker = .{ .ctx = &cc };
    const t = try std.task.go("testing/context/waiter", waiter_task_options, task_mod.Routine.init(&worker, Worker.run));

    time.sleep(5 * time_mod.duration.MilliSecond);
    cc.cancelWithCause(error.BrokenPipe);
    t.join();

    const e = cc.err() orelse return error.MultiThreadCauseMissing;
    if (e != error.BrokenPipe) return error.MultiThreadCauseWrong;
}

fn multiThreadParentCancelWakesChildWaiterCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const bg = ctx_api.background();
    var parent = try ctx_api.withCancel(bg);
    defer parent.deinit();
    var child = try ctx_api.withCancel(parent);
    defer child.deinit();

    const Worker = struct {
        ctx: *Context,

        fn run(self: *@This()) void {
            const cause = self.ctx.wait(null);
            std.debug.assert(cause != null);
            std.debug.assert(cause.? == error.Canceled);
        }
    };
    var worker: Worker = .{ .ctx = &child };
    const t = try std.task.go("testing/context/waiter", waiter_task_options, task_mod.Routine.init(&worker, Worker.run));

    time.sleep(5 * time_mod.duration.MilliSecond);
    parent.cancel();
    t.join();

    const e = child.err() orelse return error.MultiThreadParentWakeMissing;
    if (e != error.Canceled) return error.MultiThreadParentWakeWrong;
}

fn multiThreadConcurrentCreateAndDeinitCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const Api = @TypeOf(ctx_api);
    const Worker = struct {
        api: *const Api,

        fn run(self: *@This()) void {
            var i: usize = 0;
            while (i < 200) : (i += 1) {
                var ctx = self.api.withCancel(self.api.background()) catch unreachable;
                ctx.deinit();
            }
        }
    };
    var workers: [6]Worker = undefined;
    var threads: [6]std.task.Handle = undefined;
    for (&threads, &workers) |*t, *worker| {
        worker.* = .{ .api = &ctx_api };
        t.* = try std.task.go("testing/context/create_deinit", create_deinit_task_options, task_mod.Routine.init(worker, Worker.run));
    }
    for (threads) |t| t.join();
}

fn multiThreadDeadlineReparentKeepsChildDeadlineCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const bg = ctx_api.background();
    var parent = try ctx_api.withDeadline(bg, time_mod.instant.add(ctx_api.now(), 1000 * time_mod.duration.MilliSecond));
    var child = try ctx_api.withDeadline(parent, time_mod.instant.add(ctx_api.now(), 2000 * time_mod.duration.MilliSecond));
    defer child.deinit();

    const Worker = struct {
        ctx: *Context,

        fn run(self: *@This()) void {
            var i: usize = 0;
            while (i < 10_000) : (i += 1) {
                _ = self.ctx.deadline();
            }
        }
    };
    var worker: Worker = .{ .ctx = &child };
    const t = try std.task.go("testing/context/deadline_reader", deadline_reader_task_options, task_mod.Routine.init(&worker, Worker.run));

    time.sleep(1 * time_mod.duration.MilliSecond);
    parent.deinit();
    t.join();

    if (child.deadline() == null) return error.ReparentedChildShouldKeepDeadline;
    child.cancel();
}
