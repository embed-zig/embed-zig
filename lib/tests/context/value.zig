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

            t.run("basic_lookup", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try valueBasicLookupCase(lib, case_allocator);
                }
            }.run));
            t.run("missing_key_returns_null", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try valueMissingKeyReturnsNullCase(lib, case_allocator);
                }
            }.run));
            t.run("chain_lookup_reads_parent_and_child", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try valueChainLookupReadsParentAndChildCase(lib, case_allocator);
                }
            }.run));
            t.run("nearest_value_shadows_parent", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try valueNearestValueShadowsParentCase(lib, case_allocator);
                }
            }.run));
            t.run("err_tracks_parent_cancellation", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try valueErrTracksParentCancellationCase(lib, case_allocator);
                }
            }.run));
            t.run("child_of_canceled_parent_starts_canceled", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try valueChildOfCanceledParentStartsCanceledCase(lib, case_allocator);
                }
            }.run));
            t.run("cancel_propagates_through_value_node", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try valueCancelPropagatesThroughValueNodeCase(lib, case_allocator);
                }
            }.run));
            t.run("deinit_drops_binding_and_reparents_children", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try valueDeinitDropsBindingAndReparentsChildrenCase(lib, case_allocator);
                }
            }.run));
            t.run("cancel_methods_are_noop_on_value_node", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try valueCancelMethodsAreNoopOnValueNodeCase(lib, case_allocator);
                }
            }.run));
            t.run("keeps_cause_after_parent_deinit", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try valueKeepsCauseAfterParentDeinitCase(lib, case_allocator);
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

fn valueBasicLookupCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    var key: Context.Key(u64) = .{};
    const bg = ctx_ns.background();
    var ctx = try ctx_ns.withValue(u64, bg, &key, 42);
    defer ctx.deinit();
    const val = ctx.value(u64, &key) orelse return error.ValueBasicGetFailed;
    if (val != 42) return error.ValueBasicGetWrong;
}

fn valueMissingKeyReturnsNullCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    var key_a: Context.Key(u64) = .{};
    var key_b: Context.Key(u64) = .{};
    const bg = ctx_ns.background();
    var ctx = try ctx_ns.withValue(u64, bg, &key_a, 42);
    defer ctx.deinit();
    if (ctx.value(u64, &key_b) != null) return error.MissingKeyShouldBeNull;
}

fn valueChainLookupReadsParentAndChildCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    var id_key: Context.Key(u64) = .{};
    var name_key: Context.Key(u32) = .{};
    const bg = ctx_ns.background();
    var vc1 = try ctx_ns.withValue(u64, bg, &id_key, 100);
    defer vc1.deinit();
    var ctx = try ctx_ns.withValue(u32, vc1, &name_key, 200);
    defer ctx.deinit();
    const id = ctx.value(u64, &id_key) orelse return error.ChainLookupIdFailed;
    const name = ctx.value(u32, &name_key) orelse return error.ChainLookupNameFailed;
    if (id != 100) return error.ChainLookupIdWrong;
    if (name != 200) return error.ChainLookupNameWrong;
}

fn valueNearestValueShadowsParentCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    var key: Context.Key(u64) = .{};
    const bg = ctx_ns.background();
    var vc1 = try ctx_ns.withValue(u64, bg, &key, 1);
    defer vc1.deinit();
    var ctx = try ctx_ns.withValue(u64, vc1, &key, 2);
    defer ctx.deinit();
    const val = ctx.value(u64, &key) orelse return error.ShadowingFailed;
    if (val != 2) return error.ShadowingWrongValue;
}

fn valueErrTracksParentCancellationCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    var key: Context.Key(u64) = .{};
    const bg = ctx_ns.background();
    var cc = try ctx_ns.withCancel(bg);
    defer cc.deinit();
    var ctx = try ctx_ns.withValue(u64, cc, &key, 42);
    defer ctx.deinit();
    if (ctx.err() != null) return error.ValueErrBeforeCancelShouldBeNull;
    cc.cancelWithCause(error.TimedOut);
    const e = ctx.err() orelse return error.ValueErrAfterCancelMissing;
    if (e != error.TimedOut) return error.ValueErrAfterCancelWrong;
}

