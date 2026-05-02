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

                    const ProxyState = struct {
                        accepted: usize = 0,
                        saw_header: bool = false,
                    };
                    const ProxyResult = thread_sync.ThreadSnapshot(std, ProxyState);

                    var target_ln = try Net.tls.listen(testing.allocator, .{
                        .address = Utils.addr4(0),
                    }, Utils.tlsServerConfig());
                    defer target_ln.deinit();
                    const target_listener = try target_ln.as(Net.tls.Listener);
                    const target_port = try Utils.tlsListenerPort(target_ln, Net);
                    var target_result = ThreadResult{};

                    var target_thread = try Thread.spawn(test_spawn_config, struct {
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
                            if (!Utils.hasRequestLine(req_head, "GET /via-proxy HTTP/1.1")) {
                                thread_err = error.TestUnexpectedResult;
                                return;
                            }

                            var head_buf: [256]u8 = undefined;
                            const body = "secure via proxy";
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
                            var snapshot = ProxyState{};
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
                            snapshot.saw_header = std.mem.eql(u8, Utils.headerValue(req_head, "X-Connect-Test") orelse "", "proxy-test");

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

                    const proxy_raw_url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}", .{proxy_port});
                    defer testing.allocator.free(proxy_raw_url);
                    const connect_headers = [_]Http.Header{
                        Http.Header.init("X-Connect-Test", "proxy-test"),
                    };
                    var options = Utils.tlsTransportOptions();
                    options.https_proxy = .{
                        .url = try net.url.parse(proxy_raw_url),
                        .connect_headers = &connect_headers,
                    };
                    var transport = try Http.Transport.init(testing.allocator, options);
                    defer transport.deinit();

                    const raw_url = try std.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/via-proxy", .{target_port});
                    defer testing.allocator.free(raw_url);

                    var req = try Http.Request.init(testing.allocator, "GET", raw_url);
                    var resp = try transport.roundTrip(&req);
                    var resp_deinited = false;
                    defer if (!resp_deinited) resp.deinit();

                    const body = try Utils.readBody(testing.allocator, resp);
                    defer testing.allocator.free(body);
                    try testing.expectEqualStrings("secure via proxy", body);
                    resp.deinit();
                    resp_deinited = true;

                    const proxy_snapshot = try proxy_result.wait();
                    try testing.expectEqual(@as(usize, 1), proxy_snapshot.accepted);
                    try testing.expect(proxy_snapshot.saw_header);
                    if (target_result.wait()) |err| return err;
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
