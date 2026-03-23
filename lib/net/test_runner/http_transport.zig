//! HTTP transport test runner — local and public-network integration tests.
//!
//! Covers:
//! - local HTTP/1.1 round trips for 200 and 404 responses
//! - context timeout propagation as `context.err()`
//! - public AliDNS DoH endpoint reachability over plain HTTP
//!
//! Usage:
//!   try @import("net/test_runner/http_transport.zig").run(lib);

const io = @import("io");
const net_mod = @import("../../net.zig");
const context_mod = @import("context");

pub fn run(comptime lib: type) !void {
    try runImpl(lib, .full);
}

pub fn runLocal(comptime lib: type) !void {
    try runImpl(lib, .local);
}

pub fn runLayer01Local(comptime lib: type) !void {
    try runImpl(lib, .layer01);
}

fn runImpl(comptime lib: type, comptime suite: enum { full, local, layer01 }) !void {
    const Net = net_mod.Make(lib);
    const Http = Net.http;
    const Addr = lib.net.Address;
    const testing = lib.testing;
    const log = lib.log.scoped(.http_transport);

    const ServerSpec = struct {
        expected_request_line: []const u8,
        expected_request_body: ?[]const u8 = null,
        status_code: u16,
        body: []const u8,
        content_type: []const u8 = "text/plain",
        delay_ms: u32 = 0,
    };

    const TwoRequestSpec = struct {
        first_request_line: []const u8,
        second_request_line: []const u8,
        first_body: []const u8,
        second_body: []const u8,
        reuse_wait_timeout_ms: u32 = 100,
    };

    const StaleIdleRetrySpec = struct {
        warmup_request_line: []const u8,
        warmup_body: []const u8,
        retry_request_line: []const u8,
        retry_request_body: ?[]const u8 = null,
        retry_response_body: []const u8,
    };

    const RequestBodyMatch = enum {
        ok,
        missing_header_terminator,
        missing_content_length,
        invalid_content_length,
        content_length_mismatch,
        prefix_too_large,
        prefix_mismatch,
        stream_mismatch,
        read_error,
    };

    const Runner = struct {
        const Mutex = lib.Thread.Mutex;
        const Condition = lib.Thread.Condition;
        const EmptyState = struct {};

        const Gate = struct {
            mutex: Mutex = .{},
            cond: Condition = .{},
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

        const ChunkedBodySource = struct {
            chunks: []const []const u8,
            index: usize = 0,

            pub fn read(self: *@This(), buf: []u8) anyerror!usize {
                if (self.index >= self.chunks.len) return 0;
                const chunk = self.chunks[self.index];
                self.index += 1;
                @memcpy(buf[0..chunk.len], chunk);
                return chunk.len;
            }

            pub fn close(_: *@This()) void {}
        };

        const PhasedBodySource = struct {
            first: []const u8,
            second: []const u8,
            mutex: Mutex = .{},
            cond: Condition = .{},
            first_sent: bool = false,
            second_released: bool = false,
            closed: bool = false,
            stage: enum {
                first,
                wait_second,
                second,
                done,
            } = .first,

            pub fn read(self: *@This(), buf: []u8) anyerror!usize {
                self.mutex.lock();
                defer self.mutex.unlock();

                while (true) switch (self.stage) {
                    .first => {
                        @memcpy(buf[0..self.first.len], self.first);
                        self.first_sent = true;
                        self.stage = .wait_second;
                        self.cond.broadcast();
                        return self.first.len;
                    },
                    .wait_second => {
                        while (!self.second_released and !self.closed) self.cond.wait(&self.mutex);
                        if (self.closed) {
                            self.stage = .done;
                            return 0;
                        }
                        self.stage = .second;
                    },
                    .second => {
                        @memcpy(buf[0..self.second.len], self.second);
                        self.stage = .done;
                        return self.second.len;
                    },
                    .done => return 0,
                };
            }

            pub fn close(self: *@This()) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.closed = true;
                self.cond.broadcast();
            }

            fn waitUntilFirstSent(self: *@This()) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                while (!self.first_sent) self.cond.wait(&self.mutex);
            }

            fn releaseSecond(self: *@This()) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.second_released = true;
                self.cond.broadcast();
            }
        };

        const BlockingBodySource = struct {
            mutex: Mutex = .{},
            cond: Condition = .{},
            closed: bool = false,

            pub fn read(self: *@This(), _: []u8) anyerror!usize {
                self.mutex.lock();
                defer self.mutex.unlock();
                while (!self.closed) self.cond.wait(&self.mutex);
                return 0;
            }

            pub fn close(self: *@This()) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.closed = true;
                self.cond.broadcast();
            }
        };

        const OwnedBodySource = struct {
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

        const ReplayBodyFactory = struct {
            payload: []const u8,
            calls: usize = 0,

            pub fn getBody(self: *@This()) anyerror!Http.ReadCloser {
                self.calls += 1;
                const body = try testing.allocator.create(OwnedBodySource);
                body.* = .{ .payload = self.payload };
                return Http.ReadCloser.init(body);
            }
        };

        const RoundTripTask = struct {
            transport: *Http.Transport,
            req: *Http.Request,
            resp: ?Http.Response = null,
            err: ?anyerror = null,

            fn run(self: *@This()) void {
                self.resp = self.transport.roundTrip(self.req) catch |err| {
                    self.err = err;
                    return;
                };
            }
        };

        fn listenerPort(ln: net_mod.Listener, comptime NetNs: type) !u16 {
            const typed = try ln.as(NetNs.TcpListener);
            return typed.port();
        }

        fn localReturns200() !void {
            try withOneShotServer(.{
                .expected_request_line = "GET /ok HTTP/1.1",
                .status_code = Http.status.ok,
                .body = "ok",
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{});
                    defer transport.deinit();

                    const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/ok", .{port});
                    defer testing.allocator.free(url);

                    var req = try Http.Request.init(testing.allocator, "GET", url);
                    var resp = try transport.roundTrip(&req);
                    defer resp.deinit();

                    try testing.expectEqual(Http.status.ok, resp.status_code);
                    try testing.expect(resp.ok());
                    try testing.expectEqualStrings("200 OK", resp.status);

                    const body = try readBody(resp);
                    defer testing.allocator.free(body);
                    try testing.expectEqualStrings("ok", body);
                }
            }.run);
        }

        fn localReturns404() !void {
            try withOneShotServer(.{
                .expected_request_line = "GET /missing HTTP/1.1",
                .status_code = Http.status.not_found,
                .body = "missing",
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{});
                    defer transport.deinit();

                    const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/missing", .{port});
                    defer testing.allocator.free(url);

                    var req = try Http.Request.init(testing.allocator, "GET", url);
                    var resp = try transport.roundTrip(&req);
                    defer resp.deinit();

                    try testing.expectEqual(Http.status.not_found, resp.status_code);
                    try testing.expect(!resp.ok());
                    try testing.expectEqualStrings("404 Not Found", resp.status);

                    const body = try readBody(resp);
                    defer testing.allocator.free(body);
                    try testing.expectEqualStrings("missing", body);
                }
            }.run);
        }

        fn defaultUserAgentMatchesGo() !void {
            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "GET /user-agent-default HTTP/1.1"));
                        try testing.expectEqualStrings("Go-http-client/1.1", headerValue(req_head, Http.Header.user_agent) orelse "");
                        io.writeAll(@TypeOf(c), &c, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok") catch {};
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *EmptyState) !void {
                        var transport = try Http.Transport.init(testing.allocator, .{});
                        defer transport.deinit();

                        const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/user-agent-default", .{port});
                        defer testing.allocator.free(url);

                        var req = try Http.Request.init(testing.allocator, "GET", url);
                        var resp = try transport.roundTrip(&req);
                        defer resp.deinit();

                        const body = try readBody(resp);
                        defer testing.allocator.free(body);
                        try testing.expectEqualStrings("ok", body);
                    }
                }.run,
            );
        }

        fn emptyUserAgentSuppressesDefault() !void {
            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "GET /user-agent-empty HTTP/1.1"));
                        try testing.expect(headerValue(req_head, Http.Header.user_agent) == null);
                        io.writeAll(@TypeOf(c), &c, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok") catch {};
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *EmptyState) !void {
                        var transport = try Http.Transport.init(testing.allocator, .{});
                        defer transport.deinit();

                        const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/user-agent-empty", .{port});
                        defer testing.allocator.free(url);

                        const headers = [_]Http.Header{
                            Http.Header.init(Http.Header.user_agent, ""),
                        };
                        var req = try Http.Request.init(testing.allocator, "GET", url);
                        req.header = &headers;

                        var resp = try transport.roundTrip(&req);
                        defer resp.deinit();

                        const body = try readBody(resp);
                        defer testing.allocator.free(body);
                        try testing.expectEqualStrings("ok", body);
                    }
                }.run,
            );
        }

        fn contextDeadlineExceeded() !void {
            try withOneShotServer(.{
                .expected_request_line = "GET /slow HTTP/1.1",
                .status_code = Http.status.ok,
                .body = "slow",
                .delay_ms = 150,
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{});
                    defer transport.deinit();

                    const Context = context_mod.Make(lib);
                    var ctx_api = try Context.init(testing.allocator);
                    defer ctx_api.deinit();
                    var timeout_ctx = try ctx_api.withTimeout(ctx_api.background(), 30);
                    defer timeout_ctx.deinit();

                    const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/slow", .{port});
                    defer testing.allocator.free(url);

                    var req = try Http.Request.init(testing.allocator, "GET", url);
                    req = req.withContext(timeout_ctx);

                    try testing.expectError(error.DeadlineExceeded, transport.roundTrip(&req));
                }
            }.run);
        }

        fn responseHeaderTimeoutExceeded() !void {
            try withOneShotServer(.{
                .expected_request_line = "GET /header-timeout HTTP/1.1",
                .status_code = Http.status.ok,
                .body = "slow",
                .delay_ms = 80,
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{
                        .response_header_timeout_ms = 20,
                    });
                    defer transport.deinit();

                    const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/header-timeout", .{port});
                    defer testing.allocator.free(url);

                    var req = try Http.Request.init(testing.allocator, "GET", url);
                    try testing.expectError(error.TimedOut, transport.roundTrip(&req));
                }
            }.run);
        }

        fn responseHeaderTimeoutDoesNotLimitBodyRead() !void {
            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "GET /header-timeout-body HTTP/1.1"));

                        io.writeAll(
                            @TypeOf(c),
                            &c,
                            "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\n",
                        ) catch {};
                        lib.Thread.sleep(50 * lib.time.ns_per_ms);
                        io.writeAll(@TypeOf(c), &c, "hello") catch {};
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *EmptyState) !void {
                        var transport = try Http.Transport.init(testing.allocator, .{
                            .response_header_timeout_ms = 10,
                        });
                        defer transport.deinit();

                        const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/header-timeout-body", .{port});
                        defer testing.allocator.free(url);

                        var req = try Http.Request.init(testing.allocator, "GET", url);
                        var resp = try transport.roundTrip(&req);
                        defer resp.deinit();

                        const body = try readBody(resp);
                        defer testing.allocator.free(body);
                        try testing.expectEqualStrings("hello", body);
                    }
                }.run,
            );
        }

        fn publicAliDnsDoh() !void {
            var transport = try Http.Transport.init(testing.allocator, .{});
            defer transport.deinit();

            var req = try Http.Request.init(
                testing.allocator,
                "GET",
                "http://public.alidns.com/resolve?name=public.alidns.com&type=A",
            );
            const headers = [_]Http.Header{
                Http.Header.init(Http.Header.accept, "application/dns-json"),
            };
            req.header = &headers;

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

        fn responseBodyLargerThanMaxBodyBytesFails() !void {
            const payload = [_]u8{'r'} ** 8192;

            try withOneShotServer(.{
                .expected_request_line = "GET /response-limit HTTP/1.1",
                .status_code = Http.status.ok,
                .body = &payload,
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{ .max_body_bytes = 16 });
                    defer transport.deinit();

                    const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/response-limit", .{port});
                    defer testing.allocator.free(url);

                    var req = try Http.Request.init(testing.allocator, "GET", url);
                    try testing.expectError(error.BodyTooLarge, transport.roundTrip(&req));
                }
            }.run);
        }

        fn defaultMaxHeaderBytesAllowsLargeResponseHeaders() !void {
            const State = struct {
                fill: []u8,
            };

            const fill = try testing.allocator.alloc(u8, 32 * 1024);
            defer testing.allocator.free(fill);
            @memset(fill, 'h');

            try withServerState(
                State{ .fill = fill },
                struct {
                    fn run(conn: net_mod.Conn, state: *State) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "GET /large-header-default HTTP/1.1"));

                        var head = try lib.ArrayList(u8).initCapacity(testing.allocator, 0);
                        defer head.deinit(testing.allocator);
                        try head.appendSlice(testing.allocator, "HTTP/1.1 200 OK\r\nX-Fill: ");
                        try head.appendSlice(testing.allocator, state.fill);
                        try head.appendSlice(testing.allocator, "\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
                        try io.writeAll(@TypeOf(c), &c, head.items);
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *State) !void {
                        var transport = try Http.Transport.init(testing.allocator, .{});
                        defer transport.deinit();

                        const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/large-header-default", .{port});
                        defer testing.allocator.free(url);

                        var req = try Http.Request.init(testing.allocator, "GET", url);
                        var resp = try transport.roundTrip(&req);
                        defer resp.deinit();

                        const body = try readBody(resp);
                        defer testing.allocator.free(body);
                        try testing.expectEqualStrings("ok", body);
                    }
                }.run,
            );
        }

        fn largeResponseStreamsWithoutBufferingWholeBody() !void {
            const payload = [_]u8{'r'} ** 8192;

            try withOneShotServer(.{
                .expected_request_line = "GET /large-response HTTP/1.1",
                .status_code = Http.status.ok,
                .body = &payload,
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{ .max_body_bytes = payload.len });
                    defer transport.deinit();

                    const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/large-response", .{port});
                    defer testing.allocator.free(url);

                    var req = try Http.Request.init(testing.allocator, "GET", url);
                    var resp = try transport.roundTrip(&req);
                    defer resp.deinit();

                    const body = try readBody(resp);
                    defer testing.allocator.free(body);
                    try testing.expectEqual(@as(usize, payload.len), body.len);
                    try testing.expectEqualStrings(&payload, body);
                }
            }.run);
        }

        fn defaultMaxBodyBytesAllowsLargeResponse() !void {
            const payload_len = 5 * 1024 * 1024;
            const payload = try testing.allocator.alloc(u8, payload_len);
            defer testing.allocator.free(payload);
            @memset(payload, 'r');

            try withOneShotServer(.{
                .expected_request_line = "GET /large-response-default HTTP/1.1",
                .status_code = Http.status.ok,
                .body = payload,
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{});
                    defer transport.deinit();

                    const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/large-response-default", .{port});
                    defer testing.allocator.free(url);

                    var req = try Http.Request.init(testing.allocator, "GET", url);
                    var resp = try transport.roundTrip(&req);
                    defer resp.deinit();

                    const body = try readBody(resp);
                    defer testing.allocator.free(body);
                    try testing.expectEqual(@as(usize, payload_len), body.len);
                    for (body) |b| {
                        try testing.expectEqual(@as(u8, 'r'), b);
                    }
                }
            }.run);
        }

        fn largeRequestStreamsWithoutBufferingWholeBody() !void {
            const payload = [_]u8{'q'} ** 8192;

            const BodySource = struct {
                payload: []const u8,
                offset: usize = 0,

                pub fn read(self: *@This(), buf: []u8) anyerror!usize {
                    const remaining = self.payload[self.offset..];
                    const n = @min(buf.len, remaining.len);
                    @memcpy(buf[0..n], remaining[0..n]);
                    self.offset += n;
                    return n;
                }

                pub fn close(_: *@This()) void {}
            };

            try withOneShotServer(.{
                .expected_request_line = "POST /large-request HTTP/1.1",
                .expected_request_body = &payload,
                .status_code = Http.status.ok,
                .body = "uploaded",
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{ .max_body_bytes = payload.len });
                    defer transport.deinit();

                    const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/large-request", .{port});
                    defer testing.allocator.free(url);

                    var source = BodySource{ .payload = &payload };
                    var req = try Http.Request.init(testing.allocator, "POST", url);
                    req = req.withBody(Http.ReadCloser.init(&source));
                    req.content_length = payload.len;

                    var resp = try transport.roundTrip(&req);
                    defer resp.deinit();

                    const body = try readBody(resp);
                    defer testing.allocator.free(body);
                    try testing.expectEqualStrings("uploaded", body);
                }
            }.run);
        }

        fn defaultMaxBodyBytesAllowsLargeRequest() !void {
            const payload_len = 5 * 1024 * 1024;
            const payload = try testing.allocator.alloc(u8, payload_len);
            defer testing.allocator.free(payload);
            @memset(payload, 'q');

            const BodySource = struct {
                byte: u8,
                len: usize,
                offset: usize = 0,

                pub fn read(self: *@This(), buf: []u8) anyerror!usize {
                    if (self.offset >= self.len) return 0;
                    const n = @min(buf.len, self.len - self.offset);
                    @memset(buf[0..n], self.byte);
                    self.offset += n;
                    return n;
                }

                pub fn close(_: *@This()) void {}
            };

            try withOneShotServer(.{
                .expected_request_line = "POST /large-request-default HTTP/1.1",
                .expected_request_body = payload,
                .status_code = Http.status.ok,
                .body = "uploaded",
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{});
                    defer transport.deinit();

                    const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/large-request-default", .{port});
                    defer testing.allocator.free(url);

                    var source = BodySource{ .byte = 'q', .len = payload_len };
                    var req = try Http.Request.init(testing.allocator, "POST", url);
                    req = req.withBody(Http.ReadCloser.init(&source));
                    req.content_length = payload_len;

                    var resp = try transport.roundTrip(&req);
                    defer resp.deinit();

                    const body = try readBody(resp);
                    defer testing.allocator.free(body);
                    try testing.expectEqualStrings("uploaded", body);
                }
            }.run);
        }

        fn connectMethodIsRejected() !void {
            var transport = try Http.Transport.init(testing.allocator, .{});
            defer transport.deinit();

            var req = try Http.Request.init(testing.allocator, "CONNECT", "http://example.com:443/");
            try testing.expectError(error.UnsupportedMethod, transport.roundTrip(&req));
        }

        fn idleConnectionIsReused() !void {
            const accept_count = try withTwoRequestKeepAliveServer(.{
                .first_request_line = "GET /reuse-1 HTTP/1.1",
                .second_request_line = "GET /reuse-2 HTTP/1.1",
                .first_body = "one",
                .second_body = "two",
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{});
                    defer transport.deinit();

                    const url1 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/reuse-1", .{port});
                    defer testing.allocator.free(url1);
                    const url2 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/reuse-2", .{port});
                    defer testing.allocator.free(url2);

                    var req1 = try Http.Request.init(testing.allocator, "GET", url1);
                    var resp1 = try transport.roundTrip(&req1);
                    const body1 = try readBody(resp1);
                    defer testing.allocator.free(body1);
                    try testing.expectEqualStrings("one", body1);
                    resp1.deinit();

                    var req2 = try Http.Request.init(testing.allocator, "GET", url2);
                    var resp2 = try transport.roundTrip(&req2);
                    defer resp2.deinit();
                    const body2 = try readBody(resp2);
                    defer testing.allocator.free(body2);
                    try testing.expectEqualStrings("two", body2);
                }
            }.run);

            try testing.expectEqual(@as(usize, 1), accept_count);
        }

        fn closeIdleConnectionsForcesNewConn() !void {
            const accept_count = try withTwoRequestKeepAliveServer(.{
                .first_request_line = "GET /close-idle-1 HTTP/1.1",
                .second_request_line = "GET /close-idle-2 HTTP/1.1",
                .first_body = "one",
                .second_body = "two",
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{});
                    defer transport.deinit();

                    const url1 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/close-idle-1", .{port});
                    defer testing.allocator.free(url1);
                    const url2 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/close-idle-2", .{port});
                    defer testing.allocator.free(url2);

                    var req1 = try Http.Request.init(testing.allocator, "GET", url1);
                    var resp1 = try transport.roundTrip(&req1);
                    const body1 = try readBody(resp1);
                    defer testing.allocator.free(body1);
                    try testing.expectEqualStrings("one", body1);
                    resp1.deinit();

                    transport.closeIdleConnections();

                    var req2 = try Http.Request.init(testing.allocator, "GET", url2);
                    var resp2 = try transport.roundTrip(&req2);
                    defer resp2.deinit();
                    const body2 = try readBody(resp2);
                    defer testing.allocator.free(body2);
                    try testing.expectEqualStrings("two", body2);
                }
            }.run);

            try testing.expectEqual(@as(usize, 2), accept_count);
        }

        fn earlyResponseBodyCloseDoesNotReuseConn() !void {
            const accept_count = try withTwoRequestKeepAliveServer(.{
                .first_request_line = "GET /partial-close-1 HTTP/1.1",
                .second_request_line = "GET /partial-close-2 HTTP/1.1",
                .first_body = "hello",
                .second_body = "world",
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{});
                    defer transport.deinit();

                    const url1 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/partial-close-1", .{port});
                    defer testing.allocator.free(url1);
                    const url2 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/partial-close-2", .{port});
                    defer testing.allocator.free(url2);

                    var req1 = try Http.Request.init(testing.allocator, "GET", url1);
                    var resp1 = try transport.roundTrip(&req1);
                    const body1 = resp1.body() orelse return error.TestUnexpectedResult;
                    var first: [1]u8 = undefined;
                    try testing.expectEqual(@as(usize, 1), try body1.read(&first));
                    try testing.expectEqualStrings("h", &first);
                    resp1.deinit();

                    var req2 = try Http.Request.init(testing.allocator, "GET", url2);
                    var resp2 = try transport.roundTrip(&req2);
                    defer resp2.deinit();
                    const body2 = try readBody(resp2);
                    defer testing.allocator.free(body2);
                    try testing.expectEqualStrings("world", body2);
                }
            }.run);

            try testing.expectEqual(@as(usize, 2), accept_count);
        }

        fn idleConnectionTimeoutForcesNewConn() !void {
            const accept_count = try withTwoRequestKeepAliveServer(.{
                .first_request_line = "GET /idle-timeout-1 HTTP/1.1",
                .second_request_line = "GET /idle-timeout-2 HTTP/1.1",
                .first_body = "one",
                .second_body = "two",
                .reuse_wait_timeout_ms = 50,
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{
                        .idle_conn_timeout_ms = 10,
                    });
                    defer transport.deinit();

                    const url1 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/idle-timeout-1", .{port});
                    defer testing.allocator.free(url1);
                    const url2 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/idle-timeout-2", .{port});
                    defer testing.allocator.free(url2);

                    var req1 = try Http.Request.init(testing.allocator, "GET", url1);
                    var resp1 = try transport.roundTrip(&req1);
                    const body1 = try readBody(resp1);
                    defer testing.allocator.free(body1);
                    try testing.expectEqualStrings("one", body1);
                    resp1.deinit();

                    lib.Thread.sleep(30 * lib.time.ns_per_ms);

                    var req2 = try Http.Request.init(testing.allocator, "GET", url2);
                    var resp2 = try transport.roundTrip(&req2);
                    defer resp2.deinit();
                    const body2 = try readBody(resp2);
                    defer testing.allocator.free(body2);
                    try testing.expectEqualStrings("two", body2);
                }
            }.run);

            try testing.expectEqual(@as(usize, 2), accept_count);
        }

        fn sameHostRequestWhileBodyOpenUsesSecondConn() !void {
            const accept_count = try withTwoRequestKeepAliveServer(.{
                .first_request_line = "GET /body-open-1 HTTP/1.1",
                .second_request_line = "GET /body-open-2 HTTP/1.1",
                .first_body = "hello",
                .second_body = "world",
                .reuse_wait_timeout_ms = 50,
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{});
                    defer transport.deinit();

                    const url1 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/body-open-1", .{port});
                    defer testing.allocator.free(url1);
                    const url2 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/body-open-2", .{port});
                    defer testing.allocator.free(url2);

                    var req1 = try Http.Request.init(testing.allocator, "GET", url1);
                    var resp1 = try transport.roundTrip(&req1);
                    defer resp1.deinit();
                    try testing.expect(resp1.body() != null);

                    var req2 = try Http.Request.init(testing.allocator, "GET", url2);
                    var task = RoundTripTask{
                        .transport = &transport,
                        .req = &req2,
                    };
                    var thread = try lib.Thread.spawn(.{}, RoundTripTask.run, .{&task});
                    thread.join();

                    if (task.err) |err| return err;
                    var resp2 = task.resp orelse return error.TestUnexpectedResult;
                    defer resp2.deinit();

                    const body2 = try readBody(resp2);
                    defer testing.allocator.free(body2);
                    try testing.expectEqualStrings("world", body2);
                }
            }.run);

            try testing.expectEqual(@as(usize, 2), accept_count);
        }

        fn staleIdleConnectionRetriesReplayableGet() !void {
            const accept_count = try withStaleIdleRetryServer(.{
                .warmup_request_line = "GET /warm HTTP/1.1",
                .warmup_body = "warm",
                .retry_request_line = "GET /retry-get HTTP/1.1",
                .retry_response_body = "retried",
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{});
                    defer transport.deinit();

                    const warm_url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/warm", .{port});
                    defer testing.allocator.free(warm_url);
                    const retry_url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/retry-get", .{port});
                    defer testing.allocator.free(retry_url);

                    var warm_req = try Http.Request.init(testing.allocator, "GET", warm_url);
                    var warm_resp = try transport.roundTrip(&warm_req);
                    const warm_body = try readBody(warm_resp);
                    defer testing.allocator.free(warm_body);
                    try testing.expectEqualStrings("warm", warm_body);
                    warm_resp.deinit();

                    var retry_req = try Http.Request.init(testing.allocator, "GET", retry_url);
                    var retry_resp = try transport.roundTrip(&retry_req);
                    defer retry_resp.deinit();

                    const body = try readBody(retry_resp);
                    defer testing.allocator.free(body);
                    try testing.expectEqualStrings("retried", body);
                }
            }.run);

            try testing.expectEqual(@as(usize, 2), accept_count);
        }

        fn staleIdleConnectionRetriesIdempotentReplayablePost() !void {
            const payload = "retry payload";
            const accept_count = try withStaleIdleRetryServer(.{
                .warmup_request_line = "GET /warm-post HTTP/1.1",
                .warmup_body = "warm",
                .retry_request_line = "POST /retry-post HTTP/1.1",
                .retry_request_body = payload,
                .retry_response_body = "posted",
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{});
                    defer transport.deinit();

                    const warm_url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/warm-post", .{port});
                    defer testing.allocator.free(warm_url);
                    const retry_url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/retry-post", .{port});
                    defer testing.allocator.free(retry_url);

                    var warm_req = try Http.Request.init(testing.allocator, "GET", warm_url);
                    var warm_resp = try transport.roundTrip(&warm_req);
                    const warm_body = try readBody(warm_resp);
                    defer testing.allocator.free(warm_body);
                    try testing.expectEqualStrings("warm", warm_body);
                    warm_resp.deinit();

                    var body_factory = ReplayBodyFactory{ .payload = payload };
                    const initial_body_source = try testing.allocator.create(OwnedBodySource);
                    initial_body_source.* = .{ .payload = payload };
                    const initial_body = Http.ReadCloser.init(initial_body_source);

                    var req = try Http.Request.init(testing.allocator, "POST", retry_url);
                    req = req.withBody(initial_body);
                    req = req.withGetBody(Http.Request.GetBody.init(&body_factory));
                    req.header = &.{Http.Header.init("Idempotency-Key", "abc123")};
                    req.content_length = payload.len;

                    var resp = try transport.roundTrip(&req);
                    defer resp.deinit();

                    const body = try readBody(resp);
                    defer testing.allocator.free(body);
                    try testing.expectEqualStrings("posted", body);
                    try testing.expectEqual(@as(usize, 1), body_factory.calls);
                }
            }.run);

            try testing.expectEqual(@as(usize, 2), accept_count);
        }

        fn chunkedRequestUsesTransferEncoding() !void {
            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "POST /chunked-request HTTP/1.1"));

                        const head_end = lib.mem.indexOf(u8, req_head, "\r\n\r\n") orelse return error.TestUnexpectedResult;
                        try testing.expect(headerValue(req_head[0..head_end], Http.Header.content_length) == null);
                        try testing.expectEqualStrings("chunked", headerValue(req_head[0..head_end], Http.Header.transfer_encoding) orelse "");

                        const raw_body = try readUntilTerminator(conn, req_head[head_end + 4 ..], "0\r\n\r\n");
                        defer testing.allocator.free(raw_body);
                        try testing.expectEqualStrings("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n", raw_body);

                        io.writeAll(@TypeOf(c), &c, "HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\nuploaded") catch {};
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *EmptyState) !void {
                        var transport = try Http.Transport.init(testing.allocator, .{});
                        defer transport.deinit();

                        const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/chunked-request", .{port});
                        defer testing.allocator.free(url);

                        const chunks = [_][]const u8{ "hello", " world" };
                        var source = ChunkedBodySource{ .chunks = &chunks };
                        var req = try Http.Request.init(testing.allocator, "POST", url);
                        req = req.withBody(Http.ReadCloser.init(&source));

                        var resp = try transport.roundTrip(&req);
                        defer resp.deinit();

                        const body = try readBody(resp);
                        defer testing.allocator.free(body);
                        try testing.expectEqualStrings("uploaded", body);
                    }
                }.run,
            );
        }

        fn chunkedResponseStreams() !void {
            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "GET /chunked-response HTTP/1.1"));

                        io.writeAll(
                            @TypeOf(c),
                            &c,
                            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" ++
                                "5\r\nhello\r\n" ++
                                "6\r\n world\r\n" ++
                                "0\r\nX-Test: ignored\r\n\r\n",
                        ) catch {};
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *EmptyState) !void {
                        var transport = try Http.Transport.init(testing.allocator, .{});
                        defer transport.deinit();

                        const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/chunked-response", .{port});
                        defer testing.allocator.free(url);

                        var req = try Http.Request.init(testing.allocator, "GET", url);
                        var resp = try transport.roundTrip(&req);
                        defer resp.deinit();

                        try testing.expectEqual(@as(i64, -1), resp.content_length);
                        const body = try readBody(resp);
                        defer testing.allocator.free(body);
                        try testing.expectEqualStrings("hello world", body);
                    }
                }.run,
            );
        }

        fn eofDelimitedResponseStreams() !void {
            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "GET /eof-response HTTP/1.1"));

                        io.writeAll(
                            @TypeOf(c),
                            &c,
                            "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nhello eof",
                        ) catch {};
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *EmptyState) !void {
                        var transport = try Http.Transport.init(testing.allocator, .{});
                        defer transport.deinit();

                        const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/eof-response", .{port});
                        defer testing.allocator.free(url);

                        var req = try Http.Request.init(testing.allocator, "GET", url);
                        var resp = try transport.roundTrip(&req);
                        defer resp.deinit();

                        const body = try readBody(resp);
                        defer testing.allocator.free(body);
                        try testing.expectEqualStrings("hello eof", body);
                    }
                }.run,
            );
        }

        fn headResponseIsBodyless() !void {
            try withOneShotServer(.{
                .expected_request_line = "HEAD /head HTTP/1.1",
                .status_code = Http.status.ok,
                .body = "ignored",
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{});
                    defer transport.deinit();

                    const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/head", .{port});
                    defer testing.allocator.free(url);

                    var req = try Http.Request.init(testing.allocator, "HEAD", url);
                    var resp = try transport.roundTrip(&req);
                    defer resp.deinit();

                    try testing.expect(resp.body() == null);
                    try testing.expectEqual(@as(i64, "ignored".len), resp.content_length);
                }
            }.run);
        }

        fn status204ResponseIsBodyless() !void {
            try withOneShotServer(.{
                .expected_request_line = "GET /no-content HTTP/1.1",
                .status_code = Http.status.no_content,
                .body = "ignored",
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{});
                    defer transport.deinit();

                    const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/no-content", .{port});
                    defer testing.allocator.free(url);

                    var req = try Http.Request.init(testing.allocator, "GET", url);
                    var resp = try transport.roundTrip(&req);
                    defer resp.deinit();

                    try testing.expect(resp.body() == null);
                    try testing.expectEqual(Http.status.no_content, resp.status_code);
                }
            }.run);
        }

        fn status304ResponseIsBodyless() !void {
            try withOneShotServer(.{
                .expected_request_line = "GET /not-modified HTTP/1.1",
                .status_code = Http.status.not_modified,
                .body = "ignored",
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{});
                    defer transport.deinit();

                    const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/not-modified", .{port});
                    defer testing.allocator.free(url);

                    var req = try Http.Request.init(testing.allocator, "GET", url);
                    var resp = try transport.roundTrip(&req);
                    defer resp.deinit();

                    try testing.expect(resp.body() == null);
                    try testing.expectEqual(Http.status.not_modified, resp.status_code);
                }
            }.run);
        }

        fn informationalContinueThenFinalResponse() !void {
            const payload = "hello";

            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "POST /continue HTTP/1.1"));
                        const head_end = lib.mem.indexOf(u8, req_head, "\r\n\r\n") orelse return error.TestUnexpectedResult;
                        try testing.expectEqualStrings("100-continue", headerValue(req_head[0..head_end], Http.Header.expect) orelse "");
                        try testing.expectEqual(@as(usize, 0), req_head[head_end + 4 ..].len);

                        io.writeAll(@TypeOf(c), &c, "HTTP/1.1 100 Continue\r\n\r\n") catch {};
                        try testing.expectEqual(RequestBodyMatch.ok, requestBodyMatches(conn, req_head, payload));
                        io.writeAll(@TypeOf(c), &c, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok") catch {};
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *EmptyState) !void {
                        var transport = try Http.Transport.init(testing.allocator, .{});
                        defer transport.deinit();

                        const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/continue", .{port});
                        defer testing.allocator.free(url);

                        const chunks = [_][]const u8{payload};
                        var source = ChunkedBodySource{ .chunks = &chunks };
                        var req = try Http.Request.init(testing.allocator, "POST", url);
                        req = req.withBody(Http.ReadCloser.init(&source));
                        req.header = &.{Http.Header.init(Http.Header.expect, "100-continue")};
                        req.content_length = payload.len;

                        var resp = try transport.roundTrip(&req);
                        defer resp.deinit();

                        const body = try readBody(resp);
                        defer testing.allocator.free(body);
                        try testing.expectEqualStrings("ok", body);
                    }
                }.run,
            );
        }

        fn expectContinueTimeoutSendsBodyWithoutInformational() !void {
            const payload = "hello after timeout";

            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "POST /continue-timeout HTTP/1.1"));
                        const head_end = lib.mem.indexOf(u8, req_head, "\r\n\r\n") orelse return error.TestUnexpectedResult;
                        try testing.expectEqualStrings("100-continue", headerValue(req_head[0..head_end], Http.Header.expect) orelse "");
                        try testing.expectEqual(@as(usize, 0), req_head[head_end + 4 ..].len);

                        lib.Thread.sleep(40 * lib.time.ns_per_ms);
                        try testing.expectEqual(RequestBodyMatch.ok, requestBodyMatches(conn, req_head, payload));
                        io.writeAll(@TypeOf(c), &c, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok") catch {};
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *EmptyState) !void {
                        var transport = try Http.Transport.init(testing.allocator, .{
                            .expect_continue_timeout_ms = 10,
                        });
                        defer transport.deinit();

                        const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/continue-timeout", .{port});
                        defer testing.allocator.free(url);

                        var source = ChunkedBodySource{ .chunks = &.{payload} };
                        var req = try Http.Request.init(testing.allocator, "POST", url);
                        req = req.withBody(Http.ReadCloser.init(&source));
                        req.header = &.{Http.Header.init(Http.Header.expect, "100-continue")};
                        req.content_length = payload.len;

                        var resp = try transport.roundTrip(&req);
                        defer resp.deinit();

                        const body = try readBody(resp);
                        defer testing.allocator.free(body);
                        try testing.expectEqualStrings("ok", body);
                    }
                }.run,
            );
        }

        fn finalResponseWithoutContinueSkipsRequestBody() !void {
            const State = struct {
                body: BlockingBodySource = .{},
            };

            try withServerState(
                State{},
                struct {
                    fn run(conn: net_mod.Conn, _: *State) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "POST /continue-skip HTTP/1.1"));
                        const head_end = lib.mem.indexOf(u8, req_head, "\r\n\r\n") orelse return error.TestUnexpectedResult;
                        try testing.expectEqualStrings("100-continue", headerValue(req_head[0..head_end], Http.Header.expect) orelse "");
                        try testing.expectEqual(@as(usize, 0), req_head[head_end + 4 ..].len);

                        io.writeAll(@TypeOf(c), &c, "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nskip") catch {};
                    }
                }.run,
                struct {
                    fn run(port: u16, state: *State) !void {
                        var transport = try Http.Transport.init(testing.allocator, .{
                            .expect_continue_timeout_ms = 200,
                        });
                        defer transport.deinit();

                        const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/continue-skip", .{port});
                        defer testing.allocator.free(url);

                        var req = try Http.Request.init(testing.allocator, "POST", url);
                        req = req.withBody(Http.ReadCloser.init(&state.body));
                        req.header = &.{Http.Header.init(Http.Header.expect, "100-continue")};
                        req.content_length = 5;

                        var resp = try transport.roundTrip(&req);
                        defer resp.deinit();

                        const body = try readBody(resp);
                        defer testing.allocator.free(body);
                        try testing.expectEqualStrings("skip", body);
                        try testing.expect(state.body.closed);
                    }
                }.run,
            );
        }

        fn requestBodyStreamsBeforeRoundTripCompletes() !void {
            const State = struct {
                body: PhasedBodySource = .{
                    .first = "ping",
                    .second = "pong",
                },
                server_saw_first: Gate = .{},
            };

            try withServerState(
                State{},
                struct {
                    fn run(conn: net_mod.Conn, state: *State) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "POST /request-stream HTTP/1.1"));

                        const head_end = lib.mem.indexOf(u8, req_head, "\r\n\r\n") orelse return error.TestUnexpectedResult;
                        var first: [4]u8 = undefined;
                        try readExpectedBytes(conn, req_head[head_end + 4 ..], &first);
                        try testing.expectEqualStrings(state.body.first, &first);
                        state.server_saw_first.signal();

                        var rest: [4]u8 = undefined;
                        try io.readFull(@TypeOf(c), &c, &rest);
                        try testing.expectEqualStrings(state.body.second, &rest);

                        io.writeAll(@TypeOf(c), &c, "HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\nuploaded") catch {};
                    }
                }.run,
                struct {
                    fn run(port: u16, state: *State) !void {
                        var transport = try Http.Transport.init(testing.allocator, .{});
                        defer transport.deinit();

                        const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/request-stream", .{port});
                        defer testing.allocator.free(url);

                        var req = try Http.Request.init(testing.allocator, "POST", url);
                        req = req.withBody(Http.ReadCloser.init(&state.body));
                        req.content_length = @intCast(state.body.first.len + state.body.second.len);

                        var task = RoundTripTask{
                            .transport = &transport,
                            .req = &req,
                        };
                        var thread = try lib.Thread.spawn(.{}, RoundTripTask.run, .{&task});

                        state.server_saw_first.wait();
                        state.body.releaseSecond();
                        thread.join();

                        if (task.err) |err| return err;
                        var resp = task.resp orelse return error.TestUnexpectedResult;
                        defer resp.deinit();

                        const body = try readBody(resp);
                        defer testing.allocator.free(body);
                        try testing.expectEqualStrings("uploaded", body);
                    }
                }.run,
            );
        }

        fn responseBodyStreamsProgressively() !void {
            const State = struct {
                client_read_first: Gate = .{},
            };

            try withServerState(
                State{},
                struct {
                    fn run(conn: net_mod.Conn, state: *State) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "GET /response-stream HTTP/1.1"));

                        io.writeAll(
                            @TypeOf(c),
                            &c,
                            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" ++
                                "5\r\nhello\r\n",
                        ) catch {};
                        state.client_read_first.wait();
                        io.writeAll(@TypeOf(c), &c, "6\r\n world\r\n0\r\n\r\n") catch {};
                    }
                }.run,
                struct {
                    fn run(port: u16, state: *State) !void {
                        var transport = try Http.Transport.init(testing.allocator, .{});
                        defer transport.deinit();

                        const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/response-stream", .{port});
                        defer testing.allocator.free(url);

                        var req = try Http.Request.init(testing.allocator, "GET", url);
                        var resp = try transport.roundTrip(&req);
                        defer resp.deinit();

                        const body = resp.body() orelse return error.TestUnexpectedResult;
                        var first: [5]u8 = undefined;
                        try testing.expectEqual(@as(usize, 5), try body.read(&first));
                        try testing.expectEqualStrings("hello", &first);

                        state.client_read_first.signal();

                        var rest: [16]u8 = undefined;
                        const n = try body.read(&rest);
                        try testing.expectEqualStrings(" world", rest[0..n]);
                    }
                }.run,
            );
        }

        fn fullDuplexRequestAndResponse() !void {
            const State = struct {
                body: PhasedBodySource = .{
                    .first = "hello",
                    .second = " world",
                },
                client_read_first_response: Gate = .{},
            };

            try withServerState(
                State{},
                struct {
                    fn run(conn: net_mod.Conn, state: *State) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "POST /duplex HTTP/1.1"));

                        const head_end = lib.mem.indexOf(u8, req_head, "\r\n\r\n") orelse return error.TestUnexpectedResult;
                        var first: [5]u8 = undefined;
                        try readExpectedBytes(conn, req_head[head_end + 4 ..], &first);
                        try testing.expectEqualStrings(state.body.first, &first);

                        io.writeAll(
                            @TypeOf(c),
                            &c,
                            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" ++
                                "5\r\nreply\r\n",
                        ) catch {};

                        state.client_read_first_response.wait();

                        var rest: [6]u8 = undefined;
                        try io.readFull(@TypeOf(c), &c, &rest);
                        try testing.expectEqualStrings(state.body.second, &rest);

                        io.writeAll(@TypeOf(c), &c, "5\r\n done\r\n0\r\n\r\n") catch {};
                    }
                }.run,
                struct {
                    fn run(port: u16, state: *State) !void {
                        var transport = try Http.Transport.init(testing.allocator, .{});
                        defer transport.deinit();

                        const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/duplex", .{port});
                        defer testing.allocator.free(url);

                        var req = try Http.Request.init(testing.allocator, "POST", url);
                        req = req.withBody(Http.ReadCloser.init(&state.body));
                        req.content_length = @intCast(state.body.first.len + state.body.second.len);

                        var resp = try transport.roundTrip(&req);
                        defer resp.deinit();

                        const body = resp.body() orelse return error.TestUnexpectedResult;
                        var first: [5]u8 = undefined;
                        try testing.expectEqual(@as(usize, 5), try body.read(&first));
                        try testing.expectEqualStrings("reply", &first);

                        state.body.releaseSecond();
                        state.client_read_first_response.signal();

                        var rest: [16]u8 = undefined;
                        const n = try body.read(&rest);
                        try testing.expectEqualStrings(" done", rest[0..n]);
                    }
                }.run,
            );
        }

        fn bodylessEarlyResponseDoesNotWaitForBlockedRequestBody() !void {
            const State = struct {
                body: PhasedBodySource = .{
                    .first = "hello",
                    .second = " world",
                },
            };

            try withServerState(
                State{},
                struct {
                    fn run(conn: net_mod.Conn, state: *State) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "POST /bodyless-early-response HTTP/1.1"));

                        const head_end = lib.mem.indexOf(u8, req_head, "\r\n\r\n") orelse return error.TestUnexpectedResult;
                        var first: [5]u8 = undefined;
                        try readExpectedBytes(conn, req_head[head_end + 4 ..], &first);
                        try testing.expectEqualStrings(state.body.first, &first);

                        io.writeAll(@TypeOf(c), &c, "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n") catch {};
                    }
                }.run,
                struct {
                    fn run(port: u16, state: *State) !void {
                        var transport = try Http.Transport.init(testing.allocator, .{});
                        defer transport.deinit();

                        const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/bodyless-early-response", .{port});
                        defer testing.allocator.free(url);

                        var req = try Http.Request.init(testing.allocator, "POST", url);
                        req = req.withBody(Http.ReadCloser.init(&state.body));
                        req.content_length = @intCast(state.body.first.len + state.body.second.len);

                        var resp = try transport.roundTrip(&req);
                        defer resp.deinit();

                        try testing.expectEqual(Http.status.no_content, resp.status_code);
                        try testing.expect(resp.body() == null);
                    }
                }.run,
            );
        }

        fn withTwoRequestKeepAliveServer(spec: TwoRequestSpec, comptime ClientFn: anytype) !usize {
            var ln = try Net.listen(testing.allocator, .{
                .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
            });
            defer ln.deinit();

            const listener_impl = try ln.as(Net.TcpListener);
            const port = try listenerPort(ln, Net);
            var accept_count: usize = 0;
            var server_result: ?anyerror = null;

            var server_thread = try lib.Thread.spawn(.{}, struct {
                fn run(tcp_listener: *Net.TcpListener, server_spec: TwoRequestSpec, accepts: *usize, result: *?anyerror) void {
                    serveTwoKeepAliveRequests(tcp_listener, server_spec, accepts) catch |err| {
                        result.* = err;
                    };
                }
            }.run, .{ listener_impl, spec, &accept_count, &server_result });
            errdefer server_thread.join();

            try ClientFn(port);
            server_thread.join();
            if (server_result) |err| return err;
            return accept_count;
        }

        fn withStaleIdleRetryServer(spec: StaleIdleRetrySpec, comptime ClientFn: anytype) !usize {
            var ln = try Net.listen(testing.allocator, .{
                .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
            });
            defer ln.deinit();

            const listener_impl = try ln.as(Net.TcpListener);
            const port = try listenerPort(ln, Net);
            var accept_count: usize = 0;
            var server_result: ?anyerror = null;

            var server_thread = try lib.Thread.spawn(.{}, struct {
                fn run(tcp_listener: *Net.TcpListener, server_spec: StaleIdleRetrySpec, accepts: *usize, result: *?anyerror) void {
                    serveStaleIdleRetryRequests(tcp_listener, server_spec, accepts) catch |err| {
                        result.* = err;
                    };
                }
            }.run, .{ listener_impl, spec, &accept_count, &server_result });
            errdefer server_thread.join();

            try ClientFn(port);
            server_thread.join();
            if (server_result) |err| return err;
            return accept_count;
        }

        fn serveTwoKeepAliveRequests(tcp_listener: *Net.TcpListener, spec: TwoRequestSpec, accept_count: *usize) !void {
            var conn = try tcp_listener.accept();
            accept_count.* += 1;
            defer conn.deinit();

            _ = try serveKeepAliveRequest(conn, spec.first_request_line, spec.first_body, false);

            conn.setReadTimeout(spec.reuse_wait_timeout_ms);
            const reused = serveKeepAliveRequest(conn, spec.second_request_line, spec.second_body, true) catch |err| switch (err) {
                error.TimedOut, error.EndOfStream => false,
                else => return err,
            };
            conn.setReadTimeout(null);
            if (reused) return;

            var second_conn = try tcp_listener.accept();
            accept_count.* += 1;
            defer second_conn.deinit();
            _ = try serveKeepAliveRequest(second_conn, spec.second_request_line, spec.second_body, true);
        }

        fn serveStaleIdleRetryRequests(tcp_listener: *Net.TcpListener, spec: StaleIdleRetrySpec, accept_count: *usize) !void {
            var warmup_conn = try tcp_listener.accept();
            accept_count.* += 1;
            {
                defer warmup_conn.deinit();
                var c = warmup_conn;
                var req_buf: [4096]u8 = undefined;
                const req_head = try readRequestHead(warmup_conn, &req_buf);
                try testing.expect(hasRequestLine(req_head, spec.warmup_request_line));

                var head_buf: [256]u8 = undefined;
                const head = try lib.fmt.bufPrint(
                    &head_buf,
                    "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n",
                    .{spec.warmup_body.len},
                );
                try io.writeAll(@TypeOf(c), &c, head);
                try io.writeAll(@TypeOf(c), &c, spec.warmup_body);
            }

            var retry_conn = try tcp_listener.accept();
            accept_count.* += 1;
            defer retry_conn.deinit();
            var c = retry_conn;
            var req_buf: [4096]u8 = undefined;
            const req_head = try readRequestHead(retry_conn, &req_buf);
            try testing.expect(hasRequestLine(req_head, spec.retry_request_line));
            if (spec.retry_request_body) |expected_body| {
                try testing.expectEqual(RequestBodyMatch.ok, requestBodyMatches(retry_conn, req_head, expected_body));
            }

            var head_buf: [256]u8 = undefined;
            const head = try lib.fmt.bufPrint(
                &head_buf,
                "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
                .{spec.retry_response_body.len},
            );
            try io.writeAll(@TypeOf(c), &c, head);
            try io.writeAll(@TypeOf(c), &c, spec.retry_response_body);
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

        fn withOneShotServer(spec: ServerSpec, comptime ClientFn: anytype) !void {
            var ln = try Net.listen(testing.allocator, .{
                .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
            });
            defer ln.deinit();

            const listener_impl = try ln.as(Net.TcpListener);
            const port = try listenerPort(ln, Net);
            var server_thread = try lib.Thread.spawn(.{}, struct {
                fn run(tcp_listener: *Net.TcpListener, server_spec: ServerSpec) void {
                    var conn = tcp_listener.accept() catch return;
                    defer conn.deinit();

                    var req_buf: [4096]u8 = undefined;
                    const req_head = readRequestHead(conn, &req_buf) catch return;

                    const line_matches = hasRequestLine(req_head, server_spec.expected_request_line);
                    const body_match = if (line_matches)
                        if (server_spec.expected_request_body) |expected_body|
                            requestBodyMatches(conn, req_head, expected_body)
                        else
                            .ok
                    else
                        .stream_mismatch;
                    const matched = line_matches and body_match == .ok;
                    const status_code = if (matched) server_spec.status_code else Http.status.internal_server_error;
                    const body = if (matched)
                        server_spec.body
                    else if (!line_matches)
                        "unexpected request line"
                    else switch (body_match) {
                        .missing_header_terminator => "unexpected request body: missing header terminator",
                        .missing_content_length => "unexpected request body: missing content-length",
                        .invalid_content_length => "unexpected request body: invalid content-length",
                        .content_length_mismatch => "unexpected request body: content-length mismatch",
                        .prefix_too_large => "unexpected request body: prefix too large",
                        .prefix_mismatch => "unexpected request body: prefix mismatch",
                        .stream_mismatch => "unexpected request body: stream mismatch",
                        .read_error => "unexpected request body: read error",
                        .ok => unreachable,
                    };
                    const content_type = if (matched) server_spec.content_type else "text/plain";

                    if (server_spec.delay_ms != 0) {
                        lib.Thread.sleep(@as(u64, server_spec.delay_ms) * lib.time.ns_per_ms);
                    }

                    const reason = Http.status.text(status_code) orelse "Unknown";
                    var head_buf: [256]u8 = undefined;
                    const head = lib.fmt.bufPrint(
                        &head_buf,
                        "HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\nContent-Type: {s}\r\nConnection: close\r\n\r\n",
                        .{ status_code, reason, body.len, content_type },
                    ) catch return;
                    io.writeAll(@TypeOf(conn), &conn, head) catch return;
                    io.writeAll(@TypeOf(conn), &conn, body) catch {};
                }
            }.run, .{ listener_impl, spec });
            defer server_thread.join();

            try ClientFn(port);
        }

        fn withServerState(state_init: anytype, comptime ServerFn: anytype, comptime ClientFn: anytype) !void {
            const State = @TypeOf(state_init);
            var state = state_init;
            var ln = try Net.listen(testing.allocator, .{
                .address = Addr.initIp4(.{ 127, 0, 0, 1 }, 0),
            });
            defer ln.deinit();

            const listener_impl = try ln.as(Net.TcpListener);
            const port = try listenerPort(ln, Net);
            var server_result: ?anyerror = null;

            var server_thread = try lib.Thread.spawn(.{}, struct {
                fn run(tcp_listener: *Net.TcpListener, state_ptr: *State, result: *?anyerror) void {
                    var conn = tcp_listener.accept() catch |err| {
                        result.* = err;
                        return;
                    };
                    defer conn.deinit();

                    ServerFn(conn, state_ptr) catch |err| {
                        result.* = err;
                    };
                }
            }.run, .{ listener_impl, &state, &server_result });
            errdefer server_thread.join();

            try ClientFn(port, &state);
            server_thread.join();
            if (server_result) |err| return err;
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

        fn requestBodyMatches(conn: net_mod.Conn, req_head: []const u8, expected: []const u8) RequestBodyMatch {
            var c = conn;
            const head_end = lib.mem.indexOf(u8, req_head, "\r\n\r\n") orelse return .missing_header_terminator;
            const content_length_value = headerValue(req_head[0..head_end], Http.Header.content_length) orelse return .missing_content_length;
            const content_length = lib.fmt.parseInt(usize, content_length_value, 10) catch return .invalid_content_length;
            if (content_length != expected.len) return .content_length_mismatch;

            const prefix = req_head[head_end + 4 ..];
            if (prefix.len > expected.len) return .prefix_too_large;
            if (!lib.mem.eql(u8, prefix, expected[0..prefix.len])) return .prefix_mismatch;

            var matched: usize = prefix.len;
            var buf: [1024]u8 = undefined;
            while (matched < expected.len) {
                const want = @min(buf.len, expected.len - matched);
                io.readFull(@TypeOf(c), &c, buf[0..want]) catch return .read_error;
                if (!lib.mem.eql(u8, buf[0..want], expected[matched..][0..want])) return .stream_mismatch;
                matched += want;
            }

            return .ok;
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

        fn readUntilTerminator(conn: net_mod.Conn, prefix: []const u8, terminator: []const u8) ![]u8 {
            var c = conn;
            var bytes = try lib.ArrayList(u8).initCapacity(testing.allocator, prefix.len);
            errdefer bytes.deinit(testing.allocator);
            try bytes.appendSlice(testing.allocator, prefix);

            var buf: [128]u8 = undefined;
            while (true) {
                if (bytes.items.len >= terminator.len and lib.mem.eql(u8, bytes.items[bytes.items.len - terminator.len ..], terminator)) {
                    return bytes.toOwnedSlice(testing.allocator);
                }

                const n = try c.read(&buf);
                if (n == 0) return error.EndOfStream;
                try bytes.appendSlice(testing.allocator, buf[0..n]);
            }
        }

        fn readExpectedBytes(conn: net_mod.Conn, prefix: []const u8, out: []u8) !void {
            if (prefix.len > out.len) return error.TestUnexpectedResult;
            @memcpy(out[0..prefix.len], prefix);
            if (prefix.len == out.len) return;

            var c = conn;
            try io.readFull(@TypeOf(c), &c, out[prefix.len..]);
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

    log.info("=== http transport test_runner start ===", .{});
    if (suite == .layer01) {
        try Runner.idleConnectionIsReused();
        try Runner.closeIdleConnectionsForcesNewConn();
        try Runner.earlyResponseBodyCloseDoesNotReuseConn();
        try Runner.idleConnectionTimeoutForcesNewConn();
        try Runner.sameHostRequestWhileBodyOpenUsesSecondConn();
        try Runner.defaultUserAgentMatchesGo();
        try Runner.emptyUserAgentSuppressesDefault();
        try Runner.responseHeaderTimeoutExceeded();
        try Runner.responseHeaderTimeoutDoesNotLimitBodyRead();
        try Runner.defaultMaxHeaderBytesAllowsLargeResponseHeaders();
        try Runner.defaultMaxBodyBytesAllowsLargeResponse();
        try Runner.defaultMaxBodyBytesAllowsLargeRequest();
        try Runner.informationalContinueThenFinalResponse();
        try Runner.expectContinueTimeoutSendsBodyWithoutInformational();
        try Runner.finalResponseWithoutContinueSkipsRequestBody();
        try Runner.staleIdleConnectionRetriesReplayableGet();
        try Runner.staleIdleConnectionRetriesIdempotentReplayablePost();
        log.info("=== http transport test_runner done ===", .{});
        return;
    }

    try Runner.localReturns200();
    try Runner.localReturns404();
    try Runner.defaultUserAgentMatchesGo();
    try Runner.emptyUserAgentSuppressesDefault();
    try Runner.contextDeadlineExceeded();
    try Runner.responseHeaderTimeoutExceeded();
    try Runner.responseHeaderTimeoutDoesNotLimitBodyRead();
    try Runner.defaultMaxHeaderBytesAllowsLargeResponseHeaders();
    try Runner.responseBodyLargerThanMaxBodyBytesFails();
    try Runner.defaultMaxBodyBytesAllowsLargeResponse();
    try Runner.largeResponseStreamsWithoutBufferingWholeBody();
    try Runner.defaultMaxBodyBytesAllowsLargeRequest();
    try Runner.largeRequestStreamsWithoutBufferingWholeBody();
    try Runner.connectMethodIsRejected();
    try Runner.idleConnectionIsReused();
    try Runner.closeIdleConnectionsForcesNewConn();
    try Runner.earlyResponseBodyCloseDoesNotReuseConn();
    try Runner.idleConnectionTimeoutForcesNewConn();
    try Runner.sameHostRequestWhileBodyOpenUsesSecondConn();
    try Runner.chunkedRequestUsesTransferEncoding();
    try Runner.chunkedResponseStreams();
    try Runner.eofDelimitedResponseStreams();
    try Runner.headResponseIsBodyless();
    try Runner.status204ResponseIsBodyless();
    try Runner.status304ResponseIsBodyless();
    try Runner.informationalContinueThenFinalResponse();
    try Runner.expectContinueTimeoutSendsBodyWithoutInformational();
    try Runner.finalResponseWithoutContinueSkipsRequestBody();
    try Runner.requestBodyStreamsBeforeRoundTripCompletes();
    try Runner.responseBodyStreamsProgressively();
    try Runner.fullDuplexRequestAndResponse();
    try Runner.bodylessEarlyResponseDoesNotWaitForBlockedRequestBody();
    try Runner.staleIdleConnectionRetriesReplayableGet();
    try Runner.staleIdleConnectionRetriesIdempotentReplayablePost();
    if (suite == .full) try Runner.publicAliDnsDoh();
    log.info("=== http transport test_runner done ===", .{});
}
