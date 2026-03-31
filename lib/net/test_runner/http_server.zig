//! HTTP server runner — integration coverage for `http.Server`.

const embed = @import("embed");
const io = @import("io");
const context_mod = @import("context");
const fixtures = @import("../tls/test_fixtures.zig");
const net_mod = @import("../../net.zig");
const testing_api = @import("testing");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: embed.Thread.SpawnConfig = .{ .stack_size = 1024 * 1024 },

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            runImpl(lib, t, allocator) catch |err| {
                t.logErrorf("http_server runner failed: {}", .{err});
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}

fn runImpl(comptime lib: type, t: *testing_api.T, alloc: lib.mem.Allocator) !void {
    _ = t;
    const Net = net_mod.make(lib);
    const Http = Net.http;
    const Thread = lib.Thread;
    const testing = struct {
        pub var allocator: lib.mem.Allocator = undefined;
        pub const expect = lib.testing.expect;
        pub const expectEqual = lib.testing.expectEqual;
        pub const expectEqualStrings = lib.testing.expectEqualStrings;
        pub const expectError = lib.testing.expectError;
    };
    testing.allocator = alloc;
    const test_spawn_config: Thread.SpawnConfig = .{ .stack_size = 64 * 1024 };

    const Runner = struct {
        fn addr4(port: u16) net_mod.netip.AddrPort {
            return net_mod.netip.AddrPort.from4(.{ 127, 0, 0, 1 }, port);
        }

        const ServerRun = struct {
            listener: net_mod.Listener,
            port: u16,
            server_err: ?anyerror = null,
            thread: Thread,

            fn stop(self: *@This(), server: anytype) !void {
                server.close();
                self.thread.join();
                defer self.listener.deinit();
                if (self.server_err) |err| {
                    if (err != error.ServerClosed) return err;
                }
            }
        };

        const Gate = struct {
            mutex: Thread.Mutex = .{},
            cond: Thread.Condition = .{},
            open: bool = false,

            fn signal(self: *@This()) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.open = true;
                self.cond.broadcast();
            }

            fn wait(self: *@This()) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                while (!self.open) self.cond.wait(&self.mutex);
            }
        };

        const ShutdownTask = struct {
            mutex: Thread.Mutex = .{},
            cond: Thread.Condition = .{},
            finished: bool = false,
            err: ?anyerror = null,
            server: *Http.Server,
            ctx: context_mod.Context,

            fn run(self: *@This()) void {
                self.err = self.server.shutdown(self.ctx);
                self.mutex.lock();
                self.finished = true;
                self.cond.broadcast();
                self.mutex.unlock();
            }

            fn waitFor(self: *@This(), timeout_ms: u32) bool {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.finished) return true;
                self.cond.timedWait(&self.mutex, @as(u64, timeout_ms) * lib.time.ns_per_ms) catch {};
                return self.finished;
            }
        };

        const WrappedListener = struct {
            inner: net_mod.Listener,

            pub fn listen(self: *@This()) net_mod.Listener.ListenError!void {
                try self.inner.listen();
            }

            pub fn accept(self: *@This()) net_mod.Listener.AcceptError!net_mod.Conn {
                return self.inner.accept();
            }

            pub fn close(self: *@This()) void {
                self.inner.close();
            }

            pub fn deinit(self: *@This()) void {
                self.inner.deinit();
            }
        };

        fn basicGet() !void {
            var server = try Http.Server.init(testing.allocator, .{});
            defer server.deinit();
            try server.handleFunc("/hello", struct {
                fn run(rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "5") catch return;
                    _ = rw.write("hello") catch {};
                }
            }.run);

            var srv_run = try startPlainServer(&server);
            defer srv_run.stop(&server) catch {};

            var transport = try Http.Transport.init(testing.allocator, .{});
            defer transport.deinit();
            const raw_url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/hello", .{srv_run.port});
            defer testing.allocator.free(raw_url);

            var req = try Http.Request.init(testing.allocator, "GET", raw_url);
            defer req.deinit();
            var resp = try transport.roundTrip(&req);
            defer resp.deinit();

            try testing.expectEqual(@as(u16, 200), resp.status_code);
            const body = try readBody(resp);
            defer testing.allocator.free(body);
            try testing.expectEqualStrings("hello", body);
        }

        fn headBodyless() !void {
            var server = try Http.Server.init(testing.allocator, .{});
            defer server.deinit();
            try server.handleFunc("/head", struct {
                fn run(rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "5") catch return;
                    _ = rw.write("hello") catch {};
                }
            }.run);

            var srv_run = try startPlainServer(&server);
            defer srv_run.stop(&server) catch {};

            var conn = try Net.dial(testing.allocator, .tcp, addr4(srv_run.port));
            defer conn.deinit();
            try io.writeAll(@TypeOf(conn), &conn, "HEAD /head HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n");
            const resp = try readRawResponse(conn);
            defer testing.allocator.free(resp.head);
            defer testing.allocator.free(resp.body);

            try testing.expectEqualStrings("HTTP/1.1 200 OK", firstLine(resp.head));
            try testing.expectEqual(@as(usize, 0), resp.body.len);
        }

        fn keepAliveSequentialRequests() !void {
            var server = try Http.Server.init(testing.allocator, .{});
            defer server.deinit();
            try server.handleFunc("/keep", struct {
                fn run(rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "2") catch return;
                    _ = rw.write("ok") catch {};
                }
            }.run);

            var srv_run = try startPlainServer(&server);
            defer srv_run.stop(&server) catch {};

            var conn = try Net.dial(testing.allocator, .tcp, addr4(srv_run.port));
            defer conn.deinit();

            try io.writeAll(@TypeOf(conn), &conn, "GET /keep HTTP/1.1\r\nHost: example.com\r\n\r\n");
            const first = try readRawResponse(conn);
            defer testing.allocator.free(first.head);
            defer testing.allocator.free(first.body);
            try testing.expectEqualStrings("ok", first.body);

            try io.writeAll(@TypeOf(conn), &conn, "GET /keep HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n");
            const second = try readRawResponse(conn);
            defer testing.allocator.free(second.head);
            defer testing.allocator.free(second.body);
            try testing.expectEqualStrings("ok", second.body);
        }

        fn unreadBodyForcesClose() !void {
            var server = try Http.Server.init(testing.allocator, .{});
            defer server.deinit();
            try server.handleFunc("/upload", struct {
                fn run(rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "2") catch return;
                    _ = rw.write("ok") catch {};
                }
            }.run);

            var srv_run = try startPlainServer(&server);
            defer srv_run.stop(&server) catch {};

            var conn = try Net.dial(testing.allocator, .tcp, addr4(srv_run.port));
            defer conn.deinit();

            try io.writeAll(@TypeOf(conn), &conn, "POST /upload HTTP/1.1\r\nHost: example.com\r\nContent-Length: 4\r\n\r\nABCD");
            const first = try readRawResponse(conn);
            defer testing.allocator.free(first.head);
            defer testing.allocator.free(first.body);
            try testing.expectEqualStrings("ok", first.body);

            try io.writeAll(@TypeOf(conn), &conn, "GET /upload HTTP/1.1\r\nHost: example.com\r\n\r\n");
            var buf: [16]u8 = undefined;
            const n = conn.read(&buf) catch |err| {
                try testing.expect(err == error.EndOfStream or err == error.ConnectionReset or err == error.BrokenPipe);
                return;
            };
            try testing.expectEqual(@as(usize, 0), n);
        }

        fn malformedRequestGetsBadRequest() !void {
            var server = try Http.Server.init(testing.allocator, .{});
            defer server.deinit();
            try server.handleFunc("/", struct {
                fn run(rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "1") catch return;
                    _ = rw.write("x") catch {};
                }
            }.run);

            var srv_run = try startPlainServer(&server);
            defer srv_run.stop(&server) catch {};

            var conn = try Net.dial(testing.allocator, .tcp, addr4(srv_run.port));
            defer conn.deinit();
            try io.writeAll(@TypeOf(conn), &conn, "BROKEN\r\n\r\n");
            const resp = try readRawResponse(conn);
            defer testing.allocator.free(resp.head);
            defer testing.allocator.free(resp.body);
            try testing.expect(lib.mem.startsWith(u8, firstLine(resp.head), "HTTP/1.1 400"));
        }

        fn conflictingLengthAndChunkedGetsBadRequest() !void {
            var server = try Http.Server.init(testing.allocator, .{});
            defer server.deinit();
            try server.handleFunc("/upload", struct {
                fn run(rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "2") catch return;
                    _ = rw.write("ok") catch {};
                }
            }.run);

            var srv_run = try startPlainServer(&server);
            defer srv_run.stop(&server) catch {};

            var conn = try Net.dial(testing.allocator, .tcp, addr4(srv_run.port));
            defer conn.deinit();
            try io.writeAll(
                @TypeOf(conn),
                &conn,
                "POST /upload HTTP/1.1\r\nHost: example.com\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n4\r\nABCD\r\n0\r\n\r\n",
            );
            const resp = try readRawResponse(conn);
            defer testing.allocator.free(resp.head);
            defer testing.allocator.free(resp.body);
            try testing.expect(lib.mem.startsWith(u8, firstLine(resp.head), "HTTP/1.1 400"));
        }

        fn chunkedRequestBodyRoundTrips() !void {
            var server = try Http.Server.init(testing.allocator, .{});
            defer server.deinit();
            try server.handleFunc("/chunked", struct {
                fn run(rw: *Http.ResponseWriter, req: *Http.Request) void {
                    const body = req.body() orelse {
                        rw.writeHeader(Http.status.bad_request) catch {};
                        return;
                    };
                    var reader = body;
                    var buf: [16]u8 = undefined;
                    var out = lib.ArrayList(u8){};
                    defer out.deinit(testing.allocator);
                    while (true) {
                        const n = reader.read(&buf) catch {
                            rw.writeHeader(Http.status.bad_request) catch {};
                            return;
                        };
                        if (n == 0) break;
                        out.appendSlice(testing.allocator, buf[0..n]) catch {
                            rw.writeHeader(Http.status.internal_server_error) catch {};
                            return;
                        };
                    }
                    rw.setHeader(Http.Header.content_length, "6") catch return;
                    _ = rw.write(out.items) catch {};
                }
            }.run);

            var srv_run = try startPlainServer(&server);
            defer srv_run.stop(&server) catch {};

            var conn = try Net.dial(testing.allocator, .tcp, addr4(srv_run.port));
            defer conn.deinit();
            try io.writeAll(
                @TypeOf(conn),
                &conn,
                "POST /chunked HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n3\r\nabc\r\n3\r\ndef\r\n0\r\n\r\n",
            );
            const resp = try readRawResponse(conn);
            defer testing.allocator.free(resp.head);
            defer testing.allocator.free(resp.body);
            try testing.expectEqualStrings("HTTP/1.1 200 OK", firstLine(resp.head));
            try testing.expectEqualStrings("abcdef", resp.body);
        }

        fn muxRoutesAndRedirects() !void {
            const ExactHandler = struct {
                pub fn serveHTTP(_: *@This(), rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "5") catch return;
                    _ = rw.write("exact") catch {};
                }
            };

            const ApiHandler = struct {
                pub fn serveHTTP(_: *@This(), rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "3") catch return;
                    _ = rw.write("api") catch {};
                }
            };

            const RootHandler = struct {
                pub fn serveHTTP(_: *@This(), rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "4") catch return;
                    _ = rw.write("root") catch {};
                }
            };

            const PairExactHandler = struct {
                pub fn serveHTTP(_: *@This(), rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "10") catch return;
                    _ = rw.write("pair-exact") catch {};
                }
            };

            const PairSubtreeHandler = struct {
                pub fn serveHTTP(_: *@This(), rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "12") catch return;
                    _ = rw.write("pair-subtree") catch {};
                }
            };

            const exercise = struct {
                fn run(comptime use_static: bool) !void {
                    var exact_handler = ExactHandler{};
                    var api_handler = ApiHandler{};

                    if (use_static) {
                        const StaticNoCatchAll = Http.StaticServeMux(.{
                            "/exact",
                            "/api/",
                        });
                        var mux = StaticNoCatchAll.init(.{ &exact_handler, &api_handler });
                        var server = try Http.Server.init(testing.allocator, .{ .handler = mux.handler() });
                        defer server.deinit();

                        var srv_run = try startPlainServer(&server);
                        defer srv_run.stop(&server) catch {};
                        try assertNoCatchAllMatrix(srv_run.port);
                    } else {
                        var server = try Http.Server.init(testing.allocator, .{});
                        defer server.deinit();
                        try server.handle("/exact", Http.Handler.init(&exact_handler));
                        try server.handle("/api/", Http.Handler.init(&api_handler));

                        var srv_run = try startPlainServer(&server);
                        defer srv_run.stop(&server) catch {};
                        try assertNoCatchAllMatrix(srv_run.port);
                    }

                    var pair_exact = PairExactHandler{};
                    var pair_subtree = PairSubtreeHandler{};

                    if (use_static) {
                        const StaticExactAndSubtree = Http.StaticServeMux(.{
                            "/pair",
                            "/pair/",
                        });
                        var mux = StaticExactAndSubtree.init(.{ &pair_exact, &pair_subtree });
                        var server = try Http.Server.init(testing.allocator, .{ .handler = mux.handler() });
                        defer server.deinit();

                        var srv_run = try startPlainServer(&server);
                        defer srv_run.stop(&server) catch {};
                        try assertExactAndSubtreeMatrix(srv_run.port);
                    } else {
                        var server = try Http.Server.init(testing.allocator, .{});
                        defer server.deinit();
                        try server.handle("/pair", Http.Handler.init(&pair_exact));
                        try server.handle("/pair/", Http.Handler.init(&pair_subtree));

                        var srv_run = try startPlainServer(&server);
                        defer srv_run.stop(&server) catch {};
                        try assertExactAndSubtreeMatrix(srv_run.port);
                    }

                    var root_handler = RootHandler{};
                    var api_handler2 = ApiHandler{};

                    if (use_static) {
                        const StaticWithCatchAll = Http.StaticServeMux(.{
                            "/",
                            "/api/",
                        });
                        var mux = StaticWithCatchAll.init(.{ &root_handler, &api_handler2 });
                        var server = try Http.Server.init(testing.allocator, .{ .handler = mux.handler() });
                        defer server.deinit();

                        var srv_run = try startPlainServer(&server);
                        defer srv_run.stop(&server) catch {};
                        try assertCatchAllMatrix(srv_run.port);
                    } else {
                        var server = try Http.Server.init(testing.allocator, .{});
                        defer server.deinit();
                        try server.handle("/", Http.Handler.init(&root_handler));
                        try server.handle("/api/", Http.Handler.init(&api_handler2));

                        var srv_run = try startPlainServer(&server);
                        defer srv_run.stop(&server) catch {};
                        try assertCatchAllMatrix(srv_run.port);
                    }
                }

                fn assertNoCatchAllMatrix(port: u16) !void {
                    const exact = try requestRawGet(port, "/exact");
                    defer testing.allocator.free(exact.head);
                    defer testing.allocator.free(exact.body);
                    try testing.expectEqualStrings("HTTP/1.1 200 OK", firstLine(exact.head));
                    try testing.expectEqualStrings("exact", exact.body);

                    const api = try requestRawGet(port, "/api/users");
                    defer testing.allocator.free(api.head);
                    defer testing.allocator.free(api.body);
                    try testing.expectEqualStrings("HTTP/1.1 200 OK", firstLine(api.head));
                    try testing.expectEqualStrings("api", api.body);

                    const slash = try requestRawGet(port, "/api");
                    defer testing.allocator.free(slash.head);
                    defer testing.allocator.free(slash.body);
                    try testing.expect(lib.mem.startsWith(u8, firstLine(slash.head), "HTTP/1.1 301"));
                    try testing.expectEqualStrings("/api/", headerValue(slash.head, Http.Header.location) orelse "");

                    const cleaned = try requestRawGet(port, "/api/../api/users");
                    defer testing.allocator.free(cleaned.head);
                    defer testing.allocator.free(cleaned.body);
                    try testing.expect(lib.mem.startsWith(u8, firstLine(cleaned.head), "HTTP/1.1 301"));
                    try testing.expectEqualStrings("/api/users", headerValue(cleaned.head, Http.Header.location) orelse "");

                    const missing = try requestRawGet(port, "/missing");
                    defer testing.allocator.free(missing.head);
                    defer testing.allocator.free(missing.body);
                    try testing.expect(lib.mem.startsWith(u8, firstLine(missing.head), "HTTP/1.1 404"));
                }

                fn assertCatchAllMatrix(port: u16) !void {
                    const api = try requestRawGet(port, "/api/users");
                    defer testing.allocator.free(api.head);
                    defer testing.allocator.free(api.body);
                    try testing.expectEqualStrings("HTTP/1.1 200 OK", firstLine(api.head));
                    try testing.expectEqualStrings("api", api.body);

                    const root = try requestRawGet(port, "/other");
                    defer testing.allocator.free(root.head);
                    defer testing.allocator.free(root.body);
                    try testing.expectEqualStrings("HTTP/1.1 200 OK", firstLine(root.head));
                    try testing.expectEqualStrings("root", root.body);
                }

                fn assertExactAndSubtreeMatrix(port: u16) !void {
                    const redirect = try requestRawGet(port, "/pair");
                    defer testing.allocator.free(redirect.head);
                    defer testing.allocator.free(redirect.body);
                    try testing.expect(lib.mem.startsWith(u8, firstLine(redirect.head), "HTTP/1.1 301"));
                    try testing.expectEqualStrings("/pair/", headerValue(redirect.head, Http.Header.location) orelse "");

                    const subtree = try requestRawGet(port, "/pair/");
                    defer testing.allocator.free(subtree.head);
                    defer testing.allocator.free(subtree.body);
                    try testing.expectEqualStrings("HTTP/1.1 200 OK", firstLine(subtree.head));
                    try testing.expectEqualStrings("pair-subtree", subtree.body);

                    const deep_subtree = try requestRawGet(port, "/pair/users");
                    defer testing.allocator.free(deep_subtree.head);
                    defer testing.allocator.free(deep_subtree.body);
                    try testing.expectEqualStrings("HTTP/1.1 200 OK", firstLine(deep_subtree.head));
                    try testing.expectEqualStrings("pair-subtree", deep_subtree.body);
                }
            };

            try exercise.run(false);
            try exercise.run(true);
        }

        fn readHeaderTimeoutClosesSlowHeader() !void {
            var server = try Http.Server.init(testing.allocator, .{
                .read_header_timeout_ms = 20,
            });
            defer server.deinit();
            try server.handleFunc("/slow", struct {
                fn run(rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "2") catch return;
                    _ = rw.write("ok") catch {};
                }
            }.run);

            var srv_run = try startPlainServer(&server);
            defer srv_run.stop(&server) catch {};

            var conn = try Net.dial(testing.allocator, .tcp, addr4(srv_run.port));
            defer conn.deinit();
            try io.writeAll(@TypeOf(conn), &conn, "GET /slow HTTP/1.1\r\n");
            Thread.sleep(40 * lib.time.ns_per_ms);
            try io.writeAll(@TypeOf(conn), &conn, "Host: example.com\r\nConnection: close\r\n\r\n");

            var buf: [64]u8 = undefined;
            const n = conn.read(&buf) catch |err| {
                try testing.expect(err == error.EndOfStream or err == error.ConnectionReset or err == error.BrokenPipe or err == error.TimedOut);
                return;
            };
            if (n != 0) {
                try testing.expect(lib.mem.startsWith(u8, buf[0..n], "HTTP/1.1 400"));
            }
        }

        fn idleTimeoutClosesKeepAliveConn() !void {
            var server = try Http.Server.init(testing.allocator, .{
                .idle_timeout_ms = 20,
            });
            defer server.deinit();
            try server.handleFunc("/idle-timeout", struct {
                fn run(rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "2") catch return;
                    _ = rw.write("ok") catch {};
                }
            }.run);

            var srv_run = try startPlainServer(&server);
            defer srv_run.stop(&server) catch {};

            var conn = try Net.dial(testing.allocator, .tcp, addr4(srv_run.port));
            defer conn.deinit();
            try io.writeAll(@TypeOf(conn), &conn, "GET /idle-timeout HTTP/1.1\r\nHost: example.com\r\n\r\n");
            const first = try readRawResponse(conn);
            defer testing.allocator.free(first.head);
            defer testing.allocator.free(first.body);
            try testing.expectEqualStrings("ok", first.body);

            Thread.sleep(40 * lib.time.ns_per_ms);
            try io.writeAll(@TypeOf(conn), &conn, "GET /idle-timeout HTTP/1.1\r\nHost: example.com\r\n\r\n");
            var buf: [64]u8 = undefined;
            const n = conn.read(&buf) catch |err| {
                try testing.expect(err == error.EndOfStream or err == error.ConnectionReset or err == error.BrokenPipe or err == error.TimedOut);
                return;
            };
            try testing.expectEqual(@as(usize, 0), n);
        }

        fn shutdownWaitsForActiveHandler() !void {
            var server = try Http.Server.init(testing.allocator, .{});
            defer server.deinit();

            var entered = Gate{};
            var release = Gate{};
            const SlowHandler = struct {
                entered: *Gate,
                release: *Gate,
                pub fn serveHTTP(self: *@This(), rw: *Http.ResponseWriter, _: *Http.Request) void {
                    self.entered.signal();
                    self.release.wait();
                    rw.setHeader(Http.Header.content_length, "4") catch return;
                    _ = rw.write("done") catch {};
                }
            };
            var slow_handler = SlowHandler{ .entered = &entered, .release = &release };
            try server.handle("/slow", Http.Handler.init(&slow_handler));

            var srv_run = try startPlainServer(&server);
            defer srv_run.stop(&server) catch {};

            var transport = try Http.Transport.init(testing.allocator, .{});
            defer transport.deinit();
            const raw_url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/slow", .{srv_run.port});
            defer testing.allocator.free(raw_url);
            var req = try Http.Request.init(testing.allocator, "GET", raw_url);
            defer req.deinit();

            const RoundTripTask = struct {
                transport: *Http.Transport,
                req: *Http.Request,
                resp: ?Http.Response = null,
                err: ?anyerror = null,

                fn exec(self: *@This()) void {
                    self.resp = self.transport.roundTrip(self.req) catch |err| {
                        self.err = err;
                        return;
                    };
                }
            };

            var round_trip = RoundTripTask{ .transport = &transport, .req = &req };
            var request_thread = try Thread.spawn(test_spawn_config, RoundTripTask.exec, .{&round_trip});
            entered.wait();

            const ContextNs = context_mod.make(lib);
            var ctx_ns = try ContextNs.init(testing.allocator);
            defer ctx_ns.deinit();
            var shutdown_ctx = try ctx_ns.withTimeout(ctx_ns.background(), 200 * lib.time.ns_per_ms);
            defer shutdown_ctx.deinit();

            var shutdown_task = ShutdownTask{ .server = &server, .ctx = shutdown_ctx };
            var shutdown_thread = try Thread.spawn(test_spawn_config, ShutdownTask.run, .{&shutdown_task});
            defer shutdown_thread.join();

            try testing.expect(!shutdown_task.waitFor(20));
            release.signal();
            try testing.expect(shutdown_task.waitFor(200));
            try testing.expect(shutdown_task.err == null);
            request_thread.join();
            if (round_trip.err) |err| return err;
            var resp = round_trip.resp orelse return error.TestUnexpectedResult;
            defer resp.deinit();
            const body = try readBody(resp);
            defer testing.allocator.free(body);
            try testing.expectEqualStrings("done", body);
        }

        fn closeInterruptsIdleKeepAlive() !void {
            var server = try Http.Server.init(testing.allocator, .{});
            defer server.deinit();
            try server.handleFunc("/idle", struct {
                fn run(rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "2") catch return;
                    _ = rw.write("ok") catch {};
                }
            }.run);

            var srv_run = try startPlainServer(&server);
            defer srv_run.stop(&server) catch {};

            var conn = try Net.dial(testing.allocator, .tcp, addr4(srv_run.port));
            defer conn.deinit();
            try io.writeAll(@TypeOf(conn), &conn, "GET /idle HTTP/1.1\r\nHost: example.com\r\n\r\n");
            const first = try readRawResponse(conn);
            defer testing.allocator.free(first.head);
            defer testing.allocator.free(first.body);

            server.close();
            var buf: [16]u8 = undefined;
            const n = conn.read(&buf) catch |err| {
                try testing.expect(err == error.EndOfStream or err == error.ConnectionReset or err == error.BrokenPipe);
                return;
            };
            try testing.expectEqual(@as(usize, 0), n);
        }

        fn tlsWrappedListenerServesRequest() !void {
            var server = try Http.Server.init(testing.allocator, .{});
            defer server.deinit();
            try server.handleFunc("/secure", struct {
                fn run(rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "6") catch return;
                    _ = rw.write("secure") catch {};
                }
            }.run);

            var srv_run = try startTlsServer(&server);
            defer srv_run.stop(&server) catch {};

            var transport = try Http.Transport.init(testing.allocator, tlsTransportOptions());
            defer transport.deinit();
            const raw_url = try lib.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/secure", .{srv_run.port});
            defer testing.allocator.free(raw_url);

            var req = try Http.Request.init(testing.allocator, "GET", raw_url);
            defer req.deinit();
            var resp = try transport.roundTrip(&req);
            defer resp.deinit();
            const body = try readBody(resp);
            defer testing.allocator.free(body);
            try testing.expectEqualStrings("secure", body);
        }

        fn wrappedListenerServesRequest() !void {
            var server = try Http.Server.init(testing.allocator, .{});
            defer server.deinit();
            try server.handleFunc("/wrapped", struct {
                fn run(rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "7") catch return;
                    _ = rw.write("wrapped") catch {};
                }
            }.run);

            const inner = try Net.listen(testing.allocator, .{ .address = addr4(0) });
            var wrapped = WrappedListener{ .inner = inner };
            const listener = net_mod.Listener.init(&wrapped);
            const port = try listenerPort(inner, Net);
            var server_err: ?anyerror = null;
            var thread = try Thread.spawn(test_spawn_config, struct {
                fn exec(s: *Http.Server, ln: net_mod.Listener, err: *?anyerror) void {
                    s.serve(ln) catch |serve_err| {
                        err.* = serve_err;
                    };
                }
            }.exec, .{ &server, listener, &server_err });
            defer {
                server.close();
                thread.join();
                listener.deinit();
                if (server_err) |err| {
                    if (err != error.ServerClosed) @panic("wrapped listener server failed");
                }
            }

            var conn = try Net.dial(testing.allocator, .tcp, addr4(port));
            defer conn.deinit();
            try io.writeAll(@TypeOf(conn), &conn, "GET /wrapped HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n");
            const resp = try readRawResponse(conn);
            defer testing.allocator.free(resp.head);
            defer testing.allocator.free(resp.body);
            try testing.expectEqualStrings("wrapped", resp.body);
        }

        fn startPlainServer(server: *Http.Server) !ServerRun {
            const listener = try Net.listen(testing.allocator, .{ .address = addr4(0) });
            const port = try listenerPort(listener, Net);
            var run = ServerRun{
                .listener = listener,
                .port = port,
                .thread = undefined,
            };
            run.thread = try Thread.spawn(test_spawn_config, struct {
                fn exec(s: *Http.Server, ln: net_mod.Listener, err: *?anyerror) void {
                    s.serve(ln) catch |serve_err| {
                        err.* = serve_err;
                    };
                }
            }.exec, .{ server, listener, &run.server_err });
            return run;
        }

        fn startTlsServer(server: *Http.Server) !ServerRun {
            const listener = try Net.tls.listen(testing.allocator, .{ .address = addr4(0) }, tlsServerConfig());
            const port = try tlsListenerPort(listener, Net);
            var run = ServerRun{
                .listener = listener,
                .port = port,
                .thread = undefined,
            };
            run.thread = try Thread.spawn(test_spawn_config, struct {
                fn exec(s: *Http.Server, ln: net_mod.Listener, err: *?anyerror) void {
                    s.serve(ln) catch |serve_err| {
                        err.* = serve_err;
                    };
                }
            }.exec, .{ server, listener, &run.server_err });
            return run;
        }

        fn requestRawGet(port: u16, target: []const u8) !RawResponse {
            var conn = try Net.dial(testing.allocator, .tcp, addr4(port));
            defer conn.deinit();
            const raw = try lib.fmt.allocPrint(
                testing.allocator,
                "GET {s} HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n",
                .{target},
            );
            defer testing.allocator.free(raw);
            try io.writeAll(@TypeOf(conn), &conn, raw);
            return readRawResponse(conn);
        }

        const RawResponse = struct {
            head: []u8,
            body: []u8,
        };

        fn readRawResponse(conn: net_mod.Conn) !RawResponse {
            var c = conn;
            var bytes = try lib.ArrayList(u8).initCapacity(testing.allocator, 0);
            errdefer bytes.deinit(testing.allocator);
            var buf: [256]u8 = undefined;

            var head_end: ?usize = null;
            while (head_end == null) {
                const n = try c.read(&buf);
                if (n == 0) return error.EndOfStream;
                try bytes.appendSlice(testing.allocator, buf[0..n]);
                if (lib.mem.indexOf(u8, bytes.items, "\r\n\r\n")) |end| head_end = end;
            }

            const split = head_end.? + 4;
            const head = try testing.allocator.dupe(u8, bytes.items[0..split]);
            errdefer testing.allocator.free(head);
            const prefix = bytes.items[split..];

            if (headerValue(head, Http.Header.content_length)) |value| {
                const content_length = try lib.fmt.parseInt(usize, value, 10);
                const body = try readFixedBody(c, prefix, content_length);
                return .{ .head = head, .body = body };
            }
            if (headerValue(head, Http.Header.transfer_encoding)) |value| {
                if (lib.ascii.eqlIgnoreCase(value, "chunked")) {
                    const body = try readChunkedBody(c, prefix);
                    return .{ .head = head, .body = body };
                }
            }
            return .{
                .head = head,
                .body = try testing.allocator.dupe(u8, prefix),
            };
        }

        fn readFixedBody(conn: net_mod.Conn, prefix: []const u8, total_len: usize) ![]u8 {
            var bytes = try lib.ArrayList(u8).initCapacity(testing.allocator, total_len);
            errdefer bytes.deinit(testing.allocator);
            try bytes.appendSlice(testing.allocator, prefix[0..@min(prefix.len, total_len)]);
            var c = conn;
            var buf: [256]u8 = undefined;
            while (bytes.items.len < total_len) {
                const want = @min(buf.len, total_len - bytes.items.len);
                const n = try c.read(buf[0..want]);
                if (n == 0) return error.EndOfStream;
                try bytes.appendSlice(testing.allocator, buf[0..n]);
            }
            return bytes.toOwnedSlice(testing.allocator);
        }

        fn readChunkedBody(conn: net_mod.Conn, prefix: []const u8) ![]u8 {
            var stream = io.PrefixReader(net_mod.Conn).init(conn, prefix);
            var body = lib.ArrayList(u8){};
            defer body.deinit(testing.allocator);
            var line_buf: [128]u8 = undefined;
            while (true) {
                const line = try stream.readLine(&line_buf);
                const semi = lib.mem.indexOfScalar(u8, line, ';') orelse line.len;
                const size = try lib.fmt.parseInt(usize, lib.mem.trim(u8, line[0..semi], " "), 16);
                if (size == 0) {
                    try stream.expectCrlf();
                    break;
                }
                const chunk = try testing.allocator.alloc(u8, size);
                defer testing.allocator.free(chunk);
                try io.readFull(@TypeOf(stream), &stream, chunk);
                try body.appendSlice(testing.allocator, chunk);
                try stream.expectCrlf();
            }
            return body.toOwnedSlice(testing.allocator);
        }

        fn firstLine(head: []const u8) []const u8 {
            const end = lib.mem.indexOf(u8, head, "\r\n") orelse head.len;
            return head[0..end];
        }

        fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
            var line_start: usize = 0;
            while (line_start < head.len) {
                const rel_end = lib.mem.indexOf(u8, head[line_start..], "\r\n") orelse head.len - line_start;
                const line = head[line_start .. line_start + rel_end];
                const colon = lib.mem.indexOfScalar(u8, line, ':') orelse {
                    if (line_start + rel_end == head.len) break;
                    line_start += rel_end + 2;
                    continue;
                };
                const header_name = lib.mem.trim(u8, line[0..colon], " ");
                if (Http.Header.init(header_name, "").is(name)) {
                    return lib.mem.trim(u8, line[colon + 1 ..], " ");
                }
                if (line_start + rel_end == head.len) break;
                line_start += rel_end + 2;
            }
            return null;
        }

        fn readBody(resp: Http.Response) ![]u8 {
            const body = resp.body() orelse return testing.allocator.dupe(u8, "");
            var reader = body;
            var bytes = try lib.ArrayList(u8).initCapacity(testing.allocator, 0);
            errdefer bytes.deinit(testing.allocator);
            var buf: [256]u8 = undefined;
            while (true) {
                const n = try reader.read(&buf);
                if (n == 0) break;
                try bytes.appendSlice(testing.allocator, buf[0..n]);
            }
            return bytes.toOwnedSlice(testing.allocator);
        }

        fn listenerPort(ln: net_mod.Listener, comptime NetNs: type) !u16 {
            const listener = try ln.as(NetNs.TcpListener);
            return listener.port();
        }

        fn tlsListenerPort(ln: net_mod.Listener, comptime NetNs: type) !u16 {
            const tls_listener = try ln.as(NetNs.tls.Listener);
            const tcp_impl = try tls_listener.inner.as(NetNs.TcpListener);
            return tcp_impl.port();
        }

        fn tlsTransportOptions() Http.Transport.Options {
            return .{
                .tls_client_config = .{
                    .server_name = "example.com",
                    .verification = .self_signed,
                },
            };
        }

        fn tlsServerConfig() Net.tls.ServerConfig {
            return .{
                .certificates = &.{.{
                    .chain = &.{fixtures.self_signed_cert_der[0..]},
                    .private_key = .{ .ecdsa_p256_sha256 = fixtures.self_signed_key_scalar },
                }},
            };
        }
    };

    try Runner.basicGet();
    try Runner.headBodyless();
    try Runner.keepAliveSequentialRequests();
    try Runner.unreadBodyForcesClose();
    try Runner.malformedRequestGetsBadRequest();
    try Runner.conflictingLengthAndChunkedGetsBadRequest();
    try Runner.chunkedRequestBodyRoundTrips();
    try Runner.muxRoutesAndRedirects();
    try Runner.readHeaderTimeoutClosesSlowHeader();
    try Runner.idleTimeoutClosesKeepAliveConn();
    try Runner.shutdownWaitsForActiveHandler();
    try Runner.closeInterruptsIdleKeepAlive();
    try Runner.tlsWrappedListenerServesRequest();
    try Runner.wrappedListenerServesRequest();
}
