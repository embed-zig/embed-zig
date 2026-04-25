const stdz = @import("stdz");
const testing_api = @import("testing");
const tls_fixtures = @import("../../../../net/tls/test_fixtures.zig");
const tcp_test_utils = @import("../tcp/test_utils.zig");
const test_utils = @import("test_utils.zig");

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
                    const Thread = lib.Thread;
                    const test_spawn_config: Thread.SpawnConfig = .{ .stack_size = 1024 * 1024 };

                    var ln = try Net.tls.listen(a, .{
                        .address = tcp_test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    }, .{
                        .certificates = &.{.{
                            .chain = &.{tls_fixtures.self_signed_cert_der[0..]},
                            .private_key = .{ .ecdsa_p256_sha256 = tls_fixtures.self_signed_key_scalar },
                        }},
                    });
                    defer ln.deinit();

                    const tls_listener = try ln.as(Net.tls.Listener);
                    const tcp_impl = try tls_listener.inner.as(Net.TcpListener);
                    const port = try tcp_impl.port();

                    var server_result: ?anyerror = null;
                    var server_thread = try Thread.spawn(test_spawn_config, struct {
                        fn run(listener: *Net.tls.Listener, result: *?anyerror) void {
                            var conn = listener.accept() catch |err| {
                                result.* = err;
                                return;
                            };
                            defer conn.deinit();

                            const typed = conn.as(Net.tls.ServerConn) catch {
                                result.* = error.TestUnexpectedResult;
                                return;
                            };
                            typed.handshake() catch |err| {
                                result.* = err;
                                return;
                            };

                            var buf: [4]u8 = undefined;
                            test_utils.readAll(conn, &buf) catch |err| {
                                result.* = err;
                                return;
                            };
                            test_utils.writeAll(conn, "pong") catch |err| {
                                result.* = err;
                                return;
                            };
                            if (!lib.mem.eql(u8, &buf, "ping")) result.* = error.TestUnexpectedResult;
                        }
                    }.run, .{ tls_listener, &server_result });
                    defer server_thread.join();

                    var d = Net.Dialer.init(a, .{});
                    var client_conn = try d.dial(.tcp, tcp_test_utils.addr4(.{ 127, 0, 0, 1 }, port));
                    var client_conn_owned = true;
                    errdefer if (client_conn_owned) client_conn.deinit();

                    var tls_client = try Net.tls.client(a, client_conn, .{
                        .server_name = "example.com",
                        .verification = .self_signed,
                    });
                    client_conn_owned = false;
                    defer tls_client.deinit();

                    try test_utils.writeAll(tls_client, "ping");
                    var resp: [4]u8 = undefined;
                    try test_utils.readAll(tls_client, &resp);
                    try lib.testing.expectEqualStrings("pong", &resp);

                    if (server_result) |err| return err;
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
