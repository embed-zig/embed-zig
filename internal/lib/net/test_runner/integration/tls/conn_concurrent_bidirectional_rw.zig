const stdz = @import("stdz");
const testing_api = @import("testing");
const tls_fixtures = @import("../../../../net/tls/test_fixtures.zig");
const net_mod = @import("../../../../net.zig");
const tcp_test_utils = @import("../tcp/test_utils.zig");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
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
                    const Net = net_mod.make(lib);
                    const Thread = lib.Thread;
                    const test_spawn_config: Thread.SpawnConfig = .{ .stack_size = 1024 * 1024 };
                    const StartGate = tcp_test_utils.StartGate(lib);

                    const ReadCtx = struct {
                        gate: *StartGate,
                        conn: net_mod.Conn,
                        expected: []const u8,
                        output: []u8,
                        result: *?anyerror,
                    };

                    const WriteCtx = struct {
                        gate: *StartGate,
                        conn: net_mod.Conn,
                        payload: []const u8,
                        result: *?anyerror,
                    };

                    const Worker = struct {
                        fn read(ctx: *ReadCtx) void {
                            ctx.gate.wait();
                            test_utils.readAll(ctx.conn, ctx.output) catch |err| {
                                ctx.result.* = err;
                                return;
                            };
                            if (!lib.mem.eql(u8, ctx.expected, ctx.output)) {
                                ctx.result.* = error.TestUnexpectedResult;
                            }
                        }

                        fn write(ctx: *WriteCtx) void {
                            ctx.gate.wait();
                            test_utils.writeAll(ctx.conn, ctx.payload) catch |err| {
                                ctx.result.* = err;
                            };
                        }
                    };

                    var ln = try Net.TcpListener.init(a, .{
                        .address = tcp_test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    });
                    defer ln.deinit();
                    try ln.listen();
                    const ln_impl = try ln.as(Net.TcpListener);
                    const port = try ln_impl.port();

                    var server_result: ?anyerror = null;
                    const server_thread = try Thread.spawn(test_spawn_config, struct {
                        fn run(listener: *Net.TcpListener, result: *?anyerror, alloc: lib.mem.Allocator) void {
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

                            tls_conn.setReadTimeout(10_000);
                            tls_conn.setWriteTimeout(10_000);

                            const inbound_len = Net.tls.MAX_PLAINTEXT_LEN * 3 + 257;
                            const outbound_len = Net.tls.MAX_PLAINTEXT_LEN * 2 + 113;

                            const expected_from_client = alloc.alloc(u8, inbound_len) catch |err| {
                                result.* = err;
                                return;
                            };
                            defer alloc.free(expected_from_client);
                            tcp_test_utils.fillPattern(expected_from_client, 17);

                            const outbound = alloc.alloc(u8, outbound_len) catch |err| {
                                result.* = err;
                                return;
                            };
                            defer alloc.free(outbound);
                            tcp_test_utils.fillPattern(outbound, 91);

                            const received = alloc.alloc(u8, inbound_len) catch |err| {
                                result.* = err;
                                return;
                            };
                            defer alloc.free(received);

                            var gate = StartGate.init(2);
                            var read_result: ?anyerror = null;
                            var write_result: ?anyerror = null;

                            var r_ctx = ReadCtx{
                                .gate = &gate,
                                .conn = tls_conn,
                                .expected = expected_from_client,
                                .output = received,
                                .result = &read_result,
                            };
                            var w_ctx = WriteCtx{
                                .gate = &gate,
                                .conn = tls_conn,
                                .payload = outbound,
                                .result = &write_result,
                            };

                            var reader_thread = Thread.spawn(test_spawn_config, Worker.read, .{&r_ctx}) catch |err| {
                                result.* = err;
                                return;
                            };
                            var writer_thread = Thread.spawn(test_spawn_config, Worker.write, .{&w_ctx}) catch |err| {
                                result.* = err;
                                return;
                            };
                            reader_thread.join();
                            writer_thread.join();

                            if (read_result) |err| {
                                result.* = err;
                                return;
                            }
                            if (write_result) |err| {
                                result.* = err;
                                return;
                            }
                        }
                    }.run, .{ ln_impl, &server_result, a });

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

                    const typed = try tls_client.as(Net.tls.Conn);
                    try typed.handshake();

                    tls_client.setReadTimeout(10_000);
                    tls_client.setWriteTimeout(10_000);

                    const outbound_len = Net.tls.MAX_PLAINTEXT_LEN * 3 + 257;
                    const inbound_len = Net.tls.MAX_PLAINTEXT_LEN * 2 + 113;

                    const outbound = try a.alloc(u8, outbound_len);
                    defer a.free(outbound);
                    tcp_test_utils.fillPattern(outbound, 17);

                    const expected_from_server = try a.alloc(u8, inbound_len);
                    defer a.free(expected_from_server);
                    tcp_test_utils.fillPattern(expected_from_server, 91);

                    const received = try a.alloc(u8, inbound_len);
                    defer a.free(received);

                    var gate = StartGate.init(2);
                    var read_result: ?anyerror = null;
                    var write_result: ?anyerror = null;

                    var r_ctx = ReadCtx{
                        .gate = &gate,
                        .conn = tls_client,
                        .expected = expected_from_server,
                        .output = received,
                        .result = &read_result,
                    };
                    var w_ctx = WriteCtx{
                        .gate = &gate,
                        .conn = tls_client,
                        .payload = outbound,
                        .result = &write_result,
                    };

                    var reader_thread = try Thread.spawn(test_spawn_config, Worker.read, .{&r_ctx});
                    var writer_thread = try Thread.spawn(test_spawn_config, Worker.write, .{&w_ctx});
                    reader_thread.join();
                    writer_thread.join();
                    server_thread.join();

                    if (read_result) |err| return err;
                    if (write_result) |err| return err;
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
