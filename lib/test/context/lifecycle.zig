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
    const testing = lib.testing;
    const CtxApi = context_root.make(lib);

    {
        var ctx_ns = try CtxApi.init(allocator);
        const bg = ctx_ns.background();
        var child = try ctx_ns.withCancel(bg);

        try testing.expect(ctx_ns.shared.background_impl.tree.children.first != null);

        child.deinit();
        try testing.expect(ctx_ns.shared.background_impl.tree.children.first == null);

        ctx_ns.deinit();
    }

    {
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
}
