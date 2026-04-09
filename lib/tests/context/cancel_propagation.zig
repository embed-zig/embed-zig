const embed = @import("embed");
const testing_mod = @import("testing");
const context_root = @import("context");
const Context = context_root.Context;
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("parent_cancel_reaches_child", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try parentCancelReachesChildCase(lib, case_allocator);
                }
            }.run));
            t.run("deep_tree_cancel_reaches_all_levels", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try deepTreeCancelReachesAllLevelsCase(lib, case_allocator);
                }
            }.run));
            t.run("child_cancel_does_not_affect_parent", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try childCancelDoesNotAffectParentCase(lib, case_allocator);
                }
            }.run));
            t.run("sibling_cancel_is_isolated_until_parent_cancel", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try siblingCancelIsIsolatedUntilParentCancelCase(lib, case_allocator);
                }
            }.run));
            t.run("deinit_detached_child_before_parent_cancel", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try deinitDetachedChildBeforeParentCancelCase(lib, case_allocator);
                }
            }.run));
            t.run("deinit_reparents_grandchildren", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try deinitReparentsGrandchildrenCase(lib, case_allocator);
                }
            }.run));
            t.run("child_of_canceled_parent_starts_canceled", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try childOfCanceledParentStartsCanceledCase(lib, case_allocator);
                }
            }.run));
            t.run("attach_observes_parent_cancel_race", testing_mod.TestRunner.fromFn(lib, 32 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try attachObservesParentCancelRaceCase(lib, case_allocator);
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

fn parentCancelReachesChildCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var parent = try ctx_ns.withCancel(bg);
    defer parent.deinit();
    var child = try ctx_ns.withCancel(parent);
    defer child.deinit();
    if (child.err() != null) return error.ChildShouldStartActive;
    parent.cancel();
    if (parent.err() == null) return error.ParentShouldBeCanceled;
    if (child.err() == null) return error.ChildShouldBeCanceled;
}

fn deepTreeCancelReachesAllLevelsCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var a = try ctx_ns.withCancel(bg);
    defer a.deinit();
    var b = try ctx_ns.withCancel(a);
    defer b.deinit();
    var c = try ctx_ns.withCancel(b);
    defer c.deinit();
    if (c.err() != null) return error.ThreeLevelShouldStartActive;
    a.cancel();
    if (a.err() == null) return error.ThreeLevelANotCanceled;
    if (b.err() == null) return error.ThreeLevelBNotCanceled;
    if (c.err() == null) return error.ThreeLevelCNotCanceled;
}

fn childCancelDoesNotAffectParentCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var parent = try ctx_ns.withCancel(bg);
    defer parent.deinit();
    var child = try ctx_ns.withCancel(parent);
    defer child.deinit();
    child.cancel();
    if (child.err() == null) return error.ChildCancelFailed;
    if (parent.err() != null) return error.ChildCancelAffectedParent;
}

fn siblingCancelIsIsolatedUntilParentCancelCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var parent = try ctx_ns.withCancel(bg);
    defer parent.deinit();
    var a = try ctx_ns.withCancel(parent);
    defer a.deinit();
    var b = try ctx_ns.withCancel(parent);
    defer b.deinit();
    a.cancel();
    if (a.err() == null) return error.SiblingACancelFailed;
    if (b.err() != null) return error.SiblingBShouldBeActive;
    parent.cancel();
    if (b.err() == null) return error.SiblingBShouldBeCanceled;
}

fn deinitDetachedChildBeforeParentCancelCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var parent = try ctx_ns.withCancel(bg);
    defer parent.deinit();
    {
        var child = try ctx_ns.withCancel(parent);
        child.deinit();
    }
    parent.cancel();
}

fn deinitReparentsGrandchildrenCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var a = try ctx_ns.withCancel(bg);
    defer a.deinit();
    var b = try ctx_ns.withCancel(a);
    var c = try ctx_ns.withCancel(b);
    defer c.deinit();
    var d = try ctx_ns.withCancel(b);
    defer d.deinit();

    b.deinit();
    a.cancelWithCause(error.BrokenPipe);

    const ce = c.err() orelse return error.ReparentedCShouldBeCanceled;
    const de = d.err() orelse return error.ReparentedDShouldBeCanceled;
    if (ce != error.BrokenPipe) return error.ReparentedCWrongCause;
    if (de != error.BrokenPipe) return error.ReparentedDWrongCause;
}

fn childOfCanceledParentStartsCanceledCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var parent = try ctx_ns.withCancel(bg);
    defer parent.deinit();
    parent.cancelWithCause(error.TimedOut);
    var child = try ctx_ns.withCancel(parent);
    defer child.deinit();
    const e = child.err() orelse return error.ChildOfCanceledShouldStart;
    if (e != error.TimedOut) return error.ChildOfCanceledWrongCause;
}

fn attachObservesParentCancelRaceCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const RaceParent = test_utils.LockCancelParentType(lib);
    var parent_impl: RaceParent = .{};
    const parent = parent_impl.context(allocator);
    parent_impl.cancel_on_next_lock = true;

    var child = try ctx_ns.withCancel(parent);
    defer child.deinit();

    const e = child.err() orelse return error.ChildInitShouldObserveParentCancelDuringAttach;
    if (e != error.BrokenPipe) return error.ChildInitParentCancelDuringAttachWrongCause;
}
