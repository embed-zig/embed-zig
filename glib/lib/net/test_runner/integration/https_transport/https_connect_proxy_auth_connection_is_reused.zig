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

                    const ReuseState = struct {
                        reused: bool = false,
                        accepted: usize = 0,
                    };

                    const ProxyAuthState = struct {
                        accepted: usize = 0,
                        saw_auth: bool = false,
                    };
                    const ReuseResult = thread_sync.ThreadSnapshot(std, ReuseState);
                    const ProxyResult = thread_sync.ThreadSnapshot(std, ProxyAuthState);

                    var target_result = ReuseResult{};
                    var target_ln = try Net.tls.listen(testing.allocator, .{
                        .address = Utils.addr4(0),
                    }, Utils.tlsServerConfig());
                    defer target_ln.deinit();
                    const target_listener = try target_ln.as(Net.tls.Listener);
                    const target_port = try Utils.tlsListenerPort(target_ln, Net);

                    var target_thread = try Thread.spawn(test_spawn_config, struct {
                        fn run(listener: *Net.tls.Listener, result: *ReuseResult) void {
                            var snapshot = ReuseState{};
                            var thread_err: ?anyerror = null;
                            defer result.finish(snapshot, thread_err);

                            var conn = listener.accept() catch |err| {
                                thread_err = err;
                                return;
                            };
                            defer conn.deinit();
                            snapshot.accepted += 1;

                            const typed = conn.as(Net.tls.ServerConn) catch {
                                thread_err = error.TestUnexpectedResult;
                                return;
                            };
                            typed.handshake() catch |err| {
                                thread_err = err;
                                return;
                            };

                            _ = Utils.serveKeepAliveRequest(conn, "GET /auth-first HTTP/1.1", "first via auth proxy", false) catch |err| {
                                thread_err = err;
                                return;
                            };

                            conn.setReadDeadline(net.time.instant.add(net.time.instant.now(), 200 * net.time.duration.MilliSecond));
                            const reused = Utils.serveKeepAliveRequest(conn, "GET /auth-second HTTP/1.1", "second via auth proxy", true) catch |err| switch (err) {
                                error.EndOfStream,
                                error.TimedOut,
                                error.Unexpected,
                                => false,
                                else => {
                                    thread_err = err;
                                    return;
                                },
                            };
                            if (reused) snapshot.reused = true;
                        }
                    }.run, .{ target_listener, &target_result });
                    defer target_thread.join();

                    var proxy_ln = try Net.listen(testing.allocator, .{ .address = Utils.addr4(0) });
                    defer proxy_ln.deinit();
                    const proxy_listener = try proxy_ln.as(Net.TcpListener);
                    const proxy_port = try Utils.tcpListenerPort(proxy_ln, Net);
                    var proxy_result = ProxyResult{};

                    var proxy_thread = try Thread.spawn(test_spawn_config, struct {
                        fn run(
                            listener: *Net.TcpListener,
                            target_port_value: u16,
                            result: *ProxyResult,
                        ) void {
                            var snapshot = ProxyAuthState{};
                            var thread_err: ?anyerror = null;
                            defer result.finish(snapshot, thread_err);

                            var conn = listener.accept() catch |err| {
                                thread_err = err;
                                return;
                            };
                            defer conn.deinit();
                            snapshot.accepted += 1;

                            var req_buf: [4096]u8 = undefined;
                            const req_head = Utils.readRequestHead(conn, &req_buf) catch |err| {
                                thread_err = err;
                                return;
                            };
                            var line_buf: [64]u8 = undefined;
                            const expected = std.fmt.bufPrint(&line_buf, "CONNECT 127.0.0.1:{d} HTTP/1.1", .{target_port_value}) catch {
                                thread_err = error.TestUnexpectedResult;
                                return;
                            };
                            if (!Utils.hasRequestLine(req_head, expected)) {
                                thread_err = error.TestUnexpectedResult;
                                return;
                            }
                            snapshot.saw_auth = std.mem.eql(u8, Utils.headerValue(req_head, Http.Header.proxy_authorization) orelse "", "Basic dXNlcjpwYXNz");

                            var upstream = Net.dial(testing.allocator, .tcp, Utils.addr4(target_port_value)) catch |err| {
                                thread_err = err;
                                return;
                            };
                            defer upstream.deinit();

                            io.writeAll(@TypeOf(conn), &conn, "HTTP/1.1 200 Connection established\r\nContent-Length: 0\r\n\r\n") catch |err| {
                                thread_err = err;
                                return;
                            };
                            Utils.bridgeTunnel(conn, upstream) catch |err| {
                                thread_err = err;
                            };
                        }
                    }.run, .{ proxy_listener, target_port, &proxy_result });
                    defer proxy_thread.join();

                    const proxy_raw_url = try std.fmt.allocPrint(testing.allocator, "http://user:pass@127.0.0.1:{d}", .{proxy_port});
                    defer testing.allocator.free(proxy_raw_url);
                    var options = Utils.tlsTransportOptions();
                    options.https_proxy = .{
                        .url = try net.url.parse(proxy_raw_url),
                    };
                    var transport = try Http.Transport.init(testing.allocator, options);
                    defer transport.deinit();

                    const first_url = try std.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/auth-first", .{target_port});
                    defer testing.allocator.free(first_url);
                    var req1 = try Http.Request.init(testing.allocator, "GET", first_url);
                    var resp1 = try transport.roundTrip(&req1);
                    const body1 = try Utils.readBody(testing.allocator, resp1);
                    defer testing.allocator.free(body1);
                    try testing.expectEqualStrings("first via auth proxy", body1);
                    resp1.deinit();

                    const second_url = try std.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/auth-second", .{target_port});
                    defer testing.allocator.free(second_url);
                    var req2 = try Http.Request.init(testing.allocator, "GET", second_url);
                    var resp2 = try transport.roundTrip(&req2);
                    const body2 = try Utils.readBody(testing.allocator, resp2);
                    defer testing.allocator.free(body2);
                    try testing.expectEqualStrings("second via auth proxy", body2);
                    resp2.deinit();

                    const proxy_snapshot = try proxy_result.wait();
                    const target_snapshot = try target_result.wait();
                    try testing.expect(proxy_snapshot.saw_auth);
                    try testing.expectEqual(@as(usize, 1), proxy_snapshot.accepted);
                    try testing.expect(target_snapshot.reused);
                    try testing.expectEqual(@as(usize, 1), target_snapshot.accepted);
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
