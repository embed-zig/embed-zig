const stdz = @import("stdz");
const testing_api = @import("testing");
const test_utils = @import("../tcp/test_utils.zig");

pub fn make(comptime lib: type, comptime net: type) testing_api.TestRunner {
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
                    var pc = try net.listenPacket(.{
                        .allocator = a,
                        .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    });
                    defer pc.deinit();

                    const udp_impl = try pc.as(net.UdpConn);
                    const port = try udp_impl.boundPort();

                    var d = net.Dialer.init(a, .{});
                    var c = try d.dial(.udp, test_utils.addr4(.{ 127, 0, 0, 1 }, port));
                    defer c.deinit();

                    _ = try c.write("hello");

                    var recv_buf: [16]u8 = undefined;
                    const recv = try pc.readFrom(&recv_buf);
                    try lib.testing.expectEqualStrings("hello", recv_buf[0..recv.bytes_read]);

                    _ = try pc.writeTo("ack", recv.addr);

                    const empty = [_]u8{};
                    try lib.testing.expectEqual(@as(usize, 0), try c.read(empty[0..]));

                    var ack_buf: [8]u8 = undefined;
                    const ack_len = try c.read(&ack_buf);
                    try lib.testing.expectEqualStrings("ack", ack_buf[0..ack_len]);
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
