const stdz = @import("stdz");
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

                    const StaticBody = struct {
                        payload: []const u8,
                        offset: usize = 0,

                        pub fn read(self: *@This(), buf: []u8) anyerror!usize {
                            const remaining = self.payload[self.offset..];
                            if (remaining.len == 0) return 0;
                            const n = @min(buf.len, remaining.len);
                            @memcpy(buf[0..n], remaining[0..n]);
                            self.offset += n;
                            return n;
                        }

                        pub fn close(self: *@This()) void {
                            testing.allocator.destroy(self);
                        }
                    };

                    const FakeH2Transport = struct {
                        round_trip_calls: usize = 0,
                        close_idle_calls: usize = 0,

                        pub fn roundTrip(self: *@This(), req: *const Http.Request) !Http.Response {
                            self.round_trip_calls += 1;
                            try testing.expectEqualStrings("https", req.url.scheme);
                            const body = try testing.allocator.create(StaticBody);
                            body.* = .{ .payload = "h2 via hook" };
                            return .{
                                .status = "200 OK",
                                .status_code = 200,
                                .body_reader = Http.ReadCloser.init(body),
                                .content_length = "h2 via hook".len,
                            };
                        }

                        pub fn closeIdleConnections(self: *@This()) void {
                            self.close_idle_calls += 1;
                        }
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

                            var buf: [32]u8 = undefined;
                            _ = conn.read(&buf) catch {};
                        }
                    }.run, .{ listener_impl, &server_result });
                    defer server_thread.join();

                    const alternates = [_]Http.Transport.AlternateProtocol{.{
                        .protocol = "h2",
                        .transport = Http.Transport.AlternateTransport.init(&fake),
                    }};
                    var transport = try Http.Transport.init(testing.allocator, .{
                        .tls_client_config = Utils.tlsTransportOptions().tls_client_config,
                        .force_attempt_http2 = true,
                        .alternate_protocols = &alternates,
                    });
                    defer transport.deinit();

                    const raw_url = try std.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/hook-h2", .{port});
                    defer testing.allocator.free(raw_url);

                    var req = try Http.Request.init(testing.allocator, "GET", raw_url);
                    var resp = try transport.roundTrip(&req);
                    defer resp.deinit();

                    const body = try Utils.readBody(testing.allocator, resp);
                    defer testing.allocator.free(body);
                    try testing.expectEqualStrings("h2 via hook", body);
                    try testing.expectEqual(@as(usize, 1), fake.round_trip_calls);

                    transport.closeIdleConnections();
                    try testing.expectEqual(@as(usize, 1), fake.close_idle_calls);
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
