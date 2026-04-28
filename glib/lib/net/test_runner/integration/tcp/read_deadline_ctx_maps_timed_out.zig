const stdz = @import("stdz");
const context_mod = @import("context");
const io = @import("io");
const testing_api = @import("testing");
const test_utils = @import("test_utils.zig");

pub fn make(comptime std: type, comptime net: type) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 192 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            const Body = struct {
                fn call(a: std.mem.Allocator) !void {
                    const Net = net;
                    const Context = context_mod.make(std, net.time);

                    var ctx_api = try Context.init(a);
                    defer ctx_api.deinit();

                    var io_ctx = try ctx_api.withTimeout(ctx_api.background(), 30 * @import("time").duration.MilliSecond);
                    defer io_ctx.deinit();

                    var ln = try Net.listen(a, .{ .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0) });
                    defer ln.deinit();

                    const port = try test_utils.listenerPort(ln, Net);

                    var cc = try Net.dial(a, .tcp, test_utils.addr4(.{ 127, 0, 0, 1 }, port));
                    defer cc.deinit();

                    var ac = try ln.accept();
                    defer ac.deinit();

                    const accepted = try ac.as(Net.TcpConn);
                    try accepted.setReadContext(io_ctx);

                    var buf: [16]u8 = undefined;
                    try std.testing.expectError(error.TimedOut, ac.read(&buf));

                    try accepted.setReadContext(null);
                    try io.writeAll(@TypeOf(cc), &cc, "ok");
                    try io.readFull(@TypeOf(ac), &ac, buf[0..2]);
                    try std.testing.expectEqualStrings("ok", buf[0..2]);
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
