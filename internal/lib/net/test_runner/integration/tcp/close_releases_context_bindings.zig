const stdz = @import("stdz");
const context_mod = @import("context");
const testing_api = @import("testing");
const net = @import("../../../../net.zig");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 192 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            const Body = struct {
                fn call(a: lib.mem.Allocator) !void {
                    const Net = net.make(lib);
                    const Context = context_mod.make(lib);

                    var ctx_api = try Context.init(a);
                    var io_ctx = try ctx_api.withCancel(ctx_api.background());

                    var ln = try Net.listen(a, .{ .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0) });
                    defer ln.deinit();

                    const port = try test_utils.listenerPort(ln, Net);

                    var cc = try Net.dial(a, .tcp, test_utils.addr4(.{ 127, 0, 0, 1 }, port));
                    defer cc.deinit();

                    var ac = try ln.accept();
                    defer ac.deinit();

                    const accepted = try ac.as(Net.TcpConn);
                    try accepted.setReadContext(io_ctx);
                    try accepted.setWriteContext(io_ctx);

                    accepted.close();

                    // close() should release both side-owned child contexts immediately,
                    // so the parent context tree can be torn down before conn deinit().
                    io_ctx.deinit();
                    ctx_api.deinit();
                }
            };
            Body.call(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
