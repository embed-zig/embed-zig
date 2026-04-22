const stdz = @import("stdz");
const testing_api = @import("testing");
const net_mod = @import("../../../../net.zig");
const sockaddr_mod = @import("../../../fd/SockAddr.zig");
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
                    const SockAddr = sockaddr_mod.SockAddr(lib);

                    const loopback = try test_utils.addr6("::1", 0);

                    var pc = try Net.listenPacket(.{
                        .allocator = a,
                        .address = loopback,
                    });
                    defer pc.deinit();

                    const uc = try pc.as(Net.UdpConn);
                    const port = try uc.boundPort6();
                    const dest = loopback.withPort(port);
                    const dest_sockaddr = try SockAddr.encode(dest);
                    _ = try pc.writeTo("udp v6 listenPacket", @ptrCast(&dest_sockaddr.storage), dest_sockaddr.len);

                    var buf: [64]u8 = undefined;
                    const r = try pc.readFrom(&buf);
                    try lib.testing.expectEqualStrings("udp v6 listenPacket", buf[0..r.bytes_read]);
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
