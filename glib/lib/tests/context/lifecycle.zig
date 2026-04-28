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

            t.run("child_detach_leaves_root_empty", testing_mod.TestRunner.fromFn(std, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try childDetachLeavesRootEmptyCase(std, time, case_allocator);
                }
            }.run));
            t.run("parent_deinit_reparents_child", testing_mod.TestRunner.fromFn(std, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: std.mem.Allocator) !void {
                    try parentDeinitReparentsChildCase(std, time, case_allocator);
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

fn childDetachLeavesRootEmptyCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const testing = std.testing;
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    const bg = ctx_api.background();
    var child = try ctx_api.withCancel(bg);

    try testing.expect(ctx_api.shared.background_impl.tree.children.first != null);

    child.deinit();
    try testing.expect(ctx_api.shared.background_impl.tree.children.first == null);

    ctx_api.deinit();
}

fn parentDeinitReparentsChildCase(comptime std: type, comptime time: type, allocator: std.mem.Allocator) !void {
    const testing = std.testing;
    const CtxApi = context_root.make(std, time);
    var ctx_api = try CtxApi.init(allocator);
    const bg = ctx_api.background();
    var parent = try ctx_api.withCancel(bg);
    var child = try ctx_api.withCancel(parent);

    parent.deinit();
    try testing.expect(ctx_api.shared.background_impl.tree.children.first != null);

    child.deinit();
    try testing.expect(ctx_api.shared.background_impl.tree.children.first == null);

    ctx_api.deinit();
}
