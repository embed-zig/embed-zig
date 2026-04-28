const stdz = @import("stdz");
const testing_api = @import("testing");
const tls_fixtures = @import("../../../../net/tls/test_fixtures.zig");
const tcp_test_utils = @import("../tcp/test_utils.zig");
const test_utils = @import("test_utils.zig");

pub fn make(comptime std: type, comptime net: type) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 1024 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            const Body = struct {
                fn call(a: std.mem.Allocator) !void {
                    const Net = net;
                    const Thread = std.Thread;
                    const test_spawn_config: Thread.SpawnConfig = .{ .stack_size = 1024 * 1024 };

                    for ([_]Net.tls.CipherSuite{
                        .TLS_AES_128_GCM_SHA256,
                        .TLS_AES_256_GCM_SHA384,
                        .TLS_CHACHA20_POLY1305_SHA256,
                    }) |suite| {
                        var ln = try Net.TcpListener.init(a, .{
                            .address = tcp_test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                        });
                        defer ln.deinit();
                        try ln.listen();
                        const ln_impl = try ln.as(Net.TcpListener);
                        const port = try ln_impl.port();

                        var server_result: ?anyerror = null;
                        var server_thread = try Thread.spawn(test_spawn_config, struct {
                            fn run(listener: *Net.TcpListener, wanted_suite: Net.tls.CipherSuite, result: *?anyerror, alloc: std.mem.Allocator) void {
                                var conn = listener.accept() catch |err| {
                                    result.* = err;
                                    return;
                                };
                                errdefer conn.deinit();

                                var tls_conn = Net.tls.server(alloc, conn, .{
                                    .certificates = &.{.{
                                        .chain = &.{tls_fixtures.self_signed_cert_der[0..]},
                                        .private_key = .{ .ecdsa_p256_sha256 = tls_fixtures.self_signed_key_scalar },
                                    }},
                                    .min_version = .tls_1_3,
                                    .max_version = .tls_1_3,
                                    .tls13_cipher_suites = &.{wanted_suite},
                                }) catch |err| {
                                    result.* = err;
                                    return;
                                };
                                defer tls_conn.deinit();

                                const typed = tls_conn.as(Net.tls.ServerConn) catch unreachable;
                                typed.handshake() catch |err| {
                                    result.* = err;
                                    return;
                                };
                                if (typed.handshake_state.version != .tls_1_3 or typed.handshake_state.cipher_suite != wanted_suite) {
                                    result.* = error.TestUnexpectedResult;
                                    return;
                                }

                                var buf: [4]u8 = undefined;
                                test_utils.readAll(tls_conn, &buf) catch |err| {
                                    result.* = err;
                                    return;
                                };
                                test_utils.writeAll(tls_conn, "pong") catch |err| {
                                    result.* = err;
                                    return;
                                };
                                if (!std.mem.eql(u8, &buf, "ping")) result.* = error.TestUnexpectedResult;
                            }
                        }.run, .{ ln_impl, suite, &server_result, a });
                        defer server_thread.join();

                        var d = Net.Dialer.init(a, .{});
                        var client_conn = try d.dial(.tcp, tcp_test_utils.addr4(.{ 127, 0, 0, 1 }, port));
                        var client_conn_owned = true;
                        errdefer if (client_conn_owned) client_conn.deinit();

                        var tls_client = try Net.tls.client(a, client_conn, .{
                            .server_name = "example.com",
                            .verification = .self_signed,
                            .min_version = .tls_1_3,
                            .max_version = .tls_1_3,
                            .tls13_cipher_suites = &.{suite},
                        });
                        client_conn_owned = false;
                        defer tls_client.deinit();

                        const typed = try tls_client.as(Net.tls.Conn);
                        try typed.handshake();
                        try std.testing.expectEqual(Net.tls.ProtocolVersion.tls_1_3, typed.handshake_state.version);
                        try std.testing.expectEqual(suite, typed.handshake_state.cipher_suite);

                        try test_utils.sendClientKeyUpdate(Net, typed);
                        try test_utils.writeAll(tls_client, "ping");

                        var resp: [4]u8 = undefined;
                        try test_utils.readAll(tls_client, &resp);
                        try std.testing.expectEqualStrings("pong", &resp);

                        if (server_result) |err| return err;
                    }
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
