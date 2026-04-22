const stdz = @import("stdz");
const testing_mod = @import("testing");
const context_root = @import("context");
const Context = context_root.Context;

pub fn make(comptime lib: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("cancel_with_cause_sets_error", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try cancelWithCauseSetsErrorCase(lib, case_allocator);
                }
            }.run));
            t.run("first_cause_wins", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try firstCauseWinsCase(lib, case_allocator);
                }
            }.run));
            t.run("cause_propagates_to_child", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try causePropagatesToChildCase(lib, case_allocator);
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

fn cancelWithCauseSetsErrorCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var cc = try ctx_ns.withCancel(bg);
    defer cc.deinit();
    cc.cancelWithCause(error.TimedOut);
    const e = cc.err() orelse return error.CauseShouldExist;
    if (e != error.TimedOut) return error.CauseWrongValue;
}

fn firstCauseWinsCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var cc = try ctx_ns.withCancel(bg);
    defer cc.deinit();
    cc.cancelWithCause(error.TimedOut);
    cc.cancelWithCause(error.BrokenPipe);
    const e = cc.err() orelse return error.FirstCauseShouldWin;
    if (e != error.TimedOut) return error.FirstCauseWrongValue;
}

fn causePropagatesToChildCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    defer ctx_ns.deinit();

    const bg = ctx_ns.background();
    var parent = try ctx_ns.withCancel(bg);
    defer parent.deinit();
    var child = try ctx_ns.withCancel(parent);
    defer child.deinit();
    parent.cancelWithCause(error.ConnectionReset);
    const pe = parent.err() orelse return error.ParentCauseMissing;
    const ce = child.err() orelse return error.ChildCauseMissing;
    if (pe != error.ConnectionReset) return error.ParentCauseWrong;
    if (ce != error.ConnectionReset) return error.ChildCauseWrong;
}
