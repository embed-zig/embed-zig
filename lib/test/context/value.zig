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
        var key: Context.Key(u64) = .{};
        const bg = ctx_ns.background();
        var ctx = try ctx_ns.withValue(u64, bg, &key, 42);
        defer ctx.deinit();
        const val = ctx.value(u64, &key) orelse return error.ValueBasicGetFailed;
        if (val != 42) return error.ValueBasicGetWrong;
    }

    {
        var key_a: Context.Key(u64) = .{};
        var key_b: Context.Key(u64) = .{};
        const bg = ctx_ns.background();
        var ctx = try ctx_ns.withValue(u64, bg, &key_a, 42);
        defer ctx.deinit();
        if (ctx.value(u64, &key_b) != null) return error.MissingKeyShouldBeNull;
    }

    {
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

    {
        var key: Context.Key(u64) = .{};
        const bg = ctx_ns.background();
        var vc1 = try ctx_ns.withValue(u64, bg, &key, 1);
        defer vc1.deinit();
        var ctx = try ctx_ns.withValue(u64, vc1, &key, 2);
        defer ctx.deinit();
        const val = ctx.value(u64, &key) orelse return error.ShadowingFailed;
        if (val != 2) return error.ShadowingWrongValue;
    }

    {
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

    {
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

    {
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

    {
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
}
