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

                    var ln = try Net.listen(a, .{ .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0) });
                    defer ln.deinit();

                    const bound_port = try test_utils.listenerPort(ln, Net);
                    const d = Net.Dialer.init(a, .{});

                    var cc = try d.dial(.tcp, test_utils.addr4(.{ 127, 0, 0, 1 }, bound_port));
                    defer cc.deinit();

                    var ac = try ln.accept();
                    defer ac.deinit();

                    const msg = "hello Dialer.dial tcp";
                    try io.writeAll(@TypeOf(cc), &cc, msg);

                    var buf: [64]u8 = undefined;
                    try io.readFull(@TypeOf(ac), &ac, buf[0..msg.len]);
                    try std.testing.expectEqualStrings(msg, buf[0..msg.len]);

                    var ctx_conn = try d.dialContext(ctx_api.background(), .tcp, test_utils.addr4(.{ 127, 0, 0, 1 }, bound_port));
                    defer ctx_conn.deinit();

                    var ctx_ac = try ln.accept();
                    defer ctx_ac.deinit();

                    const ctx_msg = "hello dialContext tcp";
                    try io.writeAll(@TypeOf(ctx_conn), &ctx_conn, ctx_msg);
                    try io.readFull(@TypeOf(ctx_ac), &ctx_ac, buf[0..ctx_msg.len]);
                    try std.testing.expectEqualStrings(ctx_msg, buf[0..ctx_msg.len]);
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
