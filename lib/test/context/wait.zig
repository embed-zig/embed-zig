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
            runImpl(lib, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
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

fn runImpl(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    {
        const bg = ctx_ns.background();
        var ctx = try ctx_ns.withCancel(bg);
        defer ctx.deinit();
        ctx.cancel();
        const cause = ctx.wait(null) orelse return error.WaitAfterCancelShouldReturn;
        if (cause != error.Canceled) return error.WaitAfterCancelWrongCause;
    }

    {
        const bg = ctx_ns.background();
        var ctx = try ctx_ns.withCancel(bg);
        defer ctx.deinit();
        if (ctx.wait(50 * lib.time.ns_per_ms) != null) return error.WaitTimeoutShouldReturnNull;
    }

    {
        const bg = ctx_ns.background();
        var ctx = try ctx_ns.withCancel(bg);
        defer ctx.deinit();
        const cancel_impl = try ctx.as(@TypeOf(ctx_ns).CancelContext);

        var timer = try lib.time.Timer.start();
        const t = try lib.Thread.spawn(.{}, struct {
            fn wake(cancel_ctx: *@TypeOf(ctx_ns).CancelContext, l: type) void {
                l.Thread.sleep(5 * l.time.ns_per_ms);
                cancel_ctx.cond.signal();
            }
        }.wake, .{ cancel_impl, lib });
        defer t.join();

        if (ctx.wait(40 * lib.time.ns_per_ms) != null) return error.WaitSpuriousWakeShouldReturnNull;
        if (timer.read() < 20 * lib.time.ns_per_ms) return error.WaitReturnedTooEarlyAfterSpuriousWake;
    }

    {
        const bg = ctx_ns.background();
        var ctx = try ctx_ns.withCancel(bg);
        defer ctx.deinit();
        ctx.cancelWithCause(error.TimedOut);
        const cause = ctx.wait(50 * lib.time.ns_per_ms) orelse return error.WaitAlreadyCanceledMissing;
        if (cause != error.TimedOut) return error.WaitAlreadyCanceledWrongCause;
    }

    {
        var key: Context.Key(u64) = .{};
        const bg = ctx_ns.background();
        var cc = try ctx_ns.withCancel(bg);
        defer cc.deinit();
        var ctx = try ctx_ns.withValue(u64, cc, &key, 42);
        defer ctx.deinit();
        cc.cancel();
        const cause = ctx.wait(100 * lib.time.ns_per_ms) orelse return error.WaitThroughValueMissing;
        if (cause != error.Canceled) return error.WaitThroughValueWrongCause;
    }

    {
        const bg = ctx_ns.background();
        var ctx = try ctx_ns.withTimeout(bg, 100 * lib.time.ns_per_ms);
        defer ctx.deinit();
        const cause = ctx.wait(null) orelse return error.WaitDeadlineVtableMissing;
        if (cause != error.DeadlineExceeded) return error.WaitDeadlineVtableWrongCause;
    }

    {
        const bg = ctx_ns.background();
        if (bg.wait(50 * lib.time.ns_per_ms) != null) return error.BackgroundWaitShouldReturnNull;
    }
}