fn valueChildOfCanceledParentStartsCanceledCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    var key: Context.Key(u64) = .{};
    const bg = ctx_ns.background();
    var parent_cc = try ctx_ns.withCancel(bg);
    defer parent_cc.deinit();
    parent_cc.cancelWithCause(error.TimedOut);

    var ctx = try ctx_ns.withValue(u64, parent_cc, &key, 42);
    defer ctx.deinit();

    const err = ctx.err() orelse return error.ValueChildOfCanceledParentShouldStartCanceled;
    if (err != error.TimedOut) return error.ValueChildOfCanceledParentWrongCause;

    const cause = ctx.wait(20 * lib.time.ns_per_ms) orelse return error.ValueChildOfCanceledParentWaitMissing;
    if (cause != error.TimedOut) return error.ValueChildOfCanceledParentWaitWrongCause;
}

fn valueCancelPropagatesThroughValueNodeCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    var key: Context.Key(u64) = .{};
    const bg = ctx_ns.background();
    var parent_cc = try ctx_ns.withCancel(bg);
    defer parent_cc.deinit();
    var vc = try ctx_ns.withValue(u64, parent_cc, &key, 99);
    defer vc.deinit();
    var child_cc = try ctx_ns.withCancel(vc);
    defer child_cc.deinit();
    if (child_cc.err() != null) return error.CancelThroughValueShouldStart;
    parent_cc.cancel();
    if (child_cc.err() == null) return error.CancelThroughValueFailed;
    const val = child_cc.value(u64, &key) orelse return error.CancelThroughValueLookupFailed;
    if (val != 99) return error.CancelThroughValueLookupWrong;
}

fn valueDeinitDropsBindingAndReparentsChildrenCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    var key: Context.Key(u64) = .{};
    const bg = ctx_ns.background();
    var parent_cc = try ctx_ns.withCancel(bg);
    defer parent_cc.deinit();
    var vc = try ctx_ns.withValue(u64, parent_cc, &key, 77);
    var child_cc = try ctx_ns.withCancel(vc);
    defer child_cc.deinit();

    const before = child_cc.value(u64, &key) orelse return error.ValueBeforeDeinitMissing;
    if (before != 77) return error.ValueBeforeDeinitWrong;

    vc.deinit();

    if (child_cc.value(u64, &key) != null) return error.ValueShouldDropAfterValueContextDeinit;
    parent_cc.cancel();
    if (child_cc.err() == null) return error.ChildShouldSurviveValueDeinitReparent;
}

fn valueCancelMethodsAreNoopOnValueNodeCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    var key: Context.Key(u64) = .{};
    const bg = ctx_ns.background();
    var parent_cc = try ctx_ns.withCancel(bg);
    defer parent_cc.deinit();
    var vc = try ctx_ns.withValue(u64, parent_cc, &key, 55);
    defer vc.deinit();
    var child_cc = try ctx_ns.withCancel(vc);
    defer child_cc.deinit();

    vc.cancel();
    vc.cancelWithCause(error.BrokenPipe);

    if (vc.err() != null) return error.ValueCancelShouldNotSetErr;
    if (child_cc.err() != null) return error.ValueCancelShouldNotAffectChildren;

    parent_cc.cancelWithCause(error.TimedOut);
    const child_err = child_cc.err() orelse return error.ParentCancelShouldStillPropagateAfterValueCancel;
    if (child_err != error.TimedOut) return error.ParentCancelAfterValueCancelWrongCause;
}

fn valueKeepsCauseAfterParentDeinitCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    var key: Context.Key(u64) = .{};
    const bg = ctx_ns.background();
    var parent_cc = try ctx_ns.withCancel(bg);
    var ctx = try ctx_ns.withValue(u64, parent_cc, &key, 42);
    defer ctx.deinit();

    parent_cc.cancelWithCause(error.TimedOut);
    const before = ctx.err() orelse return error.ValueCauseBeforeParentDeinitMissing;
    if (before != error.TimedOut) return error.ValueCauseBeforeParentDeinitWrong;

    parent_cc.deinit();

    const after = ctx.err() orelse return error.ValueCauseAfterParentDeinitMissing;
    if (after != error.TimedOut) return error.ValueCauseAfterParentDeinitWrong;
}
