const stdz = @import("stdz");
const testing_mod = @import("testing");
const context_root = @import("context");
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

            t.run("starts_without_error", testing_mod.TestRunner.fromFn(std, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try cancelStartsWithoutErrorCase(std, time, case_allocator);
                }
            }.run));
            t.run("cancel_sets_canceled_error", testing_mod.TestRunner.fromFn(std, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try cancelSetsCanceledErrorCase(std, time, case_allocator);
                }
            }.run));
            t.run("cancel_is_idempotent", testing_mod.TestRunner.fromFn(std, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try cancelIsIdempotentCase(std, time, case_allocator);
                }
            }.run));
            t.run("cancel_has_no_deadline", testing_mod.TestRunner.fromFn(std, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try cancelHasNoDeadlineCase(std, time, case_allocator);
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

fn cancelStartsWithoutErrorCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const bg = ctx_api.background();
    var cc = try ctx_api.withCancel(bg);
    defer cc.deinit();
    if (cc.err() != null) return error.ErrBeforeCancelShouldBeNull;
}

fn cancelSetsCanceledErrorCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const bg = ctx_api.background();
    var cc = try ctx_api.withCancel(bg);
    defer cc.deinit();
    cc.cancel();
    const e = cc.err() orelse return error.ErrAfterCancelShouldExist;
    if (e != error.Canceled) return error.ErrAfterCancelWrongValue;
}

fn cancelIsIdempotentCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const bg = ctx_api.background();
    var cc = try ctx_api.withCancel(bg);
    defer cc.deinit();
    cc.cancel();
    cc.cancel();
    cc.cancel();
    const e = cc.err() orelse return error.IdempotentCancelFailed;
    if (e != error.Canceled) return error.IdempotentCancelWrongValue;
}

fn cancelHasNoDeadlineCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const bg = ctx_api.background();
    var cc = try ctx_api.withCancel(bg);
    defer cc.deinit();
    if (cc.deadline() != null) return error.CancelShouldHaveNoDeadline;
}
