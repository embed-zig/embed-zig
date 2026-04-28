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

            t.run("cancel_with_cause_sets_error", testing_mod.TestRunner.fromFn(std, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try cancelWithCauseSetsErrorCase(std, time, case_allocator);
                }
            }.run));
            t.run("first_cause_wins", testing_mod.TestRunner.fromFn(std, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try firstCauseWinsCase(std, time, case_allocator);
                }
            }.run));
            t.run("cause_propagates_to_child", testing_mod.TestRunner.fromFn(std, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try causePropagatesToChildCase(std, time, case_allocator);
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

fn cancelWithCauseSetsErrorCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const bg = ctx_api.background();
    var cc = try ctx_api.withCancel(bg);
    defer cc.deinit();
    cc.cancelWithCause(error.TimedOut);
    const e = cc.err() orelse return error.CauseShouldExist;
    if (e != error.TimedOut) return error.CauseWrongValue;
}

fn firstCauseWinsCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const bg = ctx_api.background();
    var cc = try ctx_api.withCancel(bg);
    defer cc.deinit();
    cc.cancelWithCause(error.TimedOut);
    cc.cancelWithCause(error.BrokenPipe);
    const e = cc.err() orelse return error.FirstCauseShouldWin;
    if (e != error.TimedOut) return error.FirstCauseWrongValue;
}

fn causePropagatesToChildCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    defer ctx_api.deinit();

    const bg = ctx_api.background();
    var parent = try ctx_api.withCancel(bg);
    defer parent.deinit();
    var child = try ctx_api.withCancel(parent);
    defer child.deinit();
    parent.cancelWithCause(error.ConnectionReset);
    const pe = parent.err() orelse return error.ParentCauseMissing;
    const ce = child.err() orelse return error.ChildCauseMissing;
    if (pe != error.ConnectionReset) return error.ParentCauseWrong;
    if (ce != error.ConnectionReset) return error.ChildCauseWrong;
}
