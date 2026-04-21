const embed = @import("embed");
const testing_api = @import("testing");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Utils = test_utils.make(lib);

    const Runner = struct {
        spawn_config: embed.Thread.SpawnConfig = .{ .stack_size = 3 * 1024 * 1024 },

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(runner: *@This(), t: *testing_api.T, run_allocator: lib.mem.Allocator) bool {
            _ = runner;
            const Body = struct {
                fn call(a: lib.mem.Allocator) !void {
                    const Net = Utils.Net;
                    const Http = Utils.Http;
                    const Thread = lib.Thread;
                    const test_spawn_config: lib.Thread.SpawnConfig = Utils.test_spawn_config;
                    const testing = struct {
                        pub var allocator: lib.mem.Allocator = undefined;
                        pub const expect = lib.testing.expect;
                        pub const expectEqual = lib.testing.expectEqual;
                        pub const expectEqualSlices = lib.testing.expectEqualSlices;
                        pub const expectEqualStrings = lib.testing.expectEqualStrings;
                        pub const expectError = lib.testing.expectError;
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
                            Thread.sleep(300 * lib.time.ns_per_ms);
                        }
                    }.run, .{listener_impl});
                    defer server_thread.join();

                    var transport = try Http.Transport.init(testing.allocator, .{
                        .tls_client_config = .{
                            .server_name = "example.com",
                            .verification = .no_verification,
                        },
                        .tls_handshake_timeout_ms = 100,
                    });
                    defer transport.deinit();

                    const raw_url = try lib.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/stall", .{port});
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
