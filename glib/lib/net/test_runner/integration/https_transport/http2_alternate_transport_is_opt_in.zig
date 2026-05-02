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

                    const FakeH2Transport = struct {
                        round_trip_calls: usize = 0,

                        pub fn roundTrip(self: *@This(), _: *const Http.Request) !Http.Response {
                            self.round_trip_calls += 1;
                            return error.TestUnexpectedResult;
                        }

                        pub fn closeIdleConnections(_: *@This()) void {}
                    };

                    var ln = try Net.tls.listen(testing.allocator, .{
                        .address = Utils.addr4(0),
                    }, Utils.tlsServerConfigWithAlpn(&.{"h2"}));
                    defer ln.deinit();

                    const listener_impl = try ln.as(Net.tls.Listener);
                    const port = try Utils.tlsListenerPort(ln, Net);
                    var server_result = ThreadResult{};
                    var fake = FakeH2Transport{};

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
                            if (!Utils.hasRequestLine(req_head, "GET /opt-in HTTP/1.1")) {
                                thread_err = error.TestUnexpectedResult;
                                return;
                            }

                            var head_buf: [256]u8 = undefined;
                            const body = "http1 fallback";
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

                    const alternates = [_]Http.Transport.AlternateProtocol{.{
                        .protocol = "h2",
                        .transport = Http.Transport.AlternateTransport.init(&fake),
                    }};
                    var transport = try Http.Transport.init(testing.allocator, .{
                        .tls_client_config = Utils.tlsTransportOptions().tls_client_config,
                        .alternate_protocols = &alternates,
                    });
                    defer transport.deinit();

                    const raw_url = try std.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/opt-in", .{port});
                    defer testing.allocator.free(raw_url);

                    var req = try Http.Request.init(testing.allocator, "GET", raw_url);
                    var resp = try transport.roundTrip(&req);
                    defer resp.deinit();

                    const body = try Utils.readBody(testing.allocator, resp);
                    defer testing.allocator.free(body);
                    try testing.expectEqualStrings("http1 fallback", body);
                    try testing.expectEqual(@as(usize, 0), fake.round_trip_calls);
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
