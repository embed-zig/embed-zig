const stdz = @import("stdz");
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
                    const loopback = try test_utils.addr6("::1", 0);

                    var pc = try Net.listenPacket(.{
                        .allocator = a,
                        .address = loopback,
                    });
                    defer pc.deinit();

                    const udp_impl = try pc.as(Net.UdpConn);
                    try lib.testing.expectError(error.AddressFamilyMismatch, udp_impl.boundPort());
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
