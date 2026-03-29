//! HTTPS transport test runner — local and public-network integration tests.
//!
//! Covers:
//! - direct HTTPS round trips over a self-signed local listener
//! - idle HTTPS connection reuse after the response body is fully drained
//! - TLS handshake timeout enforcement
//! - public AliDNS DoH endpoint reachability over HTTPS

const embed = @import("embed");
const io = @import("io");
const net_mod = @import("../../net.zig");
const context_mod = @import("context");
const fixtures = @import("../tls/test_fixtures.zig");
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
            const body2 = try readBody(resp2);
            defer testing.allocator.free(body2);
            try testing.expectEqualStrings("second over tls", body2);
            resp2.deinit();

            if (server_result) |err| return err;
            try testing.expect(state.reused);
            try testing.expectEqual(@as(usize, 1), state.accepted);
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

        fn publicAliDnsDoh() !void {
            var transport = try Http.Transport.init(testing.allocator, .{});
            defer transport.deinit();

            var ctx_api = try Context.init(testing.allocator);
            defer ctx_api.deinit();
            var timeout_ctx = try ctx_api.withTimeout(ctx_api.background(), 5000 * lib.time.ns_per_ms);
            defer timeout_ctx.deinit();

            var req = try Http.Request.init(
                testing.allocator,
                "GET",
                "https://dns.alidns.com/resolve?name=dns.alidns.com&type=A",
            );
            const headers = [_]Http.Header{
                Http.Header.init(Http.Header.accept, "application/dns-json"),
            };
            req.header = &headers;
            req = req.withContext(timeout_ctx);

            var resp = try transport.roundTrip(&req);
            defer resp.deinit();

            try testing.expect(resp.status_code == Http.status.ok or resp.status_code == Http.status.unauthorized);

            const body = try readBody(resp);
            defer testing.allocator.free(body);

            if (resp.status_code == Http.status.ok) {
                try testing.expect(body.len != 0);
            } else {
                try testing.expectEqual(Http.status.unauthorized, resp.status_code);
                try testing.expect(lib.mem.indexOf(u8, body, "NoPermission") != null);
            }
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

        fn tlsListenerPort(ln: net_mod.Listener, comptime NetNs: type) !u16 {
            const tls_listener = try ln.as(NetNs.tls.Listener);
            const tcp_impl = try tls_listener.inner.as(NetNs.TcpListener);
            return tcp_impl.port();
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
    try Runner.tlsHandshakeTimeoutExceeded();
    try Runner.publicAliDnsDoh();
}
