//! HTTPS transport test runner — local HTTPS integration tests.
//!
//! Covers:
//! - direct HTTPS round trips over a self-signed local listener
//! - idle HTTPS connection reuse after the response body is fully drained
//! - TLS handshake timeout enforcement
//! - timeout / proxy / ALPN regressions over local fixtures

const embed = @import("embed");
const io = @import("io");
const net_mod = @import("../../../net.zig");
const context_mod = @import("context");
const fixtures = @import("../../tls/test_fixtures.zig");
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
                t.logErrorf("https_transport runner failed: {}", .{err});
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
    const Addr = net_mod.netip.AddrPort;
    const Context = context_mod.make(lib);
    const Thread = lib.Thread;
    const testing = struct {
        pub var allocator: lib.mem.Allocator = undefined;
        pub const expect = lib.testing.expect;
        pub const expectEqual = lib.testing.expectEqual;
        pub const expectEqualSlices = lib.testing.expectEqualSlices;
        pub const expectEqualStrings = lib.testing.expectEqualStrings;
        pub const expectError = lib.testing.expectError;
    };
    testing.allocator = alloc;
    const test_spawn_config: Thread.SpawnConfig = .{
        .stack_size = 64 * 1024,
    };

    const Runner = struct {
        fn addr4(port: u16) Addr {
            return Addr.from4(.{ 127, 0, 0, 1 }, port);
        }

        const ReuseState = struct {
            reused: bool = false,
            accepted: usize = 0,
        };

        const RoundTripTask = struct {
            mutex: Thread.Mutex = .{},
            cond: Thread.Condition = .{},
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

        const BridgeErrorSlot = struct {
            mutex: Thread.Mutex = .{},
            err: ?anyerror = null,

            fn store(self: *@This(), err: anyerror) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.err == null) self.err = err;
            }

            fn load(self: *@This()) ?anyerror {
                self.mutex.lock();
                defer self.mutex.unlock();
                return self.err;
            }
        };

        const BridgeStopFlag = struct {
            mutex: Thread.Mutex = .{},
            stopping: bool = false,

            fn signal(self: *@This()) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.stopping = true;
            }

            fn load(self: *@This()) bool {
                self.mutex.lock();
                defer self.mutex.unlock();
                return self.stopping;
            }
        };

        const ProxyState = struct {
            accepted: usize = 0,
            saw_header: bool = false,
        };

        fn selfSignedRoundTrip() !void {
            var ln = try Net.tls.listen(testing.allocator, .{
                .address = addr4(0),
            }, tlsServerConfig());
            defer ln.deinit();

            const listener_impl = try ln.as(Net.tls.Listener);
            const port = try tlsListenerPort(ln, Net);
            var server_result: ?anyerror = null;

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
                    const req_head = readRequestHead(conn, &req_buf) catch |err| {
                        result.* = err;
                        return;
                    };
                    if (!hasRequestLine(req_head, "GET /hello HTTP/1.1")) {
                        result.* = error.TestUnexpectedResult;
                        return;
                    }

                    var head_buf: [256]u8 = undefined;
                    const body = "secure pong";
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

            var transport = try Http.Transport.init(testing.allocator, tlsTransportOptions());
            defer transport.deinit();

            const raw_url = try lib.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/hello", .{port});
            defer testing.allocator.free(raw_url);

            var req = try Http.Request.init(testing.allocator, "GET", raw_url);
            var resp = try transport.roundTrip(&req);
            defer resp.deinit();

            try testing.expectEqual(@as(u16, 200), resp.status_code);
            const tls_state = resp.tls orelse return error.TestUnexpectedResult;
            try testing.expectEqual(@as(u16, @intFromEnum(Net.tls.ProtocolVersion.tls_1_3)), tls_state.version);
            try testing.expect(tls_state.cipher_suite != 0);
            try testing.expect(tls_state.peer_certificate_der != null);
            try testing.expectEqualSlices(u8, fixtures.self_signed_cert_der[0..], tls_state.peer_certificate_der.?);
            const body = try readBody(resp);
            defer testing.allocator.free(body);
            try testing.expectEqualStrings("secure pong", body);

            if (server_result) |err| return err;
        }

        fn idleConnectionIsReused() !void {
            var state = ReuseState{};
            var ln = try Net.tls.listen(testing.allocator, .{
                .address = addr4(0),
            }, tlsServerConfig());
            defer ln.deinit();

            const listener_impl = try ln.as(Net.tls.Listener);
            const port = try tlsListenerPort(ln, Net);
            var server_result: ?anyerror = null;

            var server_thread = try Thread.spawn(test_spawn_config, struct {
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

                    _ = serveKeepAliveRequest(conn, "GET /first HTTP/1.1", "first over tls", false) catch |err| {
                        result.* = err;
                        return;
                    };

                    conn.setReadTimeout(150);
                    const reused = serveKeepAliveRequest(conn, "GET /second HTTP/1.1", "second over tls", true) catch |err| switch (err) {
                        error.EndOfStream,
                        error.TimedOut,
                        error.Unexpected,
                        => false,
                        else => {
                            result.* = err;
                            return;
                        },
                    };
                    if (reused) {
                        reuse_state.reused = true;
                        return;
                    }

                    var second_conn = listener.accept() catch |err| {
                        result.* = err;
                        return;
                    };
                    defer second_conn.deinit();
                    reuse_state.accepted += 1;

                    const second_typed = second_conn.as(Net.tls.ServerConn) catch {
                        result.* = error.TestUnexpectedResult;
                        return;
                    };
                    second_typed.handshake() catch |err| {
                        result.* = err;
                        return;
                    };

                    _ = serveKeepAliveRequest(second_conn, "GET /second HTTP/1.1", "second over tls", true) catch |err| {
                        result.* = err;
                    };
                }
            }.run, .{ listener_impl, &state, &server_result });
            defer server_thread.join();

            var transport = try Http.Transport.init(testing.allocator, tlsTransportOptions());
            defer transport.deinit();

            const first_url = try lib.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/first", .{port});
            defer testing.allocator.free(first_url);
            var req1 = try Http.Request.init(testing.allocator, "GET", first_url);
            var resp1 = try transport.roundTrip(&req1);
            const body1 = try readBody(resp1);
            defer testing.allocator.free(body1);
            try testing.expectEqualStrings("first over tls", body1);
            resp1.deinit();

            const second_url = try lib.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/second", .{port});
            defer testing.allocator.free(second_url);
            var req2 = try Http.Request.init(testing.allocator, "GET", second_url);
            var resp2 = try transport.roundTrip(&req2);
            const tls_state2 = resp2.tls orelse return error.TestUnexpectedResult;
            try testing.expectEqual(@as(u16, @intFromEnum(Net.tls.ProtocolVersion.tls_1_3)), tls_state2.version);
            try testing.expect(tls_state2.cipher_suite != 0);
            const body2 = try readBody(resp2);
            defer testing.allocator.free(body2);
            try testing.expectEqualStrings("second over tls", body2);
            resp2.deinit();

            if (server_result) |err| return err;
            try testing.expect(state.reused);
            try testing.expectEqual(@as(usize, 1), state.accepted);
        }

        fn responseHeaderTimeoutExceeded() !void {
            var ln = try Net.tls.listen(testing.allocator, .{
                .address = addr4(0),
            }, tlsServerConfig());
            defer ln.deinit();

            const listener_impl = try ln.as(Net.tls.Listener);
            const port = try tlsListenerPort(ln, Net);
            var server_result: ?anyerror = null;

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
                    _ = readRequestHead(conn, &req_buf) catch |err| {
                        result.* = err;
                        return;
                    };
                    Thread.sleep(150 * lib.time.ns_per_ms);
                }
            }.run, .{ listener_impl, &server_result });
            defer server_thread.join();

            var options = tlsTransportOptions();
            options.response_header_timeout_ms = 20;
            var transport = try Http.Transport.init(testing.allocator, options);
            defer transport.deinit();

            const raw_url = try lib.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/slow-head", .{port});
            defer testing.allocator.free(raw_url);

            var req = try Http.Request.init(testing.allocator, "GET", raw_url);
            try testing.expectError(error.TimedOut, transport.roundTrip(&req));
            if (server_result) |err| return err;
        }

        fn maxConnsPerHostWaiterReusesReturnedIdleConn() !void {
            var state = ReuseState{};
            var ln = try Net.tls.listen(testing.allocator, .{
                .address = addr4(0),
            }, tlsServerConfig());
            defer ln.deinit();

            const listener_impl = try ln.as(Net.tls.Listener);
            const port = try tlsListenerPort(ln, Net);
            var server_result: ?anyerror = null;

            var server_thread = try Thread.spawn(test_spawn_config, struct {
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

                    _ = serveKeepAliveRequest(conn, "GET /cap-reuse-1 HTTP/1.1", "first over tls", false) catch |err| {
                        result.* = err;
                        return;
                    };

                    conn.setReadTimeout(200);
                    const reused = serveKeepAliveRequest(conn, "GET /cap-reuse-2 HTTP/1.1", "second over tls", true) catch |err| switch (err) {
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
            }.run, .{ listener_impl, &state, &server_result });
            defer server_thread.join();

            var transport = try Http.Transport.init(testing.allocator, .{
                .tls_client_config = tlsTransportOptions().tls_client_config,
                .max_conns_per_host = 1,
            });
            defer transport.deinit();

            const first_url = try lib.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/cap-reuse-1", .{port});
            defer testing.allocator.free(first_url);
            var req1 = try Http.Request.init(testing.allocator, "GET", first_url);
            var resp1 = try transport.roundTrip(&req1);
            defer resp1.deinit();
            const body1 = resp1.body() orelse return error.TestUnexpectedResult;
            var first: [1]u8 = undefined;
            try testing.expectEqual(@as(usize, 1), try body1.read(&first));

            const second_url = try lib.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/cap-reuse-2", .{port});
            defer testing.allocator.free(second_url);
            var req2 = try Http.Request.init(testing.allocator, "GET", second_url);
            var task = RoundTripTask{
                .transport = &transport,
                .req = &req2,
            };
            var thread = try Thread.spawn(test_spawn_config, RoundTripTask.run, .{&task});
            var joined = false;
            defer if (!joined) thread.join();

            try testing.expect(!task.waitTimeout(120));
            const rest = try readBody(resp1);
            defer testing.allocator.free(rest);
            thread.join();
            joined = true;

            if (task.err) |err| return err;
            var resp2 = task.resp orelse return error.TestUnexpectedResult;
            defer resp2.deinit();

            const body2 = try readBody(resp2);
            defer testing.allocator.free(body2);
            try testing.expectEqualStrings("second over tls", body2);
            if (server_result) |err| return err;
            try testing.expect(state.reused);
            try testing.expectEqual(@as(usize, 1), state.accepted);
        }

        fn http2AlternateTransportHandlesNegotiatedH2() !void {
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
                .address = addr4(0),
            }, tlsServerConfigWithAlpn(&.{ "h2" }));
            defer ln.deinit();

            const listener_impl = try ln.as(Net.tls.Listener);
            const port = try tlsListenerPort(ln, Net);
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
                .tls_client_config = tlsTransportOptions().tls_client_config,
                .force_attempt_http2 = true,
                .alternate_protocols = &alternates,
            });
            defer transport.deinit();

            const raw_url = try lib.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/hook-h2", .{port});
            defer testing.allocator.free(raw_url);

            var req = try Http.Request.init(testing.allocator, "GET", raw_url);
            var resp = try transport.roundTrip(&req);
            defer resp.deinit();

            const body = try readBody(resp);
            defer testing.allocator.free(body);
            try testing.expectEqualStrings("h2 via hook", body);
            try testing.expectEqual(@as(usize, 1), fake.round_trip_calls);

            transport.closeIdleConnections();
            try testing.expectEqual(@as(usize, 1), fake.close_idle_calls);
            if (server_result) |err| return err;
        }

        fn http2AlternateTransportIsOptIn() !void {
            const FakeH2Transport = struct {
                round_trip_calls: usize = 0,

                pub fn roundTrip(self: *@This(), _: *const Http.Request) !Http.Response {
                    self.round_trip_calls += 1;
                    return error.TestUnexpectedResult;
                }

                pub fn closeIdleConnections(_: *@This()) void {}
            };

            var ln = try Net.tls.listen(testing.allocator, .{
                .address = addr4(0),
            }, tlsServerConfigWithAlpn(&.{ "h2" }));
            defer ln.deinit();

            const listener_impl = try ln.as(Net.tls.Listener);
            const port = try tlsListenerPort(ln, Net);
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
                    const req_head = readRequestHead(conn, &req_buf) catch |err| {
                        result.* = err;
                        return;
                    };
                    if (!hasRequestLine(req_head, "GET /opt-in HTTP/1.1")) {
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
                .tls_client_config = tlsTransportOptions().tls_client_config,
                .alternate_protocols = &alternates,
            });
            defer transport.deinit();

            const raw_url = try lib.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/opt-in", .{port});
            defer testing.allocator.free(raw_url);

            var req = try Http.Request.init(testing.allocator, "GET", raw_url);
            var resp = try transport.roundTrip(&req);
            defer resp.deinit();

            const body = try readBody(resp);
            defer testing.allocator.free(body);
            try testing.expectEqualStrings("http1 fallback", body);
            try testing.expectEqual(@as(usize, 0), fake.round_trip_calls);
            if (server_result) |err| return err;
        }

        fn responseBodyReadCanceledByContext() !void {
            var ln = try Net.tls.listen(testing.allocator, .{
                .address = addr4(0),
            }, tlsServerConfig());
            defer ln.deinit();

            const listener_impl = try ln.as(Net.tls.Listener);
            const port = try tlsListenerPort(ln, Net);
            var server_result: ?anyerror = null;

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
                    const req_head = readRequestHead(conn, &req_buf) catch |err| {
                        result.* = err;
                        return;
                    };
                    if (!hasRequestLine(req_head, "GET /body-cancel HTTP/1.1")) {
                        result.* = error.TestUnexpectedResult;
                        return;
                    }

                    io.writeAll(
                        @TypeOf(conn),
                        &conn,
                        "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n",
                    ) catch |err| {
                        result.* = err;
                        return;
                    };
                    Thread.sleep(150 * lib.time.ns_per_ms);
                    io.writeAll(@TypeOf(conn), &conn, "late") catch {};
                }
            }.run, .{ listener_impl, &server_result });
            defer server_thread.join();

            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();
            var ctx = try ctx_api.withCancel(ctx_api.background());
            defer ctx.deinit();

            var transport = try Http.Transport.init(testing.allocator, tlsTransportOptions());
            defer transport.deinit();

            const raw_url = try lib.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/body-cancel", .{port});
            defer testing.allocator.free(raw_url);

            var req = try Http.Request.init(testing.allocator, "GET", raw_url);
            req = req.withContext(ctx);

            var resp = try transport.roundTrip(&req);
            defer resp.deinit();

            const cancel_thread = try Thread.spawn(test_spawn_config, struct {
                fn run(cancel_ctx: context_mod.Context, comptime thread_lib: type) void {
                    thread_lib.Thread.sleep(30 * thread_lib.time.ns_per_ms);
                    cancel_ctx.cancel();
                }
            }.run, .{ ctx, lib });
            defer cancel_thread.join();

            try testing.expectError(error.Canceled, readBody(resp));
            if (server_result) |err| return err;
        }

        fn httpsRoundTripViaConnectProxy() !void {
            var target_ln = try Net.tls.listen(testing.allocator, .{
                .address = addr4(0),
            }, tlsServerConfig());
            defer target_ln.deinit();
            const target_listener = try target_ln.as(Net.tls.Listener);
            const target_port = try tlsListenerPort(target_ln, Net);
            var target_result: ?anyerror = null;

            var target_thread = try Thread.spawn(test_spawn_config, struct {
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
                    const req_head = readRequestHead(conn, &req_buf) catch |err| {
                        result.* = err;
                        return;
                    };
                    if (!hasRequestLine(req_head, "GET /via-proxy HTTP/1.1")) {
                        result.* = error.TestUnexpectedResult;
                        return;
                    }

                    var head_buf: [256]u8 = undefined;
                    const body = "secure via proxy";
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
            }.run, .{ target_listener, &target_result });
            defer target_thread.join();

            var proxy_ln = try Net.listen(testing.allocator, .{ .address = addr4(0) });
            defer proxy_ln.deinit();
            const proxy_listener = try proxy_ln.as(Net.TcpListener);
            const proxy_port = try tcpListenerPort(proxy_ln, Net);
            var proxy_state = ProxyState{};
            var proxy_result: ?anyerror = null;

            var proxy_thread = try Thread.spawn(test_spawn_config, struct {
                fn run(
                    listener: *Net.TcpListener,
                    target_port_value: u16,
                    state: *ProxyState,
                    result: *?anyerror,
                ) void {
                    var conn = listener.accept() catch |err| {
                        result.* = err;
                        return;
                    };
                    defer conn.deinit();
                    state.accepted += 1;

                    var req_buf: [4096]u8 = undefined;
                    const req_head = readRequestHead(conn, &req_buf) catch |err| {
                        result.* = err;
                        return;
                    };
                    var line_buf: [64]u8 = undefined;
                    const expected = lib.fmt.bufPrint(&line_buf, "CONNECT 127.0.0.1:{d} HTTP/1.1", .{target_port_value}) catch {
                        result.* = error.TestUnexpectedResult;
                        return;
                    };
                    if (!hasRequestLine(req_head, expected)) {
                        result.* = error.TestUnexpectedResult;
                        return;
                    }
                    state.saw_header = lib.mem.eql(u8, headerValue(req_head, "X-Connect-Test") orelse "", "proxy-test");

                    var upstream = Net.dial(testing.allocator, .tcp, addr4(target_port_value)) catch |err| {
                        result.* = err;
                        return;
                    };
                    defer upstream.deinit();

                    io.writeAll(@TypeOf(conn), &conn, "HTTP/1.1 200 Connection established\r\nContent-Length: 0\r\n\r\n") catch |err| {
                        result.* = err;
                        return;
                    };
                    bridgeTunnel(conn, upstream) catch |err| {
                        result.* = err;
                    };
                }
            }.run, .{ proxy_listener, target_port, &proxy_state, &proxy_result });
            defer proxy_thread.join();

            const proxy_raw_url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}", .{proxy_port});
            defer testing.allocator.free(proxy_raw_url);
            const connect_headers = [_]Http.Header{
                Http.Header.init("X-Connect-Test", "proxy-test"),
            };
            var options = tlsTransportOptions();
            options.https_proxy = .{
                .url = try net_mod.url.parse(proxy_raw_url),
                .connect_headers = &connect_headers,
            };
            var transport = try Http.Transport.init(testing.allocator, options);
            defer transport.deinit();

            const raw_url = try lib.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/via-proxy", .{target_port});
            defer testing.allocator.free(raw_url);

            var req = try Http.Request.init(testing.allocator, "GET", raw_url);
            var resp = try transport.roundTrip(&req);
            defer resp.deinit();

            const body = try readBody(resp);
            defer testing.allocator.free(body);
            try testing.expectEqualStrings("secure via proxy", body);
            try testing.expectEqual(@as(usize, 1), proxy_state.accepted);
            try testing.expect(proxy_state.saw_header);
            if (proxy_result) |err| return err;
            if (target_result) |err| return err;
        }

        fn httpsConnectProxyInformationalThenTunnelSucceeds() !void {
            var target_ln = try Net.tls.listen(testing.allocator, .{
                .address = addr4(0),
            }, tlsServerConfig());
            defer target_ln.deinit();
            const target_listener = try target_ln.as(Net.tls.Listener);
            const target_port = try tlsListenerPort(target_ln, Net);
            var target_result: ?anyerror = null;

            var target_thread = try Thread.spawn(test_spawn_config, struct {
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
                    const req_head = readRequestHead(conn, &req_buf) catch |err| {
                        result.* = err;
                        return;
                    };
                    if (!hasRequestLine(req_head, "GET /via-proxy-100 HTTP/1.1")) {
                        result.* = error.TestUnexpectedResult;
                        return;
                    }

                    io.writeAll(@TypeOf(conn), &conn, "HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nthrough") catch |err| {
                        result.* = err;
                    };
                }
            }.run, .{ target_listener, &target_result });
            defer target_thread.join();

            var proxy_ln = try Net.listen(testing.allocator, .{ .address = addr4(0) });
            defer proxy_ln.deinit();
            const proxy_listener = try proxy_ln.as(Net.TcpListener);
            const proxy_port = try tcpListenerPort(proxy_ln, Net);
            var proxy_result: ?anyerror = null;

            var proxy_thread = try Thread.spawn(test_spawn_config, struct {
                fn run(listener: *Net.TcpListener, target_port_value: u16, result: *?anyerror) void {
                    var conn = listener.accept() catch |err| {
                        result.* = err;
                        return;
                    };
                    defer conn.deinit();

                    var req_buf: [4096]u8 = undefined;
                    const req_head = readRequestHead(conn, &req_buf) catch |err| {
                        result.* = err;
                        return;
                    };
                    var line_buf: [64]u8 = undefined;
                    const expected = lib.fmt.bufPrint(&line_buf, "CONNECT 127.0.0.1:{d} HTTP/1.1", .{target_port_value}) catch {
                        result.* = error.TestUnexpectedResult;
                        return;
                    };
                    if (!hasRequestLine(req_head, expected)) {
                        result.* = error.TestUnexpectedResult;
                        return;
                    }

                    var upstream = Net.dial(testing.allocator, .tcp, addr4(target_port_value)) catch |err| {
                        result.* = err;
                        return;
                    };
                    defer upstream.deinit();

                    io.writeAll(@TypeOf(conn), &conn, "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 Connection established\r\nContent-Length: 0\r\n\r\n") catch |err| {
                        result.* = err;
                        return;
                    };
                    bridgeTunnel(conn, upstream) catch |err| {
                        result.* = err;
                    };
                }
            }.run, .{ proxy_listener, target_port, &proxy_result });
            defer proxy_thread.join();

            const proxy_raw_url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}", .{proxy_port});
            defer testing.allocator.free(proxy_raw_url);
            var options = tlsTransportOptions();
            options.https_proxy = .{
                .url = try net_mod.url.parse(proxy_raw_url),
            };
            var transport = try Http.Transport.init(testing.allocator, options);
            defer transport.deinit();

            const raw_url = try lib.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/via-proxy-100", .{target_port});
            defer testing.allocator.free(raw_url);

            var req = try Http.Request.init(testing.allocator, "GET", raw_url);
            var resp = try transport.roundTrip(&req);
            defer resp.deinit();

            const body = try readBody(resp);
            defer testing.allocator.free(body);
            try testing.expectEqualStrings("through", body);
            if (proxy_result) |err| return err;
            if (target_result) |err| return err;
        }

        fn httpsConnectProxySuccessResponseWithBodyIsRejected() !void {
            var proxy_ln = try Net.listen(testing.allocator, .{ .address = addr4(0) });
            defer proxy_ln.deinit();
            const proxy_listener = try proxy_ln.as(Net.TcpListener);
            const proxy_port = try tcpListenerPort(proxy_ln, Net);
            var proxy_result: ?anyerror = null;

            var proxy_thread = try Thread.spawn(test_spawn_config, struct {
                fn run(listener: *Net.TcpListener, result: *?anyerror) void {
                    var conn = listener.accept() catch |err| {
                        result.* = err;
                        return;
                    };
                    defer conn.deinit();

                    var req_buf: [4096]u8 = undefined;
                    const req_head = readRequestHead(conn, &req_buf) catch |err| {
                        result.* = err;
                        return;
                    };
                    if (!hasRequestLine(req_head, "CONNECT example.com:443 HTTP/1.1")) {
                        result.* = error.TestUnexpectedResult;
                        return;
                    }

                    io.writeAll(@TypeOf(conn), &conn, "HTTP/1.1 200 Connection established\r\nContent-Length: 4\r\nConnection: close\r\n\r\nnope") catch |err| {
                        result.* = err;
                    };
                }
            }.run, .{ proxy_listener, &proxy_result });
            defer proxy_thread.join();

            const proxy_raw_url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}", .{proxy_port});
            defer testing.allocator.free(proxy_raw_url);
            var options = tlsTransportOptions();
            options.https_proxy = .{
                .url = try net_mod.url.parse(proxy_raw_url),
            };
            var transport = try Http.Transport.init(testing.allocator, options);
            defer transport.deinit();

            var req = try Http.Request.init(testing.allocator, "GET", "https://example.com/invalid-connect-success");
            try testing.expectError(error.InvalidResponse, transport.roundTrip(&req));
            if (proxy_result) |err| return err;
        }

        fn httpsConnectProxySuccessResponseWithChunkedBodyIsRejected() !void {
            var proxy_ln = try Net.listen(testing.allocator, .{ .address = addr4(0) });
            defer proxy_ln.deinit();
            const proxy_listener = try proxy_ln.as(Net.TcpListener);
            const proxy_port = try tcpListenerPort(proxy_ln, Net);
            var proxy_result: ?anyerror = null;

            var proxy_thread = try Thread.spawn(test_spawn_config, struct {
                fn run(listener: *Net.TcpListener, result: *?anyerror) void {
                    var conn = listener.accept() catch |err| {
                        result.* = err;
                        return;
                    };
                    defer conn.deinit();

                    var req_buf: [4096]u8 = undefined;
                    const req_head = readRequestHead(conn, &req_buf) catch |err| {
                        result.* = err;
                        return;
                    };
                    if (!hasRequestLine(req_head, "CONNECT example.com:443 HTTP/1.1")) {
                        result.* = error.TestUnexpectedResult;
                        return;
                    }

                    io.writeAll(@TypeOf(conn), &conn, "HTTP/1.1 200 Connection established\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n4\r\nnope\r\n0\r\n\r\n") catch |err| {
                        result.* = err;
                    };
                }
            }.run, .{ proxy_listener, &proxy_result });
            defer proxy_thread.join();

            const proxy_raw_url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}", .{proxy_port});
            defer testing.allocator.free(proxy_raw_url);
            var options = tlsTransportOptions();
            options.https_proxy = .{
                .url = try net_mod.url.parse(proxy_raw_url),
            };
            var transport = try Http.Transport.init(testing.allocator, options);
            defer transport.deinit();

            var req = try Http.Request.init(testing.allocator, "GET", "https://example.com/invalid-connect-chunked");
            try testing.expectError(error.InvalidResponse, transport.roundTrip(&req));
            if (proxy_result) |err| return err;
        }

        fn httpsConnectProxyAuthConnectionIsReused() !void {
            const ProxyAuthState = struct {
                accepted: usize = 0,
                saw_auth: bool = false,
            };

            var target_state = ReuseState{};
            var target_ln = try Net.tls.listen(testing.allocator, .{
                .address = addr4(0),
            }, tlsServerConfig());
            defer target_ln.deinit();
            const target_listener = try target_ln.as(Net.tls.Listener);
            const target_port = try tlsListenerPort(target_ln, Net);
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

                    _ = serveKeepAliveRequest(conn, "GET /auth-first HTTP/1.1", "first via auth proxy", false) catch |err| {
                        result.* = err;
                        return;
                    };

                    conn.setReadTimeout(200);
                    const reused = serveKeepAliveRequest(conn, "GET /auth-second HTTP/1.1", "second via auth proxy", true) catch |err| switch (err) {
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

            var proxy_ln = try Net.listen(testing.allocator, .{ .address = addr4(0) });
            defer proxy_ln.deinit();
            const proxy_listener = try proxy_ln.as(Net.TcpListener);
            const proxy_port = try tcpListenerPort(proxy_ln, Net);
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
                    const req_head = readRequestHead(conn, &req_buf) catch |err| {
                        result.* = err;
                        return;
                    };
                    var line_buf: [64]u8 = undefined;
                    const expected = lib.fmt.bufPrint(&line_buf, "CONNECT 127.0.0.1:{d} HTTP/1.1", .{target_port_value}) catch {
                        result.* = error.TestUnexpectedResult;
                        return;
                    };
                    if (!hasRequestLine(req_head, expected)) {
                        result.* = error.TestUnexpectedResult;
                        return;
                    }
                    state.saw_auth = lib.mem.eql(u8, headerValue(req_head, Http.Header.proxy_authorization) orelse "", "Basic dXNlcjpwYXNz");

                    var upstream = Net.dial(testing.allocator, .tcp, addr4(target_port_value)) catch |err| {
                        result.* = err;
                        return;
                    };
                    defer upstream.deinit();

                    io.writeAll(@TypeOf(conn), &conn, "HTTP/1.1 200 Connection established\r\nContent-Length: 0\r\n\r\n") catch |err| {
                        result.* = err;
                        return;
                    };
                    bridgeTunnel(conn, upstream) catch |err| {
                        result.* = err;
                    };
                }
            }.run, .{ proxy_listener, target_port, &proxy_state, &proxy_result });
            defer proxy_thread.join();

            const proxy_raw_url = try lib.fmt.allocPrint(testing.allocator, "http://user:pass@127.0.0.1:{d}", .{proxy_port});
            defer testing.allocator.free(proxy_raw_url);
            var options = tlsTransportOptions();
            options.https_proxy = .{
                .url = try net_mod.url.parse(proxy_raw_url),
            };
            var transport = try Http.Transport.init(testing.allocator, options);
            defer transport.deinit();

            const first_url = try lib.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/auth-first", .{target_port});
            defer testing.allocator.free(first_url);
            var req1 = try Http.Request.init(testing.allocator, "GET", first_url);
            var resp1 = try transport.roundTrip(&req1);
            const body1 = try readBody(resp1);
            defer testing.allocator.free(body1);
            try testing.expectEqualStrings("first via auth proxy", body1);
            resp1.deinit();

            const second_url = try lib.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/auth-second", .{target_port});
            defer testing.allocator.free(second_url);
            var req2 = try Http.Request.init(testing.allocator, "GET", second_url);
            var resp2 = try transport.roundTrip(&req2);
            const body2 = try readBody(resp2);
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

        fn httpsConnectProxyConnectionIsReused() !void {
            var target_state = ReuseState{};
            var target_ln = try Net.tls.listen(testing.allocator, .{
                .address = addr4(0),
            }, tlsServerConfig());
            defer target_ln.deinit();
            const target_listener = try target_ln.as(Net.tls.Listener);
            const target_port = try tlsListenerPort(target_ln, Net);
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

                    _ = serveKeepAliveRequest(conn, "GET /first HTTP/1.1", "first via proxy", false) catch |err| {
                        result.* = err;
                        return;
                    };

                    conn.setReadTimeout(200);
                    const reused = serveKeepAliveRequest(conn, "GET /second HTTP/1.1", "second via proxy", true) catch |err| switch (err) {
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

            var proxy_ln = try Net.listen(testing.allocator, .{ .address = addr4(0) });
            defer proxy_ln.deinit();
            const proxy_listener = try proxy_ln.as(Net.TcpListener);
            const proxy_port = try tcpListenerPort(proxy_ln, Net);
            var proxy_state = ProxyState{};
            var proxy_result: ?anyerror = null;

            var proxy_thread = try Thread.spawn(test_spawn_config, struct {
                fn run(
                    listener: *Net.TcpListener,
                    target_port_value: u16,
                    state: *ProxyState,
                    result: *?anyerror,
                ) void {
                    var conn = listener.accept() catch |err| {
                        result.* = err;
                        return;
                    };
                    defer conn.deinit();
                    state.accepted += 1;

                    var req_buf: [4096]u8 = undefined;
                    const req_head = readRequestHead(conn, &req_buf) catch |err| {
                        result.* = err;
                        return;
                    };
                    var line_buf: [64]u8 = undefined;
                    const expected = lib.fmt.bufPrint(&line_buf, "CONNECT 127.0.0.1:{d} HTTP/1.1", .{target_port_value}) catch {
                        result.* = error.TestUnexpectedResult;
                        return;
                    };
                    if (!hasRequestLine(req_head, expected)) {
                        result.* = error.TestUnexpectedResult;
                        return;
                    }

                    var upstream = Net.dial(testing.allocator, .tcp, addr4(target_port_value)) catch |err| {
                        result.* = err;
                        return;
                    };
                    defer upstream.deinit();

                    io.writeAll(@TypeOf(conn), &conn, "HTTP/1.1 200 Connection established\r\nContent-Length: 0\r\n\r\n") catch |err| {
                        result.* = err;
                        return;
                    };
                    bridgeTunnel(conn, upstream) catch |err| {
                        result.* = err;
                    };
                }
            }.run, .{ proxy_listener, target_port, &proxy_state, &proxy_result });
            defer proxy_thread.join();

            const proxy_raw_url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}", .{proxy_port});
            defer testing.allocator.free(proxy_raw_url);
            var options = tlsTransportOptions();
            options.https_proxy = .{
                .url = try net_mod.url.parse(proxy_raw_url),
            };
            var transport = try Http.Transport.init(testing.allocator, options);
            defer transport.deinit();

            const first_url = try lib.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/first", .{target_port});
            defer testing.allocator.free(first_url);
            var req1 = try Http.Request.init(testing.allocator, "GET", first_url);
            var resp1 = try transport.roundTrip(&req1);
            const body1 = try readBody(resp1);
            defer testing.allocator.free(body1);
            try testing.expectEqualStrings("first via proxy", body1);
            resp1.deinit();

            const second_url = try lib.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/second", .{target_port});
            defer testing.allocator.free(second_url);
            var req2 = try Http.Request.init(testing.allocator, "GET", second_url);
            var resp2 = try transport.roundTrip(&req2);
            const body2 = try readBody(resp2);
            defer testing.allocator.free(body2);
            try testing.expectEqualStrings("second via proxy", body2);
            resp2.deinit();

            try testing.expectEqual(@as(usize, 1), proxy_state.accepted);
            try testing.expect(target_state.reused);
            try testing.expectEqual(@as(usize, 1), target_state.accepted);
            if (proxy_result) |err| return err;
            if (target_result) |err| return err;
        }

        fn directHttpsWithoutProxyBypassesConnectProxy() !void {
            const ProxyProbeState = struct {
                saw_connect: bool = false,
                saw_probe: bool = false,
            };

            var target_ln = try Net.tls.listen(testing.allocator, .{
                .address = addr4(0),
            }, tlsServerConfig());
            defer target_ln.deinit();
            const target_listener = try target_ln.as(Net.tls.Listener);
            const target_port = try tlsListenerPort(target_ln, Net);
            var target_result: ?anyerror = null;

            var target_thread = try Thread.spawn(test_spawn_config, struct {
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
                    const req_head = readRequestHead(conn, &req_buf) catch |err| {
                        result.* = err;
                        return;
                    };
                    if (!hasRequestLine(req_head, "GET /direct HTTP/1.1")) {
                        result.* = error.TestUnexpectedResult;
                        return;
                    }

                    io.writeAll(@TypeOf(conn), &conn, "HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\ndirect") catch |err| {
                        result.* = err;
                    };
                }
            }.run, .{ target_listener, &target_result });
            defer target_thread.join();

            var proxy_state = ProxyProbeState{};
            var proxy_ln: net_mod.Listener = undefined;
            var proxy_port: u16 = undefined;
            var proxy_thread: Thread = undefined;
            var proxy_cleaned = false;
            {
                var proxy_ln_local = try Net.listen(testing.allocator, .{ .address = addr4(0) });
                errdefer proxy_ln_local.deinit();
                const proxy_listener = try proxy_ln_local.as(Net.TcpListener);
                proxy_port = try tcpListenerPort(proxy_ln_local, Net);
                proxy_thread = try Thread.spawn(test_spawn_config, struct {
                    fn run(listener: *Net.TcpListener, state: *ProxyProbeState) void {
                        var conn = listener.accept() catch return;
                        defer conn.deinit();
                        conn.setReadTimeout(200);
                        var buf: [64]u8 = undefined;
                        const n = conn.read(&buf) catch return;
                        if (n == 0) return;
                        if (lib.mem.startsWith(u8, buf[0..n], "PING")) {
                            state.saw_probe = true;
                            return;
                        }
                        if (lib.mem.indexOf(u8, buf[0..n], "CONNECT ") != null) {
                            state.saw_connect = true;
                        }
                    }
                }.run, .{ proxy_listener, &proxy_state });
                proxy_ln = proxy_ln_local;
            }
            defer if (!proxy_cleaned) {
                proxy_ln.close();
                proxy_thread.join();
                proxy_ln.deinit();
            };

            var transport = try Http.Transport.init(testing.allocator, tlsTransportOptions());
            defer transport.deinit();

            const raw_url = try lib.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/direct", .{target_port});
            defer testing.allocator.free(raw_url);

            var req = try Http.Request.init(testing.allocator, "GET", raw_url);
            var resp = try transport.roundTrip(&req);
            defer resp.deinit();

            const body = try readBody(resp);
            defer testing.allocator.free(body);
            try testing.expectEqualStrings("direct", body);

            var probe = try Net.dial(testing.allocator, .tcp, addr4(proxy_port));
            try io.writeAll(@TypeOf(probe), &probe, "PING");
            probe.deinit();

            proxy_thread.join();
            proxy_ln.deinit();
            proxy_cleaned = true;

            try testing.expect(proxy_state.saw_probe);
            try testing.expect(!proxy_state.saw_connect);
            if (target_result) |err| return err;
        }

        fn tlsHandshakeTimeoutExceeded() !void {
            var ln = try Net.listen(testing.allocator, .{
                .address = addr4(0),
            });
            defer ln.deinit();

            const listener_impl = try ln.as(Net.TcpListener);
            const port = try listener_impl.port();
            var server_thread = try Thread.spawn(test_spawn_config, struct {
                fn run(listener: *Net.TcpListener) void {
                    var conn = listener.accept() catch return;
                    defer conn.deinit();
                    Thread.sleep(300 * lib.time.ns_per_ms);
                }
            }.run, .{listener_impl});
            defer server_thread.join();

            var transport = try Http.Transport.init(testing.allocator, .{
                .tls_client_config = .{
                    .server_name = "example.com",
                    .verification = .no_verification,
                },
                .tls_handshake_timeout_ms = 100,
            });
            defer transport.deinit();

            const raw_url = try lib.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/stall", .{port});
            defer testing.allocator.free(raw_url);

            var req = try Http.Request.init(testing.allocator, "GET", raw_url);
            try testing.expectError(error.TimedOut, transport.roundTrip(&req));
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

        fn tlsServerConfigWithAlpn(protocols: []const []const u8) Net.tls.ServerConfig {
            var config = tlsServerConfig();
            config.alpn_protocols = protocols;
            return config;
        }

        fn tcpListenerPort(ln: net_mod.Listener, comptime NetNs: type) !u16 {
            const listener = try ln.as(NetNs.TcpListener);
            return listener.port();
        }

        fn tlsListenerPort(ln: net_mod.Listener, comptime NetNs: type) !u16 {
            const tls_listener = try ln.as(NetNs.tls.Listener);
            const tcp_impl = try tls_listener.inner.as(NetNs.TcpListener);
            return tcp_impl.port();
        }

        fn bridgeTunnel(client: net_mod.Conn, upstream: net_mod.Conn) !void {
            var slot = BridgeErrorSlot{};
            var stop = BridgeStopFlag{};
            const upstream_thread = try Thread.spawn(test_spawn_config, struct {
                fn run(src: net_mod.Conn, dst: net_mod.Conn, err_slot: *BridgeErrorSlot, stop_flag: *BridgeStopFlag) void {
                    bridgeOneWay(src, dst, err_slot, stop_flag);
                }
            }.run, .{ client, upstream, &slot, &stop });
            defer upstream_thread.join();

            bridgeOneWay(upstream, client, &slot, &stop);
            stop.signal();
            if (slot.load()) |err| return err;
        }

        fn bridgeOneWay(src: net_mod.Conn, dst: net_mod.Conn, err_slot: *BridgeErrorSlot, stop_flag: *BridgeStopFlag) void {
            var reader = src;
            var writer = dst;
            reader.setReadTimeout(250);

            var buf: [2048]u8 = undefined;
            while (true) {
                const n = reader.read(&buf) catch |err| switch (err) {
                    error.EndOfStream,
                    error.ConnectionReset,
                    => {
                        stop_flag.signal();
                        return;
                    },
                    error.TimedOut => {
                        if (stop_flag.load()) return;
                        continue;
                    },
                    else => {
                        err_slot.store(err);
                        stop_flag.signal();
                        return;
                    },
                };
                if (n == 0) {
                    stop_flag.signal();
                    return;
                }
                io.writeAll(@TypeOf(writer), &writer, buf[0..n]) catch |err| switch (err) {
                    error.BrokenPipe,
                    error.ConnectionReset,
                    => {
                        stop_flag.signal();
                        return;
                    },
                    else => {
                        err_slot.store(err);
                        stop_flag.signal();
                        return;
                    },
                };
            }
        }

        fn serveKeepAliveRequest(conn: net_mod.Conn, expected_request_line: []const u8, body: []const u8, close_conn: bool) !bool {
            var c = conn;
            var req_buf: [4096]u8 = undefined;
            const req_head = try readRequestHead(conn, &req_buf);
            if (req_head.len == 0) return error.EndOfStream;
            try testing.expect(hasRequestLine(req_head, expected_request_line));

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

        fn readRequestHead(conn: net_mod.Conn, buf: *[4096]u8) ![]const u8 {
            var filled: usize = 0;
            while (filled < buf.len) {
                const n = try conn.read(buf[filled..]);
                if (n == 0) break;
                filled += n;
                if (lib.mem.indexOf(u8, buf[0..filled], "\r\n\r\n") != null) break;
            }
            return buf[0..filled];
        }

        fn hasRequestLine(req_head: []const u8, expected: []const u8) bool {
            const line_end = lib.mem.indexOf(u8, req_head, "\r\n") orelse req_head.len;
            return lib.mem.eql(u8, req_head[0..line_end], expected);
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
    };

    try Runner.selfSignedRoundTrip();
    try Runner.idleConnectionIsReused();
    try Runner.responseHeaderTimeoutExceeded();
    try Runner.maxConnsPerHostWaiterReusesReturnedIdleConn();
    try Runner.http2AlternateTransportHandlesNegotiatedH2();
    try Runner.http2AlternateTransportIsOptIn();
    try Runner.responseBodyReadCanceledByContext();
    try Runner.httpsRoundTripViaConnectProxy();
    try Runner.httpsConnectProxyInformationalThenTunnelSucceeds();
    try Runner.httpsConnectProxySuccessResponseWithBodyIsRejected();
    try Runner.httpsConnectProxySuccessResponseWithChunkedBodyIsRejected();
    try Runner.httpsConnectProxyAuthConnectionIsReused();
    try Runner.httpsConnectProxyConnectionIsReused();
    try Runner.directHttpsWithoutProxyBypassesConnectProxy();
    try Runner.tlsHandshakeTimeoutExceeded();
}
