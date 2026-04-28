const stdz = @import("stdz");
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

                    const loopback_v6 = try test_utils.addr6("::1", 0);

                    var ln = try Net.listen(a, .{ .address = loopback_v6 });
                    defer ln.deinit();

                    const bound_port = try test_utils.listenerPort(ln, Net);

                    const dial_addr = loopback_v6.withPort(bound_port);

                    var cc = try Net.dial(a, .tcp, dial_addr);
                    defer cc.deinit();

                    var ac = try ln.accept();
                    defer ac.deinit();

                    const msg = "hello net.dial v6";
                    try io.writeAll(@TypeOf(cc), &cc, msg);

                    var buf: [64]u8 = undefined;
                    try io.readFull(@TypeOf(ac), &ac, buf[0..msg.len]);
                    try std.testing.expectEqualStrings(msg, buf[0..msg.len]);

                    try io.writeAll(@TypeOf(ac), &ac, "v6ok");
                    try io.readFull(@TypeOf(cc), &cc, buf[0..4]);
                    try std.testing.expectEqualStrings("v6ok", buf[0..4]);
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
