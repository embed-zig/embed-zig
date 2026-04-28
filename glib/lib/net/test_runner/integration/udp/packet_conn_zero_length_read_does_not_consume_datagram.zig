const stdz = @import("stdz");
const testing_api = @import("testing");
const test_utils = @import("../tcp/test_utils.zig");

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
                    var pc = try net.listenPacket(.{
                        .allocator = a,
                        .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    });
                    defer pc.deinit();

                    const udp_impl = try pc.as(net.UdpConn);
                    const port = try udp_impl.boundPort();
                    const dest = test_utils.addr4(.{ 127, 0, 0, 1 }, port);

                    _ = try pc.writeTo("hello", dest);

                    const empty = [_]u8{};
                    const empty_read = try pc.readFrom(empty[0..]);
                    try std.testing.expectEqual(@as(usize, 0), empty_read.bytes_read);
                    try std.testing.expect(!empty_read.addr.isValid());

                    var buf: [16]u8 = undefined;
                    const recv = try pc.readFrom(&buf);
                    try std.testing.expectEqualStrings("hello", buf[0..recv.bytes_read]);
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
