const embed = @import("embed");
const testing_mod = @import("testing");
const context_root = @import("context");
const Context = context_root.Context;

pub fn make(comptime lib: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("cancel_wakes_waiter", testing_mod.TestRunner.fromFn(lib, 48 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try multiThreadCancelWakesWaiterCase(lib, case_allocator);
                }
            }.run));
            t.run("custom_cause_wakes_waiter", testing_mod.TestRunner.fromFn(lib, 48 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try multiThreadCustomCauseWakesWaiterCase(lib, case_allocator);
                }
            }.run));
            t.run("parent_cancel_wakes_child_waiter", testing_mod.TestRunner.fromFn(lib, 48 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try multiThreadParentCancelWakesChildWaiterCase(lib, case_allocator);
                }
            }.run));
            t.run("concurrent_create_and_deinit", testing_mod.TestRunner.fromFn(lib, 64 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try multiThreadConcurrentCreateAndDeinitCase(lib, case_allocator);
                }
            }.run));
            t.run("deadline_reparent_keeps_child_deadline", testing_mod.TestRunner.fromFn(lib, 64 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try multiThreadDeadlineReparentKeepsChildDeadlineCase(lib, case_allocator);
                }
            }.run));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_mod.TestRunner.make(Runner).new(&Holder.runner);
}

fn multiThreadCancelWakesWaiterCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var cc = try ctx_ns.withCancel(bg);
    defer cc.deinit();

    const t = try lib.Thread.spawn(.{}, struct {
        fn work(c: *Context) void {
            const cause = c.wait(null);
            lib.debug.assert(cause != null);
            lib.debug.assert(cause.? == error.Canceled);
        }
    }.work, .{&cc});

    lib.Thread.sleep(5_000_000);
    cc.cancel();
    t.join();

    const e = cc.err() orelse return error.MultiThreadCancelMissing;
    if (e != error.Canceled) return error.MultiThreadCancelWrong;
}

fn multiThreadCustomCauseWakesWaiterCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var cc = try ctx_ns.withCancel(bg);
    defer cc.deinit();

    const t = try lib.Thread.spawn(.{}, struct {
        fn work(c: *Context) void {
            const cause = c.wait(null);
            lib.debug.assert(cause != null);
            lib.debug.assert(cause.? == error.BrokenPipe);
        }
    }.work, .{&cc});

    lib.Thread.sleep(5_000_000);
    cc.cancelWithCause(error.BrokenPipe);
    t.join();

    const e = cc.err() orelse return error.MultiThreadCauseMissing;
    if (e != error.BrokenPipe) return error.MultiThreadCauseWrong;
}

fn multiThreadParentCancelWakesChildWaiterCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var parent = try ctx_ns.withCancel(bg);
    defer parent.deinit();
    var child = try ctx_ns.withCancel(parent);
    defer child.deinit();

    const t = try lib.Thread.spawn(.{}, struct {
        fn work(c: *Context) void {
            const cause = c.wait(null);
            lib.debug.assert(cause != null);
            lib.debug.assert(cause.? == error.Canceled);
        }
    }.work, .{&child});

    lib.Thread.sleep(5_000_000);
    parent.cancel();
    t.join();

    const e = child.err() orelse return error.MultiThreadParentWakeMissing;
    if (e != error.Canceled) return error.MultiThreadParentWakeWrong;
}

fn multiThreadConcurrentCreateAndDeinitCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const Api = @TypeOf(ctx_ns);
    var threads: [6]lib.Thread = undefined;
    for (&threads) |*t| {
        t.* = try lib.Thread.spawn(.{}, struct {
            fn work(api: *const Api) void {
                var i: usize = 0;
                while (i < 200) : (i += 1) {
                    var ctx = api.withCancel(api.background()) catch unreachable;
                    ctx.deinit();
                }
            }
        }.work, .{&ctx_ns});
    }
    for (threads) |t| t.join();
}

fn multiThreadDeadlineReparentKeepsChildDeadlineCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var parent = try ctx_ns.withDeadline(bg, lib.time.nanoTimestamp() + 1000 * lib.time.ns_per_ms);
    var child = try ctx_ns.withDeadline(parent, lib.time.nanoTimestamp() + 2000 * lib.time.ns_per_ms);
    defer child.deinit();

    const t = try lib.Thread.spawn(.{}, struct {
        fn work(c: *Context) void {
            var i: usize = 0;
            while (i < 10_000) : (i += 1) {
                _ = c.deadline();
            }
        }
    }.work, .{&child});

    lib.Thread.sleep(1_000_000);
    parent.deinit();
    t.join();

    if (child.deadline() == null) return error.ReparentedChildShouldKeepDeadline;
    child.cancel();
}
