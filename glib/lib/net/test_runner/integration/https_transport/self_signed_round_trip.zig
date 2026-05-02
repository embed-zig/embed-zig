const stdz = @import("stdz");
const io = @import("io");
const testing_api = @import("testing");
const test_utils = @import("test_utils.zig");
const thread_sync = @import("../../test_utils/thread_sync.zig");

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
                    const ThreadResult = thread_sync.ThreadResult(std);
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

                    var ln = try Net.tls.listen(testing.allocator, .{
                        .address = Utils.addr4(0),
                    }, Utils.tlsServerConfig());
                    defer ln.deinit();

                    const listener_impl = try ln.as(Net.tls.Listener);
                    const port = try Utils.tlsListenerPort(ln, Net);
                    var server_result = ThreadResult{};

                    var server_thread = try Thread.spawn(test_spawn_config, struct {
                        fn run(listener: *Net.tls.Listener, result: *ThreadResult) void {
                            var thread_err: ?anyerror = null;
                            defer result.finish(thread_err);

                            var conn = listener.accept() catch |err| {
                                thread_err = err;
                                return;
                            };
                            defer conn.deinit();

                            const typed = conn.as(Net.tls.ServerConn) catch {
                                thread_err = error.TestUnexpectedResult;
                                return;
                            };
                            typed.handshake() catch |err| {
                                thread_err = err;
                                return;
                            };

                            var req_buf: [4096]u8 = undefined;
                            const req_head = Utils.readRequestHead(conn, &req_buf) catch |err| {
                                thread_err = err;
                                return;
                            };
                            if (!Utils.hasRequestLine(req_head, "GET /hello HTTP/1.1")) {
                                thread_err = error.TestUnexpectedResult;
                                return;
                            }

                            var head_buf: [256]u8 = undefined;
                            const body = "secure pong";
                            const head = std.fmt.bufPrint(
                                &head_buf,
                                "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
                                .{body.len},
                            ) catch {
                                thread_err = error.TestUnexpectedResult;
                                return;
                            };
                            io.writeAll(@TypeOf(conn), &conn, head) catch |err| {
                                thread_err = err;
                                return;
                            };
                            io.writeAll(@TypeOf(conn), &conn, body) catch |err| {
                                thread_err = err;
                            };
                        }
                    }.run, .{ listener_impl, &server_result });
                    defer server_thread.join();

                    var transport = try Http.Transport.init(testing.allocator, Utils.tlsTransportOptions());
                    defer transport.deinit();

                    const raw_url = try std.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/hello", .{port});
                    defer testing.allocator.free(raw_url);

                    var req = try Http.Request.init(testing.allocator, "GET", raw_url);
                    var resp = try transport.roundTrip(&req);
                    defer resp.deinit();

                    try testing.expectEqual(@as(u16, 200), resp.status_code);
                    const tls_state = resp.tls orelse return error.TestUnexpectedResult;
                    try testing.expectEqual(@as(u16, @intFromEnum(Net.tls.ProtocolVersion.tls_1_3)), tls_state.version);
                    try testing.expect(tls_state.cipher_suite != 0);
                    try testing.expect(tls_state.peer_certificate_der != null);
                    try testing.expectEqualSlices(u8, Utils.fixtures.self_signed_cert_der[0..], tls_state.peer_certificate_der.?);
                    const body = try Utils.readBody(testing.allocator, resp);
                    defer testing.allocator.free(body);
                    try testing.expectEqualStrings("secure pong", body);

                    if (server_result.wait()) |err| return err;
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
