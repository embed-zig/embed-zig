const stdz = @import("stdz");
const testing_api = @import("testing");
const tls_fixtures = @import("../../../../net/tls/test_fixtures.zig");
const tcp_test_utils = @import("../tcp/test_utils.zig");
const test_utils = @import("test_utils.zig");
const thread_sync = @import("../../test_utils/thread_sync.zig");

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
                    const ThreadResult = thread_sync.ThreadResult(std);
                    const test_spawn_config: Thread.SpawnConfig = .{ .stack_size = 1024 * 1024 };

                    var ln = try Net.TcpListener.init(a, .{
                        .address = tcp_test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    });
                    defer ln.deinit();
                    try ln.listen();
                    const ln_impl = try ln.as(Net.TcpListener);
                    const port = try ln_impl.port();

                    var server_result = ThreadResult{};
                    var server_thread = try Thread.spawn(test_spawn_config, struct {
                        fn run(listener: *Net.TcpListener, result: *ThreadResult, alloc: std.mem.Allocator) void {
                            var thread_err: ?anyerror = null;
                            defer result.finish(thread_err);

                            var conn = listener.accept() catch |err| {
                                thread_err = err;
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
                            }) catch |err| {
                                thread_err = err;
                                return;
                            };
                            defer tls_conn.deinit();

                            var buf: [4]u8 = undefined;
                            test_utils.readAll(tls_conn, &buf) catch |err| {
                                thread_err = err;
                                return;
                            };
                            if (!std.mem.eql(u8, &buf, "ping")) {
                                thread_err = error.TestUnexpectedResult;
                                return;
                            }

                            var eof_buf: [1]u8 = undefined;
                            _ = tls_conn.read(&eof_buf) catch |err| {
                                if (err == error.EndOfStream) return;
                                thread_err = err;
                                return;
                            };
                            thread_err = error.TestUnexpectedResult;
                        }
                    }.run, .{ ln_impl, &server_result, a });
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
                    });
                    client_conn_owned = false;
                    defer tls_client.deinit();

                    try test_utils.writeAll(tls_client, "ping");
                    tls_client.close();

                    if (server_result.wait()) |err| return err;
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
