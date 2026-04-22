const stdz = @import("stdz");
const io = @import("io");
const net_mod = @import("../../../../net.zig");
const testing_api = @import("testing");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Utils = test_utils.make(lib);

    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 3 * 1024 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
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

                    const ReuseState = struct {
                        reused: bool = false,
                        accepted: usize = 0,
                    };

                    const ProxyAuthState = struct {
                        accepted: usize = 0,
                        saw_auth: bool = false,
                    };

                    var target_state = ReuseState{};
                    var target_ln = try Net.tls.listen(testing.allocator, .{
                        .address = Utils.addr4(0),
                    }, Utils.tlsServerConfig());
                    defer target_ln.deinit();
                    const target_listener = try target_ln.as(Net.tls.Listener);
                    const target_port = try Utils.tlsListenerPort(target_ln, Net);
                    var target_result: ?anyerror = null;

                    var target_thread = try Thread.spawn(test_spawn_config, struct {
                        fn run(listener: *Net.tls.Listener, reuse_state: *ReuseState, result: *?anyerror) void {
                            var conn = listener.accept() catch |err| {
                                result.* = err;
                                return;
                            };
                            defer conn.deinit();
                            reuse_state.accepted += 1;

                            const typed = conn.as(Net.tls.ServerConn) catch {
                                result.* = error.TestUnexpectedResult;
                                return;
                            };
                            typed.handshake() catch |err| {
                                result.* = err;
                                return;
                            };

                            _ = Utils.serveKeepAliveRequest(conn, "GET /auth-first HTTP/1.1", "first via auth proxy", false) catch |err| {
                                result.* = err;
                                return;
                            };

                            conn.setReadTimeout(200);
                            const reused = Utils.serveKeepAliveRequest(conn, "GET /auth-second HTTP/1.1", "second via auth proxy", true) catch |err| switch (err) {
                                error.EndOfStream,
                                error.TimedOut,
                                error.Unexpected,
                                => false,
                                else => {
                                    result.* = err;
                                    return;
                                },
                            };
                            if (reused) reuse_state.reused = true;
                        }
                    }.run, .{ target_listener, &target_state, &target_result });
                    defer target_thread.join();

                    var proxy_ln = try Net.listen(testing.allocator, .{ .address = Utils.addr4(0) });
                    defer proxy_ln.deinit();
                    const proxy_listener = try proxy_ln.as(Net.TcpListener);
                    const proxy_port = try Utils.tcpListenerPort(proxy_ln, Net);
                    var proxy_state = ProxyAuthState{};
                    var proxy_result: ?anyerror = null;

                    var proxy_thread = try Thread.spawn(test_spawn_config, struct {
                        fn run(
                            listener: *Net.TcpListener,
                            target_port_value: u16,
                            state: *ProxyAuthState,
                            result: *?anyerror,
                        ) void {
                            var conn = listener.accept() catch |err| {
                                result.* = err;
                                return;
                            };
                            defer conn.deinit();
                            state.accepted += 1;

                            var req_buf: [4096]u8 = undefined;
                            const req_head = Utils.readRequestHead(conn, &req_buf) catch |err| {
                                result.* = err;
                                return;
                            };
                            var line_buf: [64]u8 = undefined;
                            const expected = lib.fmt.bufPrint(&line_buf, "CONNECT 127.0.0.1:{d} HTTP/1.1", .{target_port_value}) catch {
                                result.* = error.TestUnexpectedResult;
                                return;
                            };
                            if (!Utils.hasRequestLine(req_head, expected)) {
                                result.* = error.TestUnexpectedResult;
                                return;
                            }
                            state.saw_auth = lib.mem.eql(u8, Utils.headerValue(req_head, Http.Header.proxy_authorization) orelse "", "Basic dXNlcjpwYXNz");

                            var upstream = Net.dial(testing.allocator, .tcp, Utils.addr4(target_port_value)) catch |err| {
                                result.* = err;
                                return;
                            };
                            defer upstream.deinit();

                            io.writeAll(@TypeOf(conn), &conn, "HTTP/1.1 200 Connection established\r\nContent-Length: 0\r\n\r\n") catch |err| {
                                result.* = err;
                                return;
                            };
                            Utils.bridgeTunnel(conn, upstream) catch |err| {
                                result.* = err;
                            };
                        }
                    }.run, .{ proxy_listener, target_port, &proxy_state, &proxy_result });
                    defer proxy_thread.join();

                    const proxy_raw_url = try lib.fmt.allocPrint(testing.allocator, "http://user:pass@127.0.0.1:{d}", .{proxy_port});
                    defer testing.allocator.free(proxy_raw_url);
                    var options = Utils.tlsTransportOptions();
                    options.https_proxy = .{
                        .url = try net_mod.url.parse(proxy_raw_url),
                    };
                    var transport = try Http.Transport.init(testing.allocator, options);
                    defer transport.deinit();

                    const first_url = try lib.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/auth-first", .{target_port});
                    defer testing.allocator.free(first_url);
                    var req1 = try Http.Request.init(testing.allocator, "GET", first_url);
                    var resp1 = try transport.roundTrip(&req1);
                    const body1 = try Utils.readBody(testing.allocator, resp1);
                    defer testing.allocator.free(body1);
                    try testing.expectEqualStrings("first via auth proxy", body1);
                    resp1.deinit();

                    const second_url = try lib.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/auth-second", .{target_port});
                    defer testing.allocator.free(second_url);
                    var req2 = try Http.Request.init(testing.allocator, "GET", second_url);
                    var resp2 = try transport.roundTrip(&req2);
                    const body2 = try Utils.readBody(testing.allocator, resp2);
                    defer testing.allocator.free(body2);
                    try testing.expectEqualStrings("second via auth proxy", body2);
                    resp2.deinit();

                    try testing.expect(proxy_state.saw_auth);
                    try testing.expectEqual(@as(usize, 1), proxy_state.accepted);
                    try testing.expect(target_state.reused);
                    try testing.expectEqual(@as(usize, 1), target_state.accepted);
                    if (proxy_result) |err| return err;
                    if (target_result) |err| return err;
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
