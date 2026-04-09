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

            t.run("child_detach_leaves_root_empty", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try childDetachLeavesRootEmptyCase(lib, case_allocator);
                }
            }.run));
            t.run("parent_deinit_reparents_child", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(_: *testing_mod.T, case_allocator: lib.mem.Allocator) !void {
                    try parentDeinitReparentsChildCase(lib, case_allocator);
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

fn childDetachLeavesRootEmptyCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const testing = lib.testing;
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    const bg = ctx_ns.background();
    var child = try ctx_ns.withCancel(bg);

    try testing.expect(ctx_ns.shared.background_impl.tree.children.first != null);

    child.deinit();
    try testing.expect(ctx_ns.shared.background_impl.tree.children.first == null);

    ctx_ns.deinit();
}

fn parentDeinitReparentsChildCase(comptime lib: type, allocator: lib.mem.Allocator) !void {
    const testing = lib.testing;
    const CtxApi = context_root.make(lib);
    var ctx_ns = try CtxApi.init(allocator);
    const bg = ctx_ns.background();
    var parent = try ctx_ns.withCancel(bg);
    var child = try ctx_ns.withCancel(parent);

    parent.deinit();
    try testing.expect(ctx_ns.shared.background_impl.tree.children.first != null);

    child.deinit();
    try testing.expect(ctx_ns.shared.background_impl.tree.children.first == null);

    ctx_ns.deinit();
}
