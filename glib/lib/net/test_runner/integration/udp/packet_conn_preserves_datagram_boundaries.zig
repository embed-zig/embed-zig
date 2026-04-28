const stdz = @import("stdz");
const testing_api = @import("testing");
const test_utils = @import("../tcp/test_utils.zig");

pub fn make(comptime std: type, comptime net: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            const Body = struct {
                fn call(a: std.mem.Allocator) !void {
                    var receiver = try net.listenPacket(.{
                        .allocator = a,
                        .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    });
                    defer receiver.deinit();

                    var sender = try net.listenPacket(.{
                        .allocator = a,
                        .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    });
                    defer sender.deinit();

                    const receiver_impl = try receiver.as(net.UdpConn);
                    const dest = test_utils.addr4(.{ 127, 0, 0, 1 }, try receiver_impl.boundPort());

                    _ = try sender.writeTo("ab", dest);
                    _ = try sender.writeTo("cde", dest);

                    var first_buf: [8]u8 = undefined;
                    const first = try receiver.readFrom(&first_buf);
                    try std.testing.expectEqual(@as(usize, 2), first.bytes_read);
                    try std.testing.expectEqualStrings("ab", first_buf[0..first.bytes_read]);

                    var second_buf: [8]u8 = undefined;
                    const second = try receiver.readFrom(&second_buf);
                    try std.testing.expectEqual(@as(usize, 3), second.bytes_read);
                    try std.testing.expectEqualStrings("cde", second_buf[0..second.bytes_read]);
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
