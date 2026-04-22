const embed = @import("embed");
const testing_api = @import("testing");
const net_mod = @import("../../../../net.zig");
const sockaddr_mod = @import("../../../fd/SockAddr.zig");
const test_utils = @import("../tcp/test_utils.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: embed.Thread.SpawnConfig = .{ .stack_size = 192 * 1024 },

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            const Body = struct {
                fn call(a: lib.mem.Allocator) !void {
                    const Net = net_mod.make(lib);
                    const SockAddr = sockaddr_mod.SockAddr(lib);

                    var pc = try Net.listenPacket(.{
                        .allocator = a,
                        .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    });
                    defer pc.deinit();

                    const udp_impl = try pc.as(Net.UdpConn);
                    const port = try udp_impl.boundPort();
                    const dest = test_utils.addr4(.{ 127, 0, 0, 1 }, port);
                    const dest_sockaddr = try SockAddr.encode(dest);

                    _ = try pc.writeTo("hello", @ptrCast(&dest_sockaddr.storage), dest_sockaddr.len);

                    const empty = [_]u8{};
                    const empty_read = try pc.readFrom(empty[0..]);
                    try lib.testing.expectEqual(@as(usize, 0), empty_read.bytes_read);
                    try lib.testing.expectEqual(@as(u32, 0), empty_read.addr_len);

                    var buf: [16]u8 = undefined;
                    const recv = try pc.readFrom(&buf);
                    try lib.testing.expectEqualStrings("hello", buf[0..recv.bytes_read]);
                }
            };
            Body.call(allocator) catch |err| {
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
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
