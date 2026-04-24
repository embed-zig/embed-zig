const stdz = @import("stdz");
const testing_api = @import("testing");
const tcp_test_utils = @import("../tcp/test_utils.zig");

pub fn make(comptime lib: type, comptime net: type) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 1024 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            const Body = struct {
                fn call(a: lib.mem.Allocator) !void {
                    const Net = net;
                    const net_dialer = Net.Dialer.init(a, .{});
                    const d = Net.tls.Dialer.init(net_dialer, .{
                        .server_name = "example.com",
                        .insecure_skip_verify = true,
                    });

                    try lib.testing.expectError(
                        error.UnsupportedNetwork,
                        d.dial(.udp, tcp_test_utils.addr4(.{ 127, 0, 0, 1 }, 1)),
                    );
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
