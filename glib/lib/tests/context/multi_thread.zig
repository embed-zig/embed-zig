const stdz = @import("stdz");
const testing_mod = @import("testing");
const context_root = @import("context");
const time_mod = @import("time");

const Context = context_root.Context;

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

    const t = try std.Thread.spawn(.{}, struct {
        fn work(c: *Context) void {
            const cause = c.wait(null);
            std.debug.assert(cause != null);
            std.debug.assert(cause.? == error.Canceled);
        }
    }.work, .{&cc});

    std.Thread.sleep(@intCast(5 * time_mod.duration.MilliSecond));
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

    const t = try std.Thread.spawn(.{}, struct {
        fn work(c: *Context) void {
            const cause = c.wait(null);
            std.debug.assert(cause != null);
            std.debug.assert(cause.? == error.BrokenPipe);
        }
    }.work, .{&cc});

    std.Thread.sleep(@intCast(5 * time_mod.duration.MilliSecond));
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

    const t = try std.Thread.spawn(.{}, struct {
        fn work(c: *Context) void {
            const cause = c.wait(null);
            std.debug.assert(cause != null);
            std.debug.assert(cause.? == error.Canceled);
        }
    }.work, .{&child});

    std.Thread.sleep(@intCast(5 * time_mod.duration.MilliSecond));
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
    var threads: [6]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn work(api: *const Api) void {
                var i: usize = 0;
                while (i < 200) : (i += 1) {
                    var ctx = api.withCancel(api.background()) catch unreachable;
                    ctx.deinit();
                }
            }
        }.work, .{&ctx_api});
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

    const t = try std.Thread.spawn(.{}, struct {
        fn work(c: *Context) void {
            var i: usize = 0;
            while (i < 10_000) : (i += 1) {
                _ = c.deadline();
            }
        }
    }.work, .{&child});

    std.Thread.sleep(@intCast(1 * time_mod.duration.MilliSecond));
    parent.deinit();
    t.join();

    if (child.deadline() == null) return error.ReparentedChildShouldKeepDeadline;
    child.cancel();
}
