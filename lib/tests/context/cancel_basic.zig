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

            t.run("starts_without_error", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try cancelStartsWithoutErrorCase(lib, case_allocator);
                }
            }.run));
            t.run("cancel_sets_canceled_error", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try cancelSetsCanceledErrorCase(lib, case_allocator);
                }
            }.run));
            t.run("cancel_is_idempotent", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try cancelIsIdempotentCase(lib, case_allocator);
                }
            }.run));
            t.run("cancel_has_no_deadline", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try cancelHasNoDeadlineCase(lib, case_allocator);
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

fn cancelStartsWithoutErrorCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var cc = try ctx_ns.withCancel(bg);
    defer cc.deinit();
    if (cc.err() != null) return error.ErrBeforeCancelShouldBeNull;
}

fn cancelSetsCanceledErrorCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var cc = try ctx_ns.withCancel(bg);
    defer cc.deinit();
    cc.cancel();
    const e = cc.err() orelse return error.ErrAfterCancelShouldExist;
    if (e != error.Canceled) return error.ErrAfterCancelWrongValue;
}

fn cancelIsIdempotentCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var cc = try ctx_ns.withCancel(bg);
    defer cc.deinit();
    cc.cancel();
    cc.cancel();
    cc.cancel();
    const e = cc.err() orelse return error.IdempotentCancelFailed;
    if (e != error.Canceled) return error.IdempotentCancelWrongValue;
}

fn cancelHasNoDeadlineCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var cc = try ctx_ns.withCancel(bg);
    defer cc.deinit();
    if (cc.deadline() != null) return error.CancelShouldHaveNoDeadline;
}
