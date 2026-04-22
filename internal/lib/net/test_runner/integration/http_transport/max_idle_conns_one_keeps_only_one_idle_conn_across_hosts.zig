const embed = @import("embed");
const io = @import("io");
const testing_api = @import("testing");
const net_mod = @import("../../../../net.zig");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Utils = test_utils.make(lib);

    const Runner = struct {
        spawn_config: embed.Thread.SpawnConfig = .{ .stack_size = 1024 * 1024 },

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
                    const testing = struct {
                        pub var allocator: lib.mem.Allocator = undefined;
                        pub const expect = lib.testing.expect;
                        pub const expectEqual = lib.testing.expectEqual;
                        pub const expectEqualStrings = lib.testing.expectEqualStrings;
                        pub const expectError = lib.testing.expectError;
                    };
                    testing.allocator = a;

                    const TwoRequestSpec = struct {
                        first_request_line: []const u8,
                        second_request_line: []const u8,
                        first_body: []const u8,
                        second_body: []const u8,
                        reuse_wait_timeout_ms: u32 = 100,
                    };

                    const Helpers = struct {
                        fn serveKeepAliveRequest(conn: net_mod.Conn, expected_request_line: []const u8, body: []const u8, close_conn: bool) !bool {
                            var c = conn;
                            var req_buf: [4096]u8 = undefined;
                            const req_head = try Utils.readRequestHead(conn, &req_buf);
                            if (req_head.len == 0) return error.EndOfStream;
                            try testing.expect(Utils.hasRequestLine(req_head, expected_request_line));

                            var head_buf: [256]u8 = undefined;
                            const head = try lib.fmt.bufPrint(
                                &head_buf,
                                "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: {s}\r\n\r\n",
                                .{ body.len, if (close_conn) "close" else "keep-alive" },
                            );
                            try io.writeAll(@TypeOf(c), &c, head);
                            try io.writeAll(@TypeOf(c), &c, body);
                            return true;
                        }

                        fn serveTwoKeepAliveRequests(tcp_listener: *Net.TcpListener, spec: TwoRequestSpec, accept_count: *usize) !void {
                            var conn = try tcp_listener.accept();
                            accept_count.* += 1;
                            {
                                defer conn.deinit();

                                _ = try serveKeepAliveRequest(conn, spec.first_request_line, spec.first_body, false);

                                conn.setReadTimeout(spec.reuse_wait_timeout_ms);
                                const reused = serveKeepAliveRequest(conn, spec.second_request_line, spec.second_body, true) catch |err| switch (err) {
                                    error.TimedOut, error.EndOfStream => false,
                                    else => return err,
                                };
                                conn.setReadTimeout(null);
                                if (reused) return;
                            }

                            var second_conn = tcp_listener.accept() catch |err| switch (err) {
                                error.Closed => return,
                                else => return err,
                            };
                            accept_count.* += 1;
                            defer second_conn.deinit();
                            _ = try serveKeepAliveRequest(second_conn, spec.second_request_line, spec.second_body, true);
                        }
                    };

                    var ln1 = try Net.listen(testing.allocator, .{
                        .address = Utils.addr4(0),
                    });
                    defer ln1.deinit();
                    var ln2 = try Net.listen(testing.allocator, .{
                        .address = Utils.addr4(0),
                    });
                    defer ln2.deinit();

                    const listener1 = try ln1.as(Net.TcpListener);
                    const listener2 = try ln2.as(Net.TcpListener);
                    const port1 = try Utils.listenerPort(ln1, Net);
                    const port2 = try Utils.listenerPort(ln2, Net);

                    const spec1 = TwoRequestSpec{
                        .first_request_line = "GET /global-idle-1 HTTP/1.1",
                        .second_request_line = "GET /global-idle-3 HTTP/1.1",
                        .first_body = "one",
                        .second_body = "three",
                    };
                    const spec2 = TwoRequestSpec{
                        .first_request_line = "GET /global-idle-2 HTTP/1.1",
                        .second_request_line = "GET /global-idle-4 HTTP/1.1",
                        .first_body = "two",
                        .second_body = "four",
                    };

                    var accept_count1: usize = 0;
                    var accept_count2: usize = 0;
                    var server_result1: ?anyerror = null;
                    var server_result2: ?anyerror = null;

                    var server_thread1 = try lib.Thread.spawn(.{}, struct {
                        fn run(tcp_listener: *Net.TcpListener, spec: TwoRequestSpec, accepts: *usize, result: *?anyerror) void {
                            Helpers.serveTwoKeepAliveRequests(tcp_listener, spec, accepts) catch |err| {
                                result.* = err;
                            };
                        }
                    }.run, .{ listener1, spec1, &accept_count1, &server_result1 });
                    var joined1 = false;
                    defer {
                        if (!joined1) {
                            ln1.close();
                            server_thread1.join();
                        }
                    }

                    var server_thread2 = try lib.Thread.spawn(.{}, struct {
                        fn run(tcp_listener: *Net.TcpListener, spec: TwoRequestSpec, accepts: *usize, result: *?anyerror) void {
                            Helpers.serveTwoKeepAliveRequests(tcp_listener, spec, accepts) catch |err| {
                                result.* = err;
                            };
                        }
                    }.run, .{ listener2, spec2, &accept_count2, &server_result2 });
                    var joined2 = false;
                    defer {
                        if (!joined2) {
                            ln2.close();
                            server_thread2.join();
                        }
                    }

                    var transport = try Http.Transport.init(testing.allocator, .{
                        .max_idle_conns = 1,
                    });
                    defer transport.deinit();

                    const url1 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/global-idle-1", .{port1});
                    defer testing.allocator.free(url1);
                    const url2 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/global-idle-2", .{port2});
                    defer testing.allocator.free(url2);
                    const url3 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/global-idle-3", .{port1});
                    defer testing.allocator.free(url3);
                    const url4 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/global-idle-4", .{port2});
                    defer testing.allocator.free(url4);

                    var req1 = try Http.Request.init(testing.allocator, "GET", url1);
                    var resp1 = try transport.roundTrip(&req1);
                    defer resp1.deinit();
                    const body1 = try Utils.readBody(testing.allocator, resp1);
                    defer testing.allocator.free(body1);
                    try testing.expectEqualStrings("one", body1);

                    var req2 = try Http.Request.init(testing.allocator, "GET", url2);
                    var resp2 = try transport.roundTrip(&req2);
                    defer resp2.deinit();
                    const body2 = try Utils.readBody(testing.allocator, resp2);
                    defer testing.allocator.free(body2);
                    try testing.expectEqualStrings("two", body2);

                    var req3 = try Http.Request.init(testing.allocator, "GET", url3);
                    var resp3 = try transport.roundTrip(&req3);
                    defer resp3.deinit();
                    const body3 = try Utils.readBody(testing.allocator, resp3);
                    defer testing.allocator.free(body3);
                    try testing.expectEqualStrings("three", body3);

                    var req4 = try Http.Request.init(testing.allocator, "GET", url4);
                    var resp4 = try transport.roundTrip(&req4);
                    defer resp4.deinit();
                    const body4 = try Utils.readBody(testing.allocator, resp4);
                    defer testing.allocator.free(body4);
                    try testing.expectEqualStrings("four", body4);

                    ln1.close();
                    ln2.close();
                    server_thread1.join();
                    joined1 = true;
                    server_thread2.join();
                    joined2 = true;

                    if (server_result1) |err| return err;
                    if (server_result2) |err| return err;
                    try testing.expectEqual(@as(usize, 3), accept_count1 + accept_count2);
                            
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
