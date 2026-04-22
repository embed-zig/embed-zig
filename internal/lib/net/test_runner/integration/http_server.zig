//! HTTP server runner — integration coverage for `http.Server`.

const stdz = @import("stdz");
const io = @import("io");
const context_mod = @import("context");
const fixtures = @import("../../tls/test_fixtures.zig");
const net_mod = @import("../../../net.zig");
const testing_api = @import("testing");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Cases = Suite(lib);

    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("basic_get", testing_api.TestRunner.fromFn(lib, 2 * 1024 * 1024, Cases.basicGet));
            t.run("head_bodyless", testing_api.TestRunner.fromFn(lib, 2 * 1024 * 1024, Cases.headBodyless));
            t.run("keep_alive_sequential_requests", testing_api.TestRunner.fromFn(lib, 2 * 1024 * 1024, Cases.keepAliveSequentialRequests));
            t.run("unread_body_forces_close", testing_api.TestRunner.fromFn(lib, 2 * 1024 * 1024, Cases.unreadBodyForcesClose));
            t.run("malformed_request_gets_bad_request", testing_api.TestRunner.fromFn(lib, 2 * 1024 * 1024, Cases.malformedRequestGetsBadRequest));
            t.run("conflicting_length_and_chunked_gets_bad_request", testing_api.TestRunner.fromFn(lib, 2 * 1024 * 1024, Cases.conflictingLengthAndChunkedGetsBadRequest));
            t.run("chunked_request_body_round_trips", testing_api.TestRunner.fromFn(lib, 2 * 1024 * 1024, Cases.chunkedRequestBodyRoundTrips));
            t.run("flush_streams_chunked_response", testing_api.TestRunner.fromFn(lib, 2 * 1024 * 1024, Cases.flushStreamsChunkedResponse));
            t.run("mux_routes_and_redirects", testing_api.TestRunner.fromFn(lib, 2 * 1024 * 1024, Cases.muxRoutesAndRedirects));
            t.run("read_header_timeout_closes_slow_header", testing_api.TestRunner.fromFn(lib, 2 * 1024 * 1024, Cases.readHeaderTimeoutClosesSlowHeader));
            t.run("idle_timeout_closes_keep_alive_conn", testing_api.TestRunner.fromFn(lib, 2 * 1024 * 1024, Cases.idleTimeoutClosesKeepAliveConn));
            t.run("shutdown_waits_for_active_handler", testing_api.TestRunner.fromFn(lib, 2 * 1024 * 1024, Cases.shutdownWaitsForActiveHandler));
            t.run("close_interrupts_idle_keep_alive", testing_api.TestRunner.fromFn(lib, 2 * 1024 * 1024, Cases.closeInterruptsIdleKeepAlive));
            t.run("tls_wrapped_listener_serves_request", testing_api.TestRunner.fromFn(lib, 2 * 1024 * 1024, Cases.tlsWrappedListenerServesRequest));
            t.run("wrapped_listener_serves_request", testing_api.TestRunner.fromFn(lib, 2 * 1024 * 1024, Cases.wrappedListenerServesRequest));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}

