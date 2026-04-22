const embed = @import("embed");
const io = @import("io");
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
                    var server_result: ?anyerror = null;
                    var fake = FakeH2Transport{};

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

                            var req_buf: [4096]u8 = undefined;
                            const req_head = Utils.readRequestHead(conn, &req_buf) catch |err| {
                                result.* = err;
                                return;
                            };
                            if (!Utils.hasRequestLine(req_head, "GET /opt-in HTTP/1.1")) {
                                result.* = error.TestUnexpectedResult;
                                return;
                            }

                            var head_buf: [256]u8 = undefined;
                            const body = "http1 fallback";
                            const head = lib.fmt.bufPrint(
                                &head_buf,
                                "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
                                .{body.len},
                            ) catch {
                                result.* = error.TestUnexpectedResult;
                                return;
                            };
                            io.writeAll(@TypeOf(conn), &conn, head) catch |err| {
                                result.* = err;
                                return;
                            };
                            io.writeAll(@TypeOf(conn), &conn, body) catch |err| {
                                result.* = err;
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

                    const raw_url = try lib.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/opt-in", .{port});
                    defer testing.allocator.free(raw_url);

                    var req = try Http.Request.init(testing.allocator, "GET", raw_url);
                    var resp = try transport.roundTrip(&req);
                    defer resp.deinit();

                    const body = try Utils.readBody(testing.allocator, resp);
                    defer testing.allocator.free(body);
                    try testing.expectEqualStrings("http1 fallback", body);
                    try testing.expectEqual(@as(usize, 0), fake.round_trip_calls);
                    if (server_result) |err| return err;
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
