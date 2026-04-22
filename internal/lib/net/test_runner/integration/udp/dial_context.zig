const stdz = @import("stdz");
const context_mod = @import("context");
const testing_api = @import("testing");
const net_mod = @import("../../../../net.zig");
const test_utils = @import("../tcp/test_utils.zig");

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
                    const Net = net_mod.make(lib);
                    const Context = context_mod.make(lib);

                    var ctx_api = try Context.init(a);
                    defer ctx_api.deinit();

                    var pc = try Net.listenPacket(.{
                        .allocator = a,
                        .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    });
                    defer pc.deinit();

                    const udp_impl = try pc.as(Net.UdpConn);
                    const port = try udp_impl.boundPort();
                    const dest = test_utils.addr4(.{ 127, 0, 0, 1 }, port);

                    var d = Net.Dialer.init(a, .{});
                    var c = try d.dialContext(ctx_api.background(), .udp, dest);
                    defer c.deinit();

                    const msg = "hello dialContext udp";
                    _ = try c.write(msg);

                    var buf: [64]u8 = undefined;
                    const recv = try pc.readFrom(&buf);
                    try lib.testing.expectEqualStrings(msg, buf[0..recv.bytes_read]);

                    _ = try pc.writeTo("ack", @ptrCast(&recv.addr), recv.addr_len);
                    const ack_len = try c.read(buf[0..]);
                    try lib.testing.expectEqualStrings("ack", buf[0..ack_len]);
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