fn Suite(comptime lib: type) type {
    const Net = net_mod.make(lib);
    const Http = Net.http;
    const Thread = lib.Thread;
    return struct {
        const expect = lib.testing.expect;
        const expectEqual = lib.testing.expectEqual;
        const expectEqualStrings = lib.testing.expectEqualStrings;
        const expectError = lib.testing.expectError;

        fn addr4(port: u16) net_mod.netip.AddrPort {
            return net_mod.netip.AddrPort.from4(.{ 127, 0, 0, 1 }, port);
        }

        const ServerRun = struct {
            allocator: lib.mem.Allocator,
            listener: net_mod.Listener,
            port: u16,
            server_err: *?anyerror,
            thread: Thread,

            fn stop(self: *@This(), server: anytype) !void {
                defer self.allocator.destroy(self.server_err);
                self.listener.close();
                server.close();
                self.thread.join();
                defer self.listener.deinit();
                if (self.server_err.*) |err| {
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

        fn basicGet(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const server_spawn_config: Thread.SpawnConfig = .{ .stack_size = 2 * 1024 * 1024 };
            var server = try Http.Server.init(allocator, .{
                .idle_timeout_ms = 20,
            });
            defer server.deinit();
            try server.handleFunc("/hello", struct {
                fn run(rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "5") catch return;
                    _ = rw.write("hello") catch {};
                }
            }.run);

            var srv_run = try startPlainServer(allocator, &server, server_spawn_config);

            var conn = try Net.dial(allocator, .tcp, addr4(srv_run.port));
            defer conn.deinit();
            try io.writeAll(@TypeOf(conn), &conn, "GET /hello HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n");
            const resp = try readRawResponse(allocator, conn, .{});
            defer allocator.free(resp.head);
            defer allocator.free(resp.body);

            try expectEqualStrings("HTTP/1.1 200 OK", firstLine(resp.head));
            try expectEqualStrings("hello", resp.body);
            try srv_run.stop(&server);
        }

        fn headBodyless(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const server_spawn_config: Thread.SpawnConfig = .{ .stack_size = 2 * 1024 * 1024 };
            var server = try Http.Server.init(allocator, .{});
            defer server.deinit();
            try server.handleFunc("/head", struct {
                fn run(rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "5") catch return;
                    _ = rw.write("hello") catch {};
                }
            }.run);

            var srv_run = try startPlainServer(allocator, &server, server_spawn_config);

            var conn = try Net.dial(allocator, .tcp, addr4(srv_run.port));
            defer conn.deinit();
            try io.writeAll(@TypeOf(conn), &conn, "HEAD /head HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n");
            const resp = try readRawResponse(allocator, conn, .{ .request_method = "HEAD" });
            defer allocator.free(resp.head);
            defer allocator.free(resp.body);

            try expectEqualStrings("HTTP/1.1 200 OK", firstLine(resp.head));
            try expectEqual(@as(usize, 0), resp.body.len);
            try srv_run.stop(&server);
        }

        fn keepAliveSequentialRequests(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const server_spawn_config: Thread.SpawnConfig = .{ .stack_size = 2 * 1024 * 1024 };
            var server = try Http.Server.init(allocator, .{});
            defer server.deinit();
            try server.handleFunc("/keep", struct {
                fn run(rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "2") catch return;
                    _ = rw.write("ok") catch {};
                }
            }.run);

            var srv_run = try startPlainServer(allocator, &server, server_spawn_config);
            defer srv_run.stop(&server) catch {};

            var conn = try Net.dial(allocator, .tcp, addr4(srv_run.port));
            defer conn.deinit();

            try io.writeAll(@TypeOf(conn), &conn, "GET /keep HTTP/1.1\r\nHost: example.com\r\n\r\n");
            const first = try readRawResponse(allocator, conn, .{});
            defer allocator.free(first.head);
            defer allocator.free(first.body);
            try expectEqualStrings("ok", first.body);

            try io.writeAll(@TypeOf(conn), &conn, "GET /keep HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n");
            const second = try readRawResponse(allocator, conn, .{});
            defer allocator.free(second.head);
            defer allocator.free(second.body);
            try expectEqualStrings("ok", second.body);
        }

        fn unreadBodyForcesClose(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const server_spawn_config: Thread.SpawnConfig = .{ .stack_size = 2 * 1024 * 1024 };
            var server = try Http.Server.init(allocator, .{});
            defer server.deinit();
            try server.handleFunc("/upload", struct {
                fn run(rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "2") catch return;
                    _ = rw.write("ok") catch {};
                }
            }.run);

            var srv_run = try startPlainServer(allocator, &server, server_spawn_config);
            defer srv_run.stop(&server) catch {};

            var conn = try Net.dial(allocator, .tcp, addr4(srv_run.port));
            defer conn.deinit();

            try io.writeAll(@TypeOf(conn), &conn, "POST /upload HTTP/1.1\r\nHost: example.com\r\nContent-Length: 4\r\n\r\nABCD");
            const first = try readRawResponse(allocator, conn, .{});
            defer allocator.free(first.head);
            defer allocator.free(first.body);
            try expectEqualStrings("ok", first.body);

            try io.writeAll(@TypeOf(conn), &conn, "GET /upload HTTP/1.1\r\nHost: example.com\r\n\r\n");
            var buf: [16]u8 = undefined;
            const n = conn.read(&buf) catch |err| {
                try expect(err == error.EndOfStream or err == error.ConnectionReset or err == error.BrokenPipe);
                return;
            };
            try expectEqual(@as(usize, 0), n);
        }

        fn malformedRequestGetsBadRequest(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const server_spawn_config: Thread.SpawnConfig = .{ .stack_size = 2 * 1024 * 1024 };
            var server = try Http.Server.init(allocator, .{});
            defer server.deinit();
            try server.handleFunc("/", struct {
                fn run(rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "1") catch return;
                    _ = rw.write("x") catch {};
                }
            }.run);

            var srv_run = try startPlainServer(allocator, &server, server_spawn_config);
            defer srv_run.stop(&server) catch {};

            var conn = try Net.dial(allocator, .tcp, addr4(srv_run.port));
            defer conn.deinit();
            try io.writeAll(@TypeOf(conn), &conn, "BROKEN\r\n\r\n");
            const resp = try readRawResponse(allocator, conn, .{});
            defer allocator.free(resp.head);
            defer allocator.free(resp.body);
            try expect(lib.mem.startsWith(u8, firstLine(resp.head), "HTTP/1.1 400"));
        }

        fn conflictingLengthAndChunkedGetsBadRequest(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const server_spawn_config: Thread.SpawnConfig = .{ .stack_size = 2 * 1024 * 1024 };
            var server = try Http.Server.init(allocator, .{});
            defer server.deinit();
            try server.handleFunc("/upload", struct {
                fn run(rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "2") catch return;
                    _ = rw.write("ok") catch {};
                }
            }.run);

            var srv_run = try startPlainServer(allocator, &server, server_spawn_config);
            defer srv_run.stop(&server) catch {};

            var conn = try Net.dial(allocator, .tcp, addr4(srv_run.port));
            defer conn.deinit();
            try io.writeAll(
                @TypeOf(conn),
                &conn,
                "POST /upload HTTP/1.1\r\nHost: example.com\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n4\r\nABCD\r\n0\r\n\r\n",
            );
            const resp = try readRawResponse(allocator, conn, .{});
            defer allocator.free(resp.head);
            defer allocator.free(resp.body);
            try expect(lib.mem.startsWith(u8, firstLine(resp.head), "HTTP/1.1 400"));
        }

        fn chunkedRequestBodyRoundTrips(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const server_spawn_config: Thread.SpawnConfig = .{ .stack_size = 2 * 1024 * 1024 };
            var server = try Http.Server.init(allocator, .{});
            defer server.deinit();
            const ChunkedHandler = struct {
                allocator: lib.mem.Allocator,

                pub fn serveHTTP(self: *@This(), rw: *Http.ResponseWriter, req: *Http.Request) void {
                    const body = req.body() orelse {
                        rw.writeHeader(Http.status.bad_request) catch {};
                        return;
                    };
                    var reader = body;
                    var buf: [16]u8 = undefined;
                    var out = lib.ArrayList(u8){};
                    defer out.deinit(self.allocator);
                    while (true) {
                        const n = reader.read(&buf) catch {
                            rw.writeHeader(Http.status.bad_request) catch {};
                            return;
                        };
                        if (n == 0) break;
                        out.appendSlice(self.allocator, buf[0..n]) catch {
                            rw.writeHeader(Http.status.internal_server_error) catch {};
                            return;
                        };
                    }
                    rw.setHeader(Http.Header.content_length, "6") catch return;
                    _ = rw.write(out.items) catch {};
                }
            };
            var chunked_handler = ChunkedHandler{ .allocator = allocator };
            try server.handle("/chunked", Http.Handler.init(&chunked_handler));

            var srv_run = try startPlainServer(allocator, &server, server_spawn_config);
            defer srv_run.stop(&server) catch {};

            var conn = try Net.dial(allocator, .tcp, addr4(srv_run.port));
            defer conn.deinit();
            try io.writeAll(
                @TypeOf(conn),
                &conn,
                "POST /chunked HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n3\r\nabc\r\n3\r\ndef\r\n0\r\n\r\n",
            );
            const resp = try readRawResponse(allocator, conn, .{});
            defer allocator.free(resp.head);
            defer allocator.free(resp.body);
            try expectEqualStrings("HTTP/1.1 200 OK", firstLine(resp.head));
            try expectEqualStrings("abcdef", resp.body);
        }

        fn flushStreamsChunkedResponse(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const server_spawn_config: Thread.SpawnConfig = .{ .stack_size = 2 * 1024 * 1024 };
            var server = try Http.Server.init(allocator, .{});
            defer server.deinit();

            var first_chunk_flushed = Gate{};
            var release = Gate{};
            const StreamingHandler = struct {
                first_chunk_flushed: *Gate,
                release: *Gate,

                pub fn serveHTTP(self: *@This(), rw: *Http.ResponseWriter, _: *Http.Request) void {
                    _ = rw.write("a") catch return;
                    rw.flush() catch return;
                    self.first_chunk_flushed.signal();
                    self.release.wait();
                    _ = rw.write("b") catch {};
                }
            };

            var streaming_handler = StreamingHandler{
                .first_chunk_flushed = &first_chunk_flushed,
                .release = &release,
            };
            try server.handle("/stream", Http.Handler.init(&streaming_handler));

            var srv_run = try startPlainServer(allocator, &server, server_spawn_config);
            defer srv_run.stop(&server) catch {};

            var conn = try Net.dial(allocator, .tcp, addr4(srv_run.port));
            defer conn.deinit();
            conn.setReadTimeout(200);
            defer conn.setReadTimeout(null);

            try io.writeAll(@TypeOf(conn), &conn, "GET /stream HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n");
            first_chunk_flushed.wait();

            var partial = lib.ArrayList(u8){};
            defer partial.deinit(allocator);
            var buf: [256]u8 = undefined;
            while (lib.mem.indexOf(u8, partial.items, "1\r\na\r\n") == null) {
                const n = try conn.read(&buf);
                if (n == 0) return error.EndOfStream;
                try partial.appendSlice(allocator, buf[0..n]);
            }

            try expect(lib.mem.indexOf(u8, partial.items, "HTTP/1.1 200 OK\r\n") != null);
            try expect(lib.mem.indexOf(u8, partial.items, "Transfer-Encoding: chunked\r\n") != null);
            try expect(lib.mem.indexOf(u8, partial.items, "1\r\na\r\n") != null);
            try expect(lib.mem.indexOf(u8, partial.items, "1\r\nb\r\n") == null);
            try expect(lib.mem.indexOf(u8, partial.items, "0\r\n\r\n") == null);

            release.signal();

            while (true) {
                const n = conn.read(&buf) catch |err| switch (err) {
                    error.EndOfStream,
                    error.ConnectionReset,
                    error.BrokenPipe,
                    => break,
                    else => return err,
                };
                if (n == 0) break;
                try partial.appendSlice(allocator, buf[0..n]);
            }

            try expect(lib.mem.indexOf(u8, partial.items, "1\r\na\r\n1\r\nb\r\n0\r\n\r\n") != null);
        }

        fn muxRoutesAndRedirects(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const server_spawn_config: Thread.SpawnConfig = .{ .stack_size = 2 * 1024 * 1024 };
            const exercise = struct {
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

                fn run(case_allocator: lib.mem.Allocator, case_server_spawn_config: Thread.SpawnConfig, comptime use_static: bool) !void {
                    var exact_handler = ExactHandler{};
                    var api_handler = ApiHandler{};

                    if (use_static) {
                        const StaticNoCatchAll = Http.StaticServeMux(.{
                            "/exact",
                            "/api/",
                        });
                        var mux = StaticNoCatchAll.init(.{ &exact_handler, &api_handler });
                        var server = try Http.Server.init(case_allocator, .{ .handler = mux.handler() });
                        defer server.deinit();

                        var srv_run = try startPlainServer(case_allocator, &server, case_server_spawn_config);
                        defer srv_run.stop(&server) catch {};
                        try assertNoCatchAllMatrix(case_allocator, srv_run.port);
                    } else {
                        var server = try Http.Server.init(case_allocator, .{});
                        defer server.deinit();
                        try server.handle("/exact", Http.Handler.init(&exact_handler));
                        try server.handle("/api/", Http.Handler.init(&api_handler));

                        var srv_run = try startPlainServer(case_allocator, &server, case_server_spawn_config);
                        defer srv_run.stop(&server) catch {};
                        try assertNoCatchAllMatrix(case_allocator, srv_run.port);
                    }

                    var pair_exact = PairExactHandler{};
                    var pair_subtree = PairSubtreeHandler{};

                    if (use_static) {
                        const StaticExactAndSubtree = Http.StaticServeMux(.{
                            "/pair",
                            "/pair/",
                        });
                        var mux = StaticExactAndSubtree.init(.{ &pair_exact, &pair_subtree });
                        var server = try Http.Server.init(case_allocator, .{ .handler = mux.handler() });
                        defer server.deinit();

                        var srv_run = try startPlainServer(case_allocator, &server, case_server_spawn_config);
                        defer srv_run.stop(&server) catch {};
                        try assertExactAndSubtreeMatrix(case_allocator, srv_run.port);
                    } else {
                        var server = try Http.Server.init(case_allocator, .{});
                        defer server.deinit();
                        try server.handle("/pair", Http.Handler.init(&pair_exact));
                        try server.handle("/pair/", Http.Handler.init(&pair_subtree));

                        var srv_run = try startPlainServer(case_allocator, &server, case_server_spawn_config);
                        defer srv_run.stop(&server) catch {};
                        try assertExactAndSubtreeMatrix(case_allocator, srv_run.port);
                    }

                    var root_handler = RootHandler{};
                    var api_handler2 = ApiHandler{};

                    if (use_static) {
                        const StaticWithCatchAll = Http.StaticServeMux(.{
                            "/",
                            "/api/",
                        });
                        var mux = StaticWithCatchAll.init(.{ &root_handler, &api_handler2 });
                        var server = try Http.Server.init(case_allocator, .{ .handler = mux.handler() });
                        defer server.deinit();

                        var srv_run = try startPlainServer(case_allocator, &server, case_server_spawn_config);
                        defer srv_run.stop(&server) catch {};
                        try assertCatchAllMatrix(case_allocator, srv_run.port);
                    } else {
                        var server = try Http.Server.init(case_allocator, .{});
                        defer server.deinit();
                        try server.handle("/", Http.Handler.init(&root_handler));
                        try server.handle("/api/", Http.Handler.init(&api_handler2));

                        var srv_run = try startPlainServer(case_allocator, &server, case_server_spawn_config);
                        defer srv_run.stop(&server) catch {};
                        try assertCatchAllMatrix(case_allocator, srv_run.port);
                    }
                }

                fn assertNoCatchAllMatrix(case_allocator: lib.mem.Allocator, port: u16) !void {
                    const exact = try requestRawGet(case_allocator, port, "/exact");
                    defer case_allocator.free(exact.head);
                    defer case_allocator.free(exact.body);
                    try expectEqualStrings("HTTP/1.1 200 OK", firstLine(exact.head));
                    try expectEqualStrings("exact", exact.body);

                    const api = try requestRawGet(case_allocator, port, "/api/users");
                    defer case_allocator.free(api.head);
                    defer case_allocator.free(api.body);
                    try expectEqualStrings("HTTP/1.1 200 OK", firstLine(api.head));
                    try expectEqualStrings("api", api.body);

                    const slash = try requestRawGet(case_allocator, port, "/api");
                    defer case_allocator.free(slash.head);
                    defer case_allocator.free(slash.body);
                    try expect(lib.mem.startsWith(u8, firstLine(slash.head), "HTTP/1.1 301"));
                    try expectEqualStrings("/api/", headerValue(slash.head, Http.Header.location) orelse "");

                    const cleaned = try requestRawGet(case_allocator, port, "/api/../api/users");
                    defer case_allocator.free(cleaned.head);
                    defer case_allocator.free(cleaned.body);
                    try expect(lib.mem.startsWith(u8, firstLine(cleaned.head), "HTTP/1.1 301"));
                    try expectEqualStrings("/api/users", headerValue(cleaned.head, Http.Header.location) orelse "");

                    const missing = try requestRawGet(case_allocator, port, "/missing");
                    defer case_allocator.free(missing.head);
                    defer case_allocator.free(missing.body);
                    try expect(lib.mem.startsWith(u8, firstLine(missing.head), "HTTP/1.1 404"));
                }

                fn assertCatchAllMatrix(case_allocator: lib.mem.Allocator, port: u16) !void {
                    const api = try requestRawGet(case_allocator, port, "/api/users");
                    defer case_allocator.free(api.head);
                    defer case_allocator.free(api.body);
                    try expectEqualStrings("HTTP/1.1 200 OK", firstLine(api.head));
                    try expectEqualStrings("api", api.body);

                    const root = try requestRawGet(case_allocator, port, "/other");
                    defer case_allocator.free(root.head);
                    defer case_allocator.free(root.body);
                    try expectEqualStrings("HTTP/1.1 200 OK", firstLine(root.head));
                    try expectEqualStrings("root", root.body);
                }

                fn assertExactAndSubtreeMatrix(case_allocator: lib.mem.Allocator, port: u16) !void {
                    const redirect = try requestRawGet(case_allocator, port, "/pair");
                    defer case_allocator.free(redirect.head);
                    defer case_allocator.free(redirect.body);
                    try expect(lib.mem.startsWith(u8, firstLine(redirect.head), "HTTP/1.1 301"));
                    try expectEqualStrings("/pair/", headerValue(redirect.head, Http.Header.location) orelse "");

                    const subtree = try requestRawGet(case_allocator, port, "/pair/");
                    defer case_allocator.free(subtree.head);
                    defer case_allocator.free(subtree.body);
                    try expectEqualStrings("HTTP/1.1 200 OK", firstLine(subtree.head));
                    try expectEqualStrings("pair-subtree", subtree.body);

                    const deep_subtree = try requestRawGet(case_allocator, port, "/pair/users");
                    defer case_allocator.free(deep_subtree.head);
                    defer case_allocator.free(deep_subtree.body);
                    try expectEqualStrings("HTTP/1.1 200 OK", firstLine(deep_subtree.head));
                    try expectEqualStrings("pair-subtree", deep_subtree.body);
                }
            };

            try exercise.run(allocator, server_spawn_config, false);
            try exercise.run(allocator, server_spawn_config, true);
        }

        fn readHeaderTimeoutClosesSlowHeader(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const server_spawn_config: Thread.SpawnConfig = .{ .stack_size = 2 * 1024 * 1024 };
            var server = try Http.Server.init(allocator, .{
                .read_header_timeout_ms = 20,
            });
            defer server.deinit();
            try server.handleFunc("/slow", struct {
                fn run(rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "2") catch return;
                    _ = rw.write("ok") catch {};
                }
            }.run);

            var srv_run = try startPlainServer(allocator, &server, server_spawn_config);
            defer srv_run.stop(&server) catch {};

            var conn = try Net.dial(allocator, .tcp, addr4(srv_run.port));
            defer conn.deinit();
            try io.writeAll(@TypeOf(conn), &conn, "GET /slow HTTP/1.1\r\n");
            Thread.sleep(40 * lib.time.ns_per_ms);
            try io.writeAll(@TypeOf(conn), &conn, "Host: example.com\r\nConnection: close\r\n\r\n");

            var buf: [64]u8 = undefined;
            const n = conn.read(&buf) catch |err| {
                try expect(err == error.EndOfStream or err == error.ConnectionReset or err == error.BrokenPipe or err == error.TimedOut);
                return;
            };
            if (n != 0) {
                try expect(lib.mem.startsWith(u8, buf[0..n], "HTTP/1.1 400"));
            }
        }

        fn idleTimeoutClosesKeepAliveConn(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const server_spawn_config: Thread.SpawnConfig = .{ .stack_size = 2 * 1024 * 1024 };
            var server = try Http.Server.init(allocator, .{
                .idle_timeout_ms = 20,
            });
            defer server.deinit();
            try server.handleFunc("/idle-timeout", struct {
                fn run(rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "2") catch return;
                    _ = rw.write("ok") catch {};
                }
            }.run);

            var srv_run = try startPlainServer(allocator, &server, server_spawn_config);
            defer srv_run.stop(&server) catch {};

            var conn = try Net.dial(allocator, .tcp, addr4(srv_run.port));
            defer conn.deinit();
            try io.writeAll(@TypeOf(conn), &conn, "GET /idle-timeout HTTP/1.1\r\nHost: example.com\r\n\r\n");
            const first = try readRawResponse(allocator, conn, .{});
            defer allocator.free(first.head);
            defer allocator.free(first.body);
            try expectEqualStrings("ok", first.body);

            Thread.sleep(40 * lib.time.ns_per_ms);
            try io.writeAll(@TypeOf(conn), &conn, "GET /idle-timeout HTTP/1.1\r\nHost: example.com\r\n\r\n");
            var buf: [64]u8 = undefined;
            const n = conn.read(&buf) catch |err| {
                try expect(err == error.EndOfStream or err == error.ConnectionReset or err == error.BrokenPipe or err == error.TimedOut);
                return;
            };
            try expectEqual(@as(usize, 0), n);
        }

        fn shutdownWaitsForActiveHandler(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const server_spawn_config: Thread.SpawnConfig = .{ .stack_size = 2 * 1024 * 1024 };
            const request_spawn_config: Thread.SpawnConfig = .{ .stack_size = 2 * 1024 * 1024 };
            const shutdown_spawn_config: Thread.SpawnConfig = .{ .stack_size = 256 * 1024 };
            var server = try Http.Server.init(allocator, .{});
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

            var srv_run = try startPlainServer(allocator, &server, server_spawn_config);
            defer srv_run.stop(&server) catch {};

            var transport = try Http.Transport.init(allocator, .{});
            defer transport.deinit();
            const raw_url = try lib.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/slow", .{srv_run.port});
            defer allocator.free(raw_url);
            var req = try Http.Request.init(allocator, "GET", raw_url);
            req.close = true;
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
            var request_thread = try Thread.spawn(request_spawn_config, RoundTripTask.exec, .{&round_trip});
            entered.wait();

            const ContextNs = context_mod.make(lib);
            var ctx_ns = try ContextNs.init(allocator);
            defer ctx_ns.deinit();
            var shutdown_ctx = try ctx_ns.withTimeout(ctx_ns.background(), 200 * lib.time.ns_per_ms);
            defer shutdown_ctx.deinit();

            var shutdown_task = ShutdownTask{ .server = &server, .ctx = shutdown_ctx };
            var shutdown_thread = try Thread.spawn(shutdown_spawn_config, ShutdownTask.run, .{&shutdown_task});
            defer shutdown_thread.join();

            try expect(!shutdown_task.waitFor(20));
            release.signal();
            try expect(shutdown_task.waitFor(200));
            try expect(shutdown_task.err == null);
            request_thread.join();
            if (round_trip.err) |err| return err;
            var resp = round_trip.resp orelse return error.TestUnexpectedResult;
            defer resp.deinit();
            const body = try readBody(allocator, resp);
            defer allocator.free(body);
            try expectEqualStrings("done", body);
        }

        fn closeInterruptsIdleKeepAlive(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const server_spawn_config: Thread.SpawnConfig = .{ .stack_size = 2 * 1024 * 1024 };
            var server = try Http.Server.init(allocator, .{});
            defer server.deinit();
            try server.handleFunc("/idle", struct {
                fn run(rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "2") catch return;
                    _ = rw.write("ok") catch {};
                }
            }.run);

            var srv_run = try startPlainServer(allocator, &server, server_spawn_config);
            defer srv_run.stop(&server) catch {};

            var conn = try Net.dial(allocator, .tcp, addr4(srv_run.port));
            defer conn.deinit();
            try io.writeAll(@TypeOf(conn), &conn, "GET /idle HTTP/1.1\r\nHost: example.com\r\n\r\n");
            const first = try readRawResponse(allocator, conn, .{});
            defer allocator.free(first.head);
            defer allocator.free(first.body);

            server.close();
            var buf: [16]u8 = undefined;
            const n = conn.read(&buf) catch |err| {
                try expect(err == error.EndOfStream or err == error.ConnectionReset or err == error.BrokenPipe);
                return;
            };
            try expectEqual(@as(usize, 0), n);
        }

        fn tlsWrappedListenerServesRequest(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const server_spawn_config: Thread.SpawnConfig = .{ .stack_size = 2 * 1024 * 1024 };
            var server = try Http.Server.init(allocator, .{});
            defer server.deinit();
            try server.handleFunc("/secure", struct {
                fn run(rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "6") catch return;
                    _ = rw.write("secure") catch {};
                }
            }.run);

            var srv_run = try startTlsServer(allocator, &server, server_spawn_config);
            defer srv_run.stop(&server) catch {};

            var transport = try Http.Transport.init(allocator, tlsTransportOptions());
            defer transport.deinit();
            const raw_url = try lib.fmt.allocPrint(allocator, "https://127.0.0.1:{d}/secure", .{srv_run.port});
            defer allocator.free(raw_url);

            var req = try Http.Request.init(allocator, "GET", raw_url);
            req.close = true;
            defer req.deinit();
            var resp = try transport.roundTrip(&req);
            defer resp.deinit();
            const body = try readBody(allocator, resp);
            defer allocator.free(body);
            try expectEqualStrings("secure", body);
        }

        fn wrappedListenerServesRequest(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const server_spawn_config: Thread.SpawnConfig = .{ .stack_size = 2 * 1024 * 1024 };
            var server = try Http.Server.init(allocator, .{});
            defer server.deinit();
            try server.handleFunc("/wrapped", struct {
                fn run(rw: *Http.ResponseWriter, _: *Http.Request) void {
                    rw.setHeader(Http.Header.content_length, "7") catch return;
                    _ = rw.write("wrapped") catch {};
                }
            }.run);

            const inner = try Net.listen(allocator, .{ .address = addr4(0) });
            var wrapped = WrappedListener{ .inner = inner };
            const listener = net_mod.Listener.init(&wrapped);
            const port = try listenerPort(inner, Net);
            var server_err: ?anyerror = null;
            var thread = try Thread.spawn(server_spawn_config, struct {
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

            var conn = try Net.dial(allocator, .tcp, addr4(port));
            defer conn.deinit();
            try io.writeAll(@TypeOf(conn), &conn, "GET /wrapped HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n");
            const resp = try readRawResponse(allocator, conn, .{});
            defer allocator.free(resp.head);
            defer allocator.free(resp.body);
            try expectEqualStrings("wrapped", resp.body);
        }

        fn startPlainServer(allocator: lib.mem.Allocator, server: *Http.Server, server_spawn_config: Thread.SpawnConfig) !ServerRun {
            const listener = try Net.listen(allocator, .{ .address = addr4(0) });
            errdefer listener.deinit();
            const port = try listenerPort(listener, Net);
            const server_err = try allocator.create(?anyerror);
            errdefer allocator.destroy(server_err);
            server_err.* = null;
            var run = ServerRun{
                .allocator = allocator,
                .listener = listener,
                .port = port,
                .server_err = server_err,
                .thread = undefined,
            };
            run.thread = try Thread.spawn(server_spawn_config, struct {
                fn exec(s: *Http.Server, ln: net_mod.Listener, err: *?anyerror) void {
                    s.serve(ln) catch |serve_err| {
                        err.* = serve_err;
                    };
                }
            }.exec, .{ server, listener, server_err });
            return run;
        }

        fn startTlsServer(allocator: lib.mem.Allocator, server: *Http.Server, server_spawn_config: Thread.SpawnConfig) !ServerRun {
            const listener = try Net.tls.listen(allocator, .{ .address = addr4(0) }, tlsServerConfig());
            errdefer listener.deinit();
            const port = try tlsListenerPort(listener, Net);
            const server_err = try allocator.create(?anyerror);
            errdefer allocator.destroy(server_err);
            server_err.* = null;
            var run = ServerRun{
                .allocator = allocator,
                .listener = listener,
                .port = port,
                .server_err = server_err,
                .thread = undefined,
            };
            run.thread = try Thread.spawn(server_spawn_config, struct {
                fn exec(s: *Http.Server, ln: net_mod.Listener, err: *?anyerror) void {
                    s.serve(ln) catch |serve_err| {
                        err.* = serve_err;
                    };
                }
            }.exec, .{ server, listener, server_err });
            return run;
        }

        fn requestRawGet(allocator: lib.mem.Allocator, port: u16, target: []const u8) !RawResponse {
            var conn = try Net.dial(allocator, .tcp, addr4(port));
            defer conn.deinit();
            const raw = try lib.fmt.allocPrint(
                allocator,
                "GET {s} HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n",
                .{target},
            );
            defer allocator.free(raw);
            try io.writeAll(@TypeOf(conn), &conn, raw);
            return readRawResponse(allocator, conn, .{});
        }

        const RawResponse = struct {
            head: []u8,
            body: []u8,
        };

        const ReadRawResponseOptions = struct {
            request_method: ?[]const u8 = null,
        };

        fn readRawResponse(allocator: lib.mem.Allocator, conn: net_mod.Conn, options: ReadRawResponseOptions) !RawResponse {
            var c = conn;
            var bytes = try lib.ArrayList(u8).initCapacity(allocator, 0);
            defer bytes.deinit(allocator);
            var buf: [256]u8 = undefined;

            var head_end: ?usize = null;
            while (head_end == null) {
                const n = try c.read(&buf);
                if (n == 0) return error.EndOfStream;
                try bytes.appendSlice(allocator, buf[0..n]);
                if (lib.mem.indexOf(u8, bytes.items, "\r\n\r\n")) |end| head_end = end;
            }

            const split = head_end.? + 4;
            const head = try allocator.dupe(u8, bytes.items[0..split]);
            errdefer allocator.free(head);
            const prefix = bytes.items[split..];
            const status_code = try responseStatusCode(head);

            if (!responseBodyAllowed(options.request_method, status_code)) {
                return .{
                    .head = head,
                    .body = try allocator.dupe(u8, prefix),
                };
            }

            if (headerValue(head, Http.Header.content_length)) |value| {
                const content_length = try lib.fmt.parseInt(usize, value, 10);
                const body = try readFixedBody(allocator, c, prefix, content_length);
                return .{ .head = head, .body = body };
            }
            if (headerValue(head, Http.Header.transfer_encoding)) |value| {
                if (lib.ascii.eqlIgnoreCase(value, "chunked")) {
                    const body = try readChunkedBody(allocator, c, prefix);
                    return .{ .head = head, .body = body };
                }
            }
            return .{
                .head = head,
                .body = try allocator.dupe(u8, prefix),
            };
        }

        fn readFixedBody(allocator: lib.mem.Allocator, conn: net_mod.Conn, prefix: []const u8, total_len: usize) ![]u8 {
            var bytes = try lib.ArrayList(u8).initCapacity(allocator, total_len);
            errdefer bytes.deinit(allocator);
            try bytes.appendSlice(allocator, prefix[0..@min(prefix.len, total_len)]);
            var c = conn;
            var buf: [256]u8 = undefined;
            while (bytes.items.len < total_len) {
                const want = @min(buf.len, total_len - bytes.items.len);
                const n = try c.read(buf[0..want]);
                if (n == 0) return error.EndOfStream;
                try bytes.appendSlice(allocator, buf[0..n]);
            }
            return bytes.toOwnedSlice(allocator);
        }

        fn readChunkedBody(allocator: lib.mem.Allocator, conn: net_mod.Conn, prefix: []const u8) ![]u8 {
            var stream = io.PrefixReader(net_mod.Conn).init(conn, prefix);
            var body = lib.ArrayList(u8){};
            defer body.deinit(allocator);
            var line_buf: [128]u8 = undefined;
            while (true) {
                const line = try stream.readLine(&line_buf);
                const semi = lib.mem.indexOfScalar(u8, line, ';') orelse line.len;
                const size = try lib.fmt.parseInt(usize, lib.mem.trim(u8, line[0..semi], " "), 16);
                if (size == 0) {
                    try stream.expectCrlf();
                    break;
                }
                const chunk = try allocator.alloc(u8, size);
                defer allocator.free(chunk);
                try io.readFull(@TypeOf(stream), &stream, chunk);
                try body.appendSlice(allocator, chunk);
                try stream.expectCrlf();
            }
            return body.toOwnedSlice(allocator);
        }

        fn responseStatusCode(head: []const u8) !u16 {
            const line = firstLine(head);
            var parts = lib.mem.tokenizeAny(u8, line, " ");
            _ = parts.next() orelse return error.BadResponse;
            const code = parts.next() orelse return error.BadResponse;
            return try lib.fmt.parseInt(u16, code, 10);
        }

        fn responseBodyAllowed(request_method: ?[]const u8, status_code: u16) bool {
            if (status_code >= 100 and status_code < 200) return false;
            if (status_code == Http.status.no_content or status_code == Http.status.not_modified) return false;
            if (request_method) |method| {
                if (lib.ascii.eqlIgnoreCase(method, "HEAD")) return false;
            }
            return true;
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

        fn readBody(allocator: lib.mem.Allocator, resp: Http.Response) ![]u8 {
            const body = resp.body() orelse return allocator.dupe(u8, "");
            var reader = body;
            var bytes = try lib.ArrayList(u8).initCapacity(allocator, 0);
            errdefer bytes.deinit(allocator);
            var buf: [256]u8 = undefined;
            while (true) {
                const n = try reader.read(&buf);
                if (n == 0) break;
                try bytes.appendSlice(allocator, buf[0..n]);
            }
            return bytes.toOwnedSlice(allocator);
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
}
