const stdz = @import("stdz");
const testing_api = @import("testing");
const test_utils = @import("test_utils.zig");

pub fn make(comptime std: type, comptime net: type) testing_api.TestRunner {
    const Utils = test_utils.make(std, net);

    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 3 * 1024 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(runner: *@This(), t: *testing_api.T, run_allocator: std.mem.Allocator) bool {
            _ = runner;
            const Body = struct {
                fn call(a: std.mem.Allocator) !void {
                    const Net = Utils.Net;
                    const Http = Utils.Http;
                    const Thread = std.Thread;
                    const test_spawn_config: std.Thread.SpawnConfig = Utils.test_spawn_config;
                    const testing = struct {
                        pub var allocator: std.mem.Allocator = undefined;
                        pub const expect = std.testing.expect;
                        pub const expectEqual = std.testing.expectEqual;
                        pub const expectEqualSlices = std.testing.expectEqualSlices;
                        pub const expectEqualStrings = std.testing.expectEqualStrings;
                        pub const expectError = std.testing.expectError;
                    };
                    testing.allocator = a;

                    var ln = try Net.listen(testing.allocator, .{
                        .address = Utils.addr4(0),
                    });
                    defer ln.deinit();

                    const listener_impl = try ln.as(Net.TcpListener);
                    const port = try listener_impl.port();
                    var server_thread = try Thread.spawn(test_spawn_config, struct {
                        fn run(listener: *Net.TcpListener) void {
                            var conn = listener.accept() catch return;
                            defer conn.deinit();
                            Thread.sleep(@intCast(300 * net.time.duration.MilliSecond));
                        }
                    }.run, .{listener_impl});
                    defer server_thread.join();

                    var transport = try Http.Transport.init(testing.allocator, .{
                        .tls_client_config = .{
                            .server_name = "example.com",
                            .verification = .no_verification,
                        },
                        .tls_handshake_timeout = 100 * net.time.duration.MilliSecond,
                    });
                    defer transport.deinit();

                    const raw_url = try std.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/stall", .{port});
                    defer testing.allocator.free(raw_url);

                    var req = try Http.Request.init(testing.allocator, "GET", raw_url);
                    try testing.expectError(error.TimedOut, transport.roundTrip(&req));
                }
            };
            Body.call(run_allocator) catch |err| {
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
