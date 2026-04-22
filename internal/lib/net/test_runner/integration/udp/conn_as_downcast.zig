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
                    const posix = lib.posix;
                    const SockAddr = sockaddr_mod.SockAddr(lib);
                    const TcpConnType = @import("../../../TcpConn.zig").TcpConn(lib);

                    const fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
                    errdefer posix.close(fd);
                    const bind_addr = test_utils.addr4(.{ 127, 0, 0, 1 }, 0);
                    const bind_sockaddr = try SockAddr.encode(bind_addr);
                    try posix.bind(fd, @ptrCast(&bind_sockaddr.storage), bind_sockaddr.len);

                    var c = try Net.UdpConn.init(a, fd);
                    defer c.deinit();

                    const udp_impl = try c.as(Net.UdpConn);
                    try lib.testing.expect(!udp_impl.closed);

                    try lib.testing.expectError(error.TypeMismatch, c.as(TcpConnType));
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
