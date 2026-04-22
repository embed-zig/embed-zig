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
                    const test_spawn_config: lib.Thread.SpawnConfig = .{};

                    const Mutex = lib.Thread.Mutex;
                    const Condition = lib.Thread.Condition;

                    const RoundTripTask = struct {
                        mutex: Mutex = .{},
                        cond: Condition = .{},
                        transport: *Http.Transport,
                        req: *Http.Request,
                        resp: ?Http.Response = null,
                        err: ?anyerror = null,
                        finished: bool = false,

                        fn run(self: *@This()) void {
                            defer {
                                self.mutex.lock();
                                self.finished = true;
                                self.cond.broadcast();
                                self.mutex.unlock();
                            }
                            self.resp = self.transport.roundTrip(self.req) catch |err| {
                                self.err = err;
                                return;
                            };
                        }

                        fn waitTimeout(self: *@This(), timeout_ms: u32) bool {
                            self.mutex.lock();
                            defer self.mutex.unlock();
                            if (self.finished) return true;
                            self.cond.timedWait(&self.mutex, @as(u64, timeout_ms) * lib.time.ns_per_ms) catch {};
                            return self.finished;
                        }
                    };
                    var ln = try Net.listen(testing.allocator, .{
                        .address = Utils.addr4(0),
                    });
                    defer ln.deinit();

                    const listener = try ln.as(Net.TcpListener);
                    const port = try Utils.listenerPort(ln, Net);
                    var accept_count: usize = 0;
                    var server_result: ?anyerror = null;

                    var server_thread = try lib.Thread.spawn(.{}, struct {
                        fn writePathResponse(conn: net_mod.Conn, req_head: []const u8) !void {
                            var c = conn;
                            const body = if (Utils.hasRequestLine(req_head, "GET /idle-per-host-1 HTTP/1.1"))
                                "one"
                            else if (Utils.hasRequestLine(req_head, "GET /idle-per-host-2 HTTP/1.1"))
                                "two"
                            else if (Utils.hasRequestLine(req_head, "GET /idle-per-host-3 HTTP/1.1"))
                                "three"
                            else if (Utils.hasRequestLine(req_head, "GET /idle-per-host-4 HTTP/1.1"))
                                "four"
                            else
                                return error.TestUnexpectedResult;

                            var head_buf: [256]u8 = undefined;
                            const head = try lib.fmt.bufPrint(
                                &head_buf,
                                "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n",
                                .{body.len},
                            );
                            try io.writeAll(@TypeOf(c), &c, head);
                            try io.writeAll(@TypeOf(c), &c, body);
                        }

                        fn serveConn(conn: net_mod.Conn, result: *?anyerror) void {
                            var owned = conn;
                            defer owned.deinit();

                            var req_buf: [4096]u8 = undefined;
                            while (true) {
                                owned.setReadTimeout(200);
                                const req_head = Utils.readRequestHead(owned, &req_buf) catch |err| switch (err) {
                                    error.TimedOut,
                                    error.EndOfStream,
                                    => return,
                                    else => {
                                        result.* = err;
                                        return;
                                    },
                                };
                                if (req_head.len == 0) return;
                                writePathResponse(owned, req_head) catch |err| {
                                    result.* = err;
                                    return;
                                };
                            }
                        }

                        fn run(tcp_listener: *Net.TcpListener, accepts: *usize, result: *?anyerror) void {
                            var handler_threads: [3]?lib.Thread = .{ null, null, null };
                            var handler_count: usize = 0;
                            defer {
                                var i: usize = 0;
                                while (i < handler_count) : (i += 1) {
                                    handler_threads[i].?.join();
                                }
                            }

                            while (true) {
                                var conn = tcp_listener.accept() catch |err| {
                                    result.* = err;
                                    return;
                                };
                                var req_buf: [4096]u8 = undefined;
                                const req_head = Utils.readRequestHead(conn, &req_buf) catch |err| {
                                    conn.deinit();
                                    result.* = err;
                                    return;
                                };
                                if (Utils.hasRequestLine(req_head, "PING")) {
                                    conn.deinit();
                                    return;
                                }
                                if (handler_count >= handler_threads.len) {
                                    conn.deinit();
                                    result.* = error.TestUnexpectedResult;
                                    return;
                                }

                                accepts.* += 1;
                                writePathResponse(conn, req_head) catch |err| {
                                    conn.deinit();
                                    result.* = err;
                                    return;
                                };
                                handler_threads[handler_count] = lib.Thread.spawn(.{}, struct {
                                    fn runConn(owned_conn: net_mod.Conn, run_result: *?anyerror) void {
                                        serveConn(owned_conn, run_result);
                                    }
                                }.runConn, .{ conn, result }) catch |err| {
                                    conn.deinit();
                                    result.* = err;
                                    return;
                                };
                                handler_count += 1;
                            }
                        }
                    }.run, .{ listener, &accept_count, &server_result });
                    var server_joined = false;
                    defer if (!server_joined) server_thread.join();

                    var transport = try Http.Transport.init(testing.allocator, .{
                        .max_idle_conns_per_host = 1,
                    });
                    defer transport.deinit();

                    const url1 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/idle-per-host-1", .{port});
                    defer testing.allocator.free(url1);
                    const url2 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/idle-per-host-2", .{port});
                    defer testing.allocator.free(url2);
                    const url3 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/idle-per-host-3", .{port});
                    defer testing.allocator.free(url3);
                    const url4 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/idle-per-host-4", .{port});
                    defer testing.allocator.free(url4);

                    var req1 = try Http.Request.init(testing.allocator, "GET", url1);
                    var resp1 = try transport.roundTrip(&req1);

                    var req2 = try Http.Request.init(testing.allocator, "GET", url2);
                    var task2 = RoundTripTask{
                        .transport = &transport,
                        .req = &req2,
                    };
                    var thread2 = try lib.Thread.spawn(test_spawn_config, RoundTripTask.run, .{&task2});
                    thread2.join();

                    if (task2.err) |err| return err;
                    var resp2 = task2.resp orelse return error.TestUnexpectedResult;

                    const body1 = try Utils.readBody(testing.allocator, resp1);
                    defer testing.allocator.free(body1);
                    try testing.expectEqualStrings("one", body1);
                    resp1.deinit();

                    const body2 = try Utils.readBody(testing.allocator, resp2);
                    defer testing.allocator.free(body2);
                    try testing.expectEqualStrings("two", body2);
                    resp2.deinit();

                    var req3 = try Http.Request.init(testing.allocator, "GET", url3);
                    var resp3 = try transport.roundTrip(&req3);

                    var req4 = try Http.Request.init(testing.allocator, "GET", url4);
                    var task4 = RoundTripTask{
                        .transport = &transport,
                        .req = &req4,
                    };
                    var thread4 = try lib.Thread.spawn(test_spawn_config, RoundTripTask.run, .{&task4});
                    thread4.join();

                    if (task4.err) |err| return err;
                    var resp4 = task4.resp orelse return error.TestUnexpectedResult;

                    const body4 = try Utils.readBody(testing.allocator, resp4);
                    defer testing.allocator.free(body4);
                    try testing.expectEqualStrings("four", body4);
                    resp4.deinit();

                    const body3 = try Utils.readBody(testing.allocator, resp3);
                    defer testing.allocator.free(body3);
                    try testing.expectEqualStrings("three", body3);
                    resp3.deinit();

                    var probe = try Net.dial(testing.allocator, .tcp, Utils.addr4(port));
                    try io.writeAll(@TypeOf(probe), &probe, "PING\r\n\r\n");
                    probe.deinit();

                    server_thread.join();
                    server_joined = true;
                    if (server_result) |err| return err;
                    try testing.expectEqual(@as(usize, 3), accept_count);
                            
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
