//! Shared HTTP transport runner implementation.
//!
const embed = @import("embed");
const io = @import("io");
const net_mod = @import("../../net.zig");
const context_mod = @import("context");
const testing_api = @import("testing");

pub fn make(
    comptime lib: type,
    comptime name: []const u8,
    comptime run_cases: *const fn (type, type) anyerror!void,
) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: embed.Thread.SpawnConfig = .{ .stack_size = 1024 * 1024 },

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            runImpl(lib, t, allocator, run_cases) catch |err| {
                t.logErrorf("{s} runner failed: {}", .{ name, err });
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

fn runImpl(
    comptime lib: type,
    t: *testing_api.T,
    alloc: lib.mem.Allocator,
    comptime run_cases: *const fn (type, type) anyerror!void,
) !void {
    _ = t;
    const Net = net_mod.make(lib);
    const Http = Net.http;
    const AddrPort = net_mod.netip.AddrPort;
    const testing = struct {
        pub var allocator: lib.mem.Allocator = undefined;
        pub const expect = lib.testing.expect;
        pub const expectEqual = lib.testing.expectEqual;
        pub const expectEqualStrings = lib.testing.expectEqualStrings;
        pub const expectError = lib.testing.expectError;
    };
    testing.allocator = alloc;
    const test_spawn_config: lib.Thread.SpawnConfig = .{};

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
        fn addr4(port: u16) AddrPort {
            return AddrPort.from4(.{ 127, 0, 0, 1 }, port);
        }

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

        const RepeatingBodySource = struct {
            remaining: usize,
            byte: u8,

            pub fn read(self: *@This(), buf: []u8) anyerror!usize {
                if (self.remaining == 0) return 0;
                const n = @min(buf.len, self.remaining);
                @memset(buf[0..n], self.byte);
                self.remaining -= n;
                return n;
            }

            pub fn close(_: *@This()) void {}
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

        fn listenerPort(ln: net_mod.Listener, comptime NetNs: type) !u16 {
            const typed = try ln.as(NetNs.TcpListener);
            return typed.port();
        }

        pub fn localReturns200() !void {
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

        pub fn localReturns404() !void {
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

        pub fn defaultUserAgentMatches() !void {
            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "GET /user-agent-default HTTP/1.1"));
                        try testing.expectEqualStrings("embed-zig-http-client/1.0", headerValue(req_head, Http.Header.user_agent) orelse "");
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

        pub fn emptyUserAgentSuppressesDefault() !void {
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

        pub fn contextDeadlineExceeded() !void {
            try withOneShotServer(.{
                .expected_request_line = "GET /slow HTTP/1.1",
                .status_code = Http.status.ok,
                .body = "slow",
                .delay_ms = 150,
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{});
                    defer transport.deinit();

                    const Context = context_mod.make(lib);
                    var ctx_api = try Context.init(testing.allocator);
                    defer ctx_api.deinit();
                    var timeout_ctx = try ctx_api.withTimeout(ctx_api.background(), 30 * lib.time.ns_per_ms);
                    defer timeout_ctx.deinit();

                    const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/slow", .{port});
                    defer testing.allocator.free(url);

                    var req = try Http.Request.init(testing.allocator, "GET", url);
                    req = req.withContext(timeout_ctx);

                    try testing.expectError(error.DeadlineExceeded, transport.roundTrip(&req));
                }
            }.run);
        }

        pub fn responseHeaderTimeoutExceeded() !void {
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

        pub fn responseHeaderTimeoutDoesNotLimitBodyRead() !void {
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

        pub fn responseBodyReadCanceledByContext() !void {
            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "GET /body-cancel HTTP/1.1"));

                        io.writeAll(
                            @TypeOf(c),
                            &c,
                            "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n",
                        ) catch {};
                        lib.Thread.sleep(150 * lib.time.ns_per_ms);
                        io.writeAll(@TypeOf(c), &c, "late") catch {};
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *EmptyState) !void {
                        const Context = context_mod.make(lib);
                        var ctx_api = try Context.init(testing.allocator);
                        defer ctx_api.deinit();
                        var ctx = try ctx_api.withCancel(ctx_api.background());
                        defer ctx.deinit();

                        var transport = try Http.Transport.init(testing.allocator, .{});
                        defer transport.deinit();

                        const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/body-cancel", .{port});
                        defer testing.allocator.free(url);

                        var req = try Http.Request.init(testing.allocator, "GET", url);
                        req = req.withContext(ctx);

                        var resp = try transport.roundTrip(&req);
                        defer resp.deinit();

                        const cancel_thread = try lib.Thread.spawn(.{}, struct {
                            fn run(cancel_ctx: context_mod.Context, comptime thread_lib: type) void {
                                thread_lib.Thread.sleep(30 * thread_lib.time.ns_per_ms);
                                cancel_ctx.cancel();
                            }
                        }.run, .{ ctx, lib });
                        defer cancel_thread.join();

                        try testing.expectError(error.Canceled, readBody(resp));
                    }
                }.run,
            );
        }

        pub fn responseBodyReadDeadlineExceededByContext() !void {
            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "GET /body-deadline HTTP/1.1"));

                        io.writeAll(
                            @TypeOf(c),
                            &c,
                            "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n",
                        ) catch {};
                        lib.Thread.sleep(150 * lib.time.ns_per_ms);
                        io.writeAll(@TypeOf(c), &c, "late") catch {};
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *EmptyState) !void {
                        const Context = context_mod.make(lib);
                        var ctx_api = try Context.init(testing.allocator);
                        defer ctx_api.deinit();
                        var ctx = try ctx_api.withDeadline(ctx_api.background(), lib.time.nanoTimestamp() + 30 * lib.time.ns_per_ms);
                        defer ctx.deinit();

                        var transport = try Http.Transport.init(testing.allocator, .{});
                        defer transport.deinit();

                        const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/body-deadline", .{port});
                        defer testing.allocator.free(url);

                        var req = try Http.Request.init(testing.allocator, "GET", url);
                        req = req.withContext(ctx);

                        var resp = try transport.roundTrip(&req);
                        defer resp.deinit();

                        try testing.expectError(error.DeadlineExceeded, readBody(resp));
                    }
                }.run,
            );
        }

        pub fn requestBodyWriteCanceledByContext() !void {
            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "POST /upload-cancel HTTP/1.1"));
                        const head_end = lib.mem.indexOf(u8, req_head, "\r\n\r\n") orelse return error.TestUnexpectedResult;
                        if (req_head[head_end + 4 ..].len == 0) {
                            c.setReadTimeout(120);
                            try testing.expectEqual(@as(usize, 1), try c.read(req_buf[0..1]));
                        }
                        lib.Thread.sleep(150 * lib.time.ns_per_ms);
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *EmptyState) !void {
                        const Context = context_mod.make(lib);
                        var ctx_api = try Context.init(testing.allocator);
                        defer ctx_api.deinit();
                        var ctx = try ctx_api.withCancel(ctx_api.background());
                        defer ctx.deinit();

                        var transport = try Http.Transport.init(testing.allocator, .{});
                        defer transport.deinit();

                        const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/upload-cancel", .{port});
                        defer testing.allocator.free(url);

                        const payload_len = 32 * 1024 * 1024;
                        var source = RepeatingBodySource{
                            .remaining = payload_len,
                            .byte = 'w',
                        };

                        var req = try Http.Request.init(testing.allocator, "POST", url);
                        req = req.withContext(ctx).withBody(Http.ReadCloser.init(&source));
                        req.content_length = payload_len;

                        var task = RoundTripTask{
                            .transport = &transport,
                            .req = &req,
                        };
                        var thread = try lib.Thread.spawn(test_spawn_config, RoundTripTask.run, .{&task});
                        var joined = false;
                        defer if (!joined) thread.join();

                        try testing.expect(!task.waitTimeout(120));
                        ctx.cancel();
                        thread.join();
                        joined = true;
                        try testing.expectEqual(error.Canceled, task.err orelse return error.TestUnexpectedResult);
                    }
                }.run,
            );
        }

        pub fn requestBodyWriteDeadlineExceededByContext() !void {
            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "POST /upload-deadline HTTP/1.1"));
                        const head_end = lib.mem.indexOf(u8, req_head, "\r\n\r\n") orelse return error.TestUnexpectedResult;
                        if (req_head[head_end + 4 ..].len == 0) {
                            c.setReadTimeout(120);
                            try testing.expectEqual(@as(usize, 1), try c.read(req_buf[0..1]));
                        }
                        lib.Thread.sleep(150 * lib.time.ns_per_ms);
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *EmptyState) !void {
                        const Context = context_mod.make(lib);
                        var ctx_api = try Context.init(testing.allocator);
                        defer ctx_api.deinit();
                        var ctx = try ctx_api.withDeadline(ctx_api.background(), lib.time.nanoTimestamp() + 30 * lib.time.ns_per_ms);
                        defer ctx.deinit();

                        var transport = try Http.Transport.init(testing.allocator, .{});
                        defer transport.deinit();

                        const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/upload-deadline", .{port});
                        defer testing.allocator.free(url);

                        const payload_len = 32 * 1024 * 1024;
                        var source = RepeatingBodySource{
                            .remaining = payload_len,
                            .byte = 'd',
                        };

                        var req = try Http.Request.init(testing.allocator, "POST", url);
                        req = req.withContext(ctx).withBody(Http.ReadCloser.init(&source));
                        req.content_length = payload_len;

                        var task = RoundTripTask{
                            .transport = &transport,
                            .req = &req,
                        };
                        var thread = try lib.Thread.spawn(test_spawn_config, RoundTripTask.run, .{&task});
                        var joined = false;
                        defer if (!joined) thread.join();
                        thread.join();
                        joined = true;
                        try testing.expectEqual(error.DeadlineExceeded, task.err orelse return error.TestUnexpectedResult);
                    }
                }.run,
            );
        }

        pub fn chunkedRequestBodyWriteCanceledByContext() !void {
            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "POST /upload-chunked-cancel HTTP/1.1"));
                        try testing.expectEqualStrings("chunked", headerValue(req_head, Http.Header.transfer_encoding) orelse "");
                        try testing.expectEqualStrings("100-continue", headerValue(req_head, Http.Header.expect) orelse "");
                        const head_end = lib.mem.indexOf(u8, req_head, "\r\n\r\n") orelse return error.TestUnexpectedResult;
                        try testing.expectEqual(@as(usize, 0), req_head[head_end + 4 ..].len);
                        lib.Thread.sleep(150 * lib.time.ns_per_ms);
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *EmptyState) !void {
                        const Context = context_mod.make(lib);
                        var ctx_api = try Context.init(testing.allocator);
                        defer ctx_api.deinit();
                        var ctx = try ctx_api.withCancel(ctx_api.background());
                        defer ctx.deinit();

                        var transport = try Http.Transport.init(testing.allocator, .{});
                        defer transport.deinit();

                        const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/upload-chunked-cancel", .{port});
                        defer testing.allocator.free(url);

                        var source = ChunkedBodySource{ .chunks = &.{"cancel-me"} };

                        var req = try Http.Request.init(testing.allocator, "POST", url);
                        req = req.withContext(ctx).withBody(Http.ReadCloser.init(&source));
                        req.header = &.{Http.Header.init(Http.Header.expect, "100-continue")};

                        var task = RoundTripTask{
                            .transport = &transport,
                            .req = &req,
                        };
                        var thread = try lib.Thread.spawn(test_spawn_config, RoundTripTask.run, .{&task});
                        var joined = false;
                        defer if (!joined) thread.join();

                        try testing.expect(!task.waitTimeout(120));
                        ctx.cancel();
                        thread.join();
                        joined = true;
                        try testing.expectEqual(error.Canceled, task.err orelse return error.TestUnexpectedResult);
                    }
                }.run,
            );
        }

        pub fn chunkedRequestBodyWriteDeadlineExceededByContext() !void {
            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "POST /upload-chunked-deadline HTTP/1.1"));
                        try testing.expectEqualStrings("chunked", headerValue(req_head, Http.Header.transfer_encoding) orelse "");
                        try testing.expectEqualStrings("100-continue", headerValue(req_head, Http.Header.expect) orelse "");
                        const head_end = lib.mem.indexOf(u8, req_head, "\r\n\r\n") orelse return error.TestUnexpectedResult;
                        try testing.expectEqual(@as(usize, 0), req_head[head_end + 4 ..].len);
                        lib.Thread.sleep(150 * lib.time.ns_per_ms);
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *EmptyState) !void {
                        const Context = context_mod.make(lib);
                        var ctx_api = try Context.init(testing.allocator);
                        defer ctx_api.deinit();
                        var ctx = try ctx_api.withDeadline(ctx_api.background(), lib.time.nanoTimestamp() + 30 * lib.time.ns_per_ms);
                        defer ctx.deinit();

                        var transport = try Http.Transport.init(testing.allocator, .{});
                        defer transport.deinit();

                        const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/upload-chunked-deadline", .{port});
                        defer testing.allocator.free(url);

                        var source = ChunkedBodySource{ .chunks = &.{"deadline-me"} };

                        var req = try Http.Request.init(testing.allocator, "POST", url);
                        req = req.withContext(ctx).withBody(Http.ReadCloser.init(&source));
                        req.header = &.{Http.Header.init(Http.Header.expect, "100-continue")};

                        var task = RoundTripTask{
                            .transport = &transport,
                            .req = &req,
                        };
                        var thread = try lib.Thread.spawn(test_spawn_config, RoundTripTask.run, .{&task});
                        var joined = false;
                        defer if (!joined) thread.join();
                        thread.join();
                        joined = true;
                        try testing.expectEqual(error.DeadlineExceeded, task.err orelse return error.TestUnexpectedResult);
                    }
                }.run,
            );
        }

        pub fn responseBodyLargerThanMaxBodyBytesFails() !void {
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

        pub fn configuredMaxHeaderBytesAllowsLargeResponseHeaders() !void {
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
                        var transport = try Http.Transport.init(testing.allocator, .{
                            .max_header_bytes = 64 * 1024,
                        });
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

        pub fn largeResponseStreamsWithoutBufferingWholeBody() !void {
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

        pub fn defaultMaxBodyBytesAllowsLargeResponse() !void {
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

        pub fn largeRequestStreamsWithoutBufferingWholeBody() !void {
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

        pub fn defaultMaxBodyBytesAllowsLargeRequest() !void {
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

        pub fn connectMethodIsRejected() !void {
            var transport = try Http.Transport.init(testing.allocator, .{});
            defer transport.deinit();

            var req = try Http.Request.init(testing.allocator, "CONNECT", "http://example.com:443/");
            try testing.expectError(error.UnsupportedMethod, transport.roundTrip(&req));
        }

        pub fn httpsConnectProxyAuthRequired() !void {
            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "CONNECT example.com:443 HTTP/1.1"));
                        try testing.expectEqualStrings("proxy-test", headerValue(req_head, "X-Connect-Test") orelse "");
                        try testing.expectEqualStrings("example.com:443", headerValue(req_head, Http.Header.host) orelse "");
                        io.writeAll(@TypeOf(c), &c, "HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch {};
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *EmptyState) !void {
                        const proxy_raw_url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}", .{port});
                        defer testing.allocator.free(proxy_raw_url);

                        const connect_headers = [_]Http.Header{
                            Http.Header.init("X-Connect-Test", "proxy-test"),
                        };
                        var transport = try Http.Transport.init(testing.allocator, .{
                            .https_proxy = .{
                                .url = try net_mod.url.parse(proxy_raw_url),
                                .connect_headers = &connect_headers,
                            },
                        });
                        defer transport.deinit();

                        var req = try Http.Request.init(testing.allocator, "GET", "https://example.com/through-proxy");
                        try testing.expectError(error.ProxyAuthRequired, transport.roundTrip(&req));
                    }
                }.run,
            );
        }

        pub fn httpsConnectProxyAuthRequiredWithBody() !void {
            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "CONNECT example.com:443 HTTP/1.1"));
                        io.writeAll(@TypeOf(c), &c, "HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 5\r\nConnection: close\r\n\r\nblock") catch {};
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *EmptyState) !void {
                        const proxy_raw_url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}", .{port});
                        defer testing.allocator.free(proxy_raw_url);

                        var transport = try Http.Transport.init(testing.allocator, .{
                            .https_proxy = .{
                                .url = try net_mod.url.parse(proxy_raw_url),
                            },
                        });
                        defer transport.deinit();

                        var req = try Http.Request.init(testing.allocator, "GET", "https://example.com/through-proxy");
                        try testing.expectError(error.ProxyAuthRequired, transport.roundTrip(&req));
                    }
                }.run,
            );
        }

        pub fn httpsConnectProxyRejected() !void {
            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "CONNECT example.com:443 HTTP/1.1"));
                        io.writeAll(@TypeOf(c), &c, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch {};
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *EmptyState) !void {
                        const proxy_raw_url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}", .{port});
                        defer testing.allocator.free(proxy_raw_url);

                        var transport = try Http.Transport.init(testing.allocator, .{
                            .https_proxy = .{
                                .url = try net_mod.url.parse(proxy_raw_url),
                            },
                        });
                        defer transport.deinit();

                        var req = try Http.Request.init(testing.allocator, "GET", "https://example.com/rejected");
                        try testing.expectError(error.ProxyConnectFailed, transport.roundTrip(&req));
                    }
                }.run,
            );
        }

        pub fn httpsConnectProxyRejectedWithBody() !void {
            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "CONNECT example.com:443 HTTP/1.1"));
                        io.writeAll(@TypeOf(c), &c, "HTTP/1.1 403 Forbidden\r\nContent-Length: 6\r\nConnection: close\r\n\r\nreject") catch {};
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *EmptyState) !void {
                        const proxy_raw_url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}", .{port});
                        defer testing.allocator.free(proxy_raw_url);

                        var transport = try Http.Transport.init(testing.allocator, .{
                            .https_proxy = .{
                                .url = try net_mod.url.parse(proxy_raw_url),
                            },
                        });
                        defer transport.deinit();

                        var req = try Http.Request.init(testing.allocator, "GET", "https://example.com/rejected");
                        try testing.expectError(error.ProxyConnectFailed, transport.roundTrip(&req));
                    }
                }.run,
            );
        }

        pub fn httpsConnectProxyResponseHeaderTimeout() !void {
            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "CONNECT example.com:443 HTTP/1.1"));
                        lib.Thread.sleep(150 * lib.time.ns_per_ms);
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *EmptyState) !void {
                        const proxy_raw_url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}", .{port});
                        defer testing.allocator.free(proxy_raw_url);

                        var transport = try Http.Transport.init(testing.allocator, .{
                            .response_header_timeout_ms = 20,
                            .https_proxy = .{
                                .url = try net_mod.url.parse(proxy_raw_url),
                            },
                        });
                        defer transport.deinit();

                        var req = try Http.Request.init(testing.allocator, "GET", "https://example.com/connect-timeout");
                        try testing.expectError(error.TimedOut, transport.roundTrip(&req));
                    }
                }.run,
            );
        }

        pub fn httpsConnectProxyTlsInitFailureClosesTunnelConn() !void {
            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "CONNECT example.com:443 HTTP/1.1"));
                        try io.writeAll(@TypeOf(c), &c, "HTTP/1.1 200 Connection Established\r\nContent-Length: 0\r\n\r\n");

                        c.setReadTimeout(200);
                        var buf: [64]u8 = undefined;
                        const n = c.read(&buf) catch |err| switch (err) {
                            error.EndOfStream => return,
                            else => return err,
                        };
                        try testing.expectEqual(@as(usize, 0), n);
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *EmptyState) !void {
                        const proxy_raw_url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}", .{port});
                        defer testing.allocator.free(proxy_raw_url);

                        var transport = try Http.Transport.init(testing.allocator, .{
                            .https_proxy = .{
                                .url = try net_mod.url.parse(proxy_raw_url),
                            },
                            .tls_client_config = .{
                                .server_name = "example.com",
                                .min_version = .tls_1_3,
                                .max_version = .tls_1_2,
                            },
                        });
                        defer transport.deinit();

                        var req = try Http.Request.init(testing.allocator, "GET", "https://example.com/tls-init-cleanup");
                        try testing.expectError(error.Unexpected, transport.roundTrip(&req));
                    }
                }.run,
            );
        }

        pub fn httpsProxyUserinfoGeneratesProxyAuthorization() !void {
            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "CONNECT example.com:443 HTTP/1.1"));
                        try testing.expectEqualStrings("Basic dXNlcjpwQHNz", headerValue(req_head, Http.Header.proxy_authorization) orelse "");
                        try testing.expectEqual(@as(usize, 1), headerCount(req_head, Http.Header.proxy_authorization));
                        io.writeAll(@TypeOf(c), &c, "HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch {};
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *EmptyState) !void {
                        const proxy_raw_url = try lib.fmt.allocPrint(testing.allocator, "http://us%65r:p%40ss@127.0.0.1:{d}", .{port});
                        defer testing.allocator.free(proxy_raw_url);

                        var transport = try Http.Transport.init(testing.allocator, .{
                            .https_proxy = .{
                                .url = try net_mod.url.parse(proxy_raw_url),
                            },
                        });
                        defer transport.deinit();

                        var req = try Http.Request.init(testing.allocator, "GET", "https://example.com/userinfo-auth");
                        try testing.expectError(error.ProxyAuthRequired, transport.roundTrip(&req));
                    }
                }.run,
            );
        }

        pub fn httpsProxyInvalidPercentEncodingIsRejected() !void {
            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var c = conn;
                        c.setReadTimeout(100);
                        var buf: [64]u8 = undefined;
                        const n = c.read(&buf) catch |err| switch (err) {
                            error.EndOfStream,
                            error.TimedOut,
                            => 0,
                            else => return err,
                        };
                        try testing.expectEqual(@as(usize, 0), n);
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *EmptyState) !void {
                        const proxy_raw_url = try lib.fmt.allocPrint(testing.allocator, "http://user%4:pass@127.0.0.1:{d}", .{port});
                        defer testing.allocator.free(proxy_raw_url);

                        var transport = try Http.Transport.init(testing.allocator, .{
                            .https_proxy = .{
                                .url = try net_mod.url.parse(proxy_raw_url),
                            },
                        });
                        defer transport.deinit();

                        var req = try Http.Request.init(testing.allocator, "GET", "https://example.com/bad-userinfo");
                        try testing.expectError(error.InvalidProxy, transport.roundTrip(&req));
                    }
                }.run,
            );
        }

        pub fn httpsProxyOversizedUserinfoIsRejected() !void {
            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var c = conn;
                        c.setReadTimeout(100);
                        var buf: [64]u8 = undefined;
                        const n = c.read(&buf) catch |err| switch (err) {
                            error.EndOfStream,
                            error.TimedOut,
                            => 0,
                            else => return err,
                        };
                        try testing.expectEqual(@as(usize, 0), n);
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *EmptyState) !void {
                        const oversized_user = try testing.allocator.alloc(u8, 32 * 1024);
                        defer testing.allocator.free(oversized_user);
                        @memset(oversized_user, 'u');

                        const proxy_raw_url = try lib.fmt.allocPrint(testing.allocator, "http://{s}:pass@127.0.0.1:{d}", .{ oversized_user, port });
                        defer testing.allocator.free(proxy_raw_url);

                        var transport = try Http.Transport.init(testing.allocator, .{
                            .https_proxy = .{
                                .url = try net_mod.url.parse(proxy_raw_url),
                            },
                        });
                        defer transport.deinit();

                        var req = try Http.Request.init(testing.allocator, "GET", "https://example.com/oversized-userinfo");
                        try testing.expectError(error.InvalidProxy, transport.roundTrip(&req));
                    }
                }.run,
            );
        }

        pub fn httpsProxyConnectHeadersOverrideUrlUserinfo() !void {
            try withServerState(
                EmptyState{},
                struct {
                    fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "CONNECT example.com:443 HTTP/1.1"));
                        try testing.expectEqualStrings("Basic ZXhwbGljaXQ=", headerValue(req_head, Http.Header.proxy_authorization) orelse "");
                        try testing.expectEqual(@as(usize, 1), headerCount(req_head, Http.Header.proxy_authorization));
                        try testing.expectEqualStrings("proxy-test", headerValue(req_head, "X-Connect-Test") orelse "");
                        io.writeAll(@TypeOf(c), &c, "HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch {};
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *EmptyState) !void {
                        const proxy_raw_url = try lib.fmt.allocPrint(testing.allocator, "http://user:pass@127.0.0.1:{d}", .{port});
                        defer testing.allocator.free(proxy_raw_url);

                        const connect_headers = [_]Http.Header{
                            Http.Header.init(Http.Header.proxy_authorization, "Basic ZXhwbGljaXQ="),
                            Http.Header.init("X-Connect-Test", "proxy-test"),
                        };
                        var transport = try Http.Transport.init(testing.allocator, .{
                            .https_proxy = .{
                                .url = try net_mod.url.parse(proxy_raw_url),
                                .connect_headers = &connect_headers,
                            },
                        });
                        defer transport.deinit();

                        var req = try Http.Request.init(testing.allocator, "GET", "https://example.com/userinfo-override");
                        try testing.expectError(error.ProxyAuthRequired, transport.roundTrip(&req));
                    }
                }.run,
            );
        }

        pub fn idleConnectionIsReused() !void {
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

        pub fn closeIdleConnectionsForcesNewConn() !void {
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

        pub fn disableKeepAlivesForcesNewConn() !void {
            const accept_count = try withTwoRequestKeepAliveServer(.{
                .first_request_line = "GET /disable-keepalive-1 HTTP/1.1",
                .second_request_line = "GET /disable-keepalive-2 HTTP/1.1",
                .first_body = "one",
                .second_body = "two",
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{
                        .disable_keep_alives = true,
                    });
                    defer transport.deinit();

                    const url1 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/disable-keepalive-1", .{port});
                    defer testing.allocator.free(url1);
                    const url2 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/disable-keepalive-2", .{port});
                    defer testing.allocator.free(url2);

                    var req1 = try Http.Request.init(testing.allocator, "GET", url1);
                    var resp1 = try transport.roundTrip(&req1);
                    defer resp1.deinit();
                    const body1 = try readBody(resp1);
                    defer testing.allocator.free(body1);
                    try testing.expectEqualStrings("one", body1);

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

        pub fn maxIdleConnsOneKeepsOnlyOneIdleConnAcrossHosts() !void {
            var ln1 = try Net.listen(testing.allocator, .{
                .address = addr4(0),
            });
            defer ln1.deinit();
            var ln2 = try Net.listen(testing.allocator, .{
                .address = addr4(0),
            });
            defer ln2.deinit();

            const listener1 = try ln1.as(Net.TcpListener);
            const listener2 = try ln2.as(Net.TcpListener);
            const port1 = try listenerPort(ln1, Net);
            const port2 = try listenerPort(ln2, Net);

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
                    serveTwoKeepAliveRequests(tcp_listener, spec, accepts) catch |err| {
                        result.* = err;
                    };
                }
            }.run, .{ listener1, spec1, &accept_count1, &server_result1 });
            var joined1 = false;
            defer if (!joined1) server_thread1.join();

            var server_thread2 = try lib.Thread.spawn(.{}, struct {
                fn run(tcp_listener: *Net.TcpListener, spec: TwoRequestSpec, accepts: *usize, result: *?anyerror) void {
                    serveTwoKeepAliveRequests(tcp_listener, spec, accepts) catch |err| {
                        result.* = err;
                    };
                }
            }.run, .{ listener2, spec2, &accept_count2, &server_result2 });
            var joined2 = false;
            defer if (!joined2) server_thread2.join();

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
            const body1 = try readBody(resp1);
            defer testing.allocator.free(body1);
            try testing.expectEqualStrings("one", body1);

            var req2 = try Http.Request.init(testing.allocator, "GET", url2);
            var resp2 = try transport.roundTrip(&req2);
            defer resp2.deinit();
            const body2 = try readBody(resp2);
            defer testing.allocator.free(body2);
            try testing.expectEqualStrings("two", body2);

            var req3 = try Http.Request.init(testing.allocator, "GET", url3);
            var resp3 = try transport.roundTrip(&req3);
            defer resp3.deinit();
            const body3 = try readBody(resp3);
            defer testing.allocator.free(body3);
            try testing.expectEqualStrings("three", body3);

            var req4 = try Http.Request.init(testing.allocator, "GET", url4);
            var resp4 = try transport.roundTrip(&req4);
            defer resp4.deinit();
            const body4 = try readBody(resp4);
            defer testing.allocator.free(body4);
            try testing.expectEqualStrings("four", body4);

            server_thread1.join();
            joined1 = true;
            server_thread2.join();
            joined2 = true;

            if (server_result1) |err| return err;
            if (server_result2) |err| return err;
            try testing.expectEqual(@as(usize, 3), accept_count1 + accept_count2);
        }

        pub fn maxIdleConnsPerHostOneKeepsOnlyOneIdleConn() !void {
            var ln = try Net.listen(testing.allocator, .{
                .address = addr4(0),
            });
            defer ln.deinit();

            const listener = try ln.as(Net.TcpListener);
            const port = try listenerPort(ln, Net);
            var accept_count: usize = 0;
            var server_result: ?anyerror = null;

            var server_thread = try lib.Thread.spawn(.{}, struct {
                fn writePathResponse(conn: net_mod.Conn, req_head: []const u8) !void {
                    var c = conn;
                    const body = if (hasRequestLine(req_head, "GET /idle-per-host-1 HTTP/1.1"))
                        "one"
                    else if (hasRequestLine(req_head, "GET /idle-per-host-2 HTTP/1.1"))
                        "two"
                    else if (hasRequestLine(req_head, "GET /idle-per-host-3 HTTP/1.1"))
                        "three"
                    else if (hasRequestLine(req_head, "GET /idle-per-host-4 HTTP/1.1"))
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
                        const req_head = readRequestHead(owned, &req_buf) catch |err| switch (err) {
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
                        const req_head = readRequestHead(conn, &req_buf) catch |err| {
                            conn.deinit();
                            result.* = err;
                            return;
                        };
                        if (lib.mem.eql(u8, req_head, "PING")) {
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

            const body1 = try readBody(resp1);
            defer testing.allocator.free(body1);
            try testing.expectEqualStrings("one", body1);
            resp1.deinit();

            const body2 = try readBody(resp2);
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

            const body4 = try readBody(resp4);
            defer testing.allocator.free(body4);
            try testing.expectEqualStrings("four", body4);
            resp4.deinit();

            const body3 = try readBody(resp3);
            defer testing.allocator.free(body3);
            try testing.expectEqualStrings("three", body3);
            resp3.deinit();

            var probe = try Net.dial(testing.allocator, .tcp, addr4(port));
            try io.writeAll(@TypeOf(probe), &probe, "PING");
            probe.deinit();

            server_thread.join();
            server_joined = true;
            if (server_result) |err| return err;
            try testing.expectEqual(@as(usize, 3), accept_count);
        }

        pub fn earlyResponseBodyCloseDoesNotReuseConn() !void {
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

        pub fn idleConnectionTimeoutForcesNewConn() !void {
            const accept_count = try withTwoRequestKeepAliveServer(.{
                .first_request_line = "GET /idle-timeout-1 HTTP/1.1",
                .second_request_line = "GET /idle-timeout-2 HTTP/1.1",
                .first_body = "one",
                .second_body = "two",
                .reuse_wait_timeout_ms = 150,
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

                    lib.Thread.sleep(80 * lib.time.ns_per_ms);

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

        pub fn sameHostRequestWhileBodyOpenUsesSecondConn() !void {
            const accept_count = try withTwoRequestKeepAliveServer(.{
                .first_request_line = "GET /body-open-1 HTTP/1.1",
                .second_request_line = "GET /body-open-2 HTTP/1.1",
                .first_body = "hello",
                .second_body = "world",
                .reuse_wait_timeout_ms = 150,
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
                    var thread = try lib.Thread.spawn(test_spawn_config, RoundTripTask.run, .{&task});
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

        pub fn maxConnsPerHostOneBlocksSecondRequestUntilFirstResponseCloses() !void {
            const accept_count = try withTwoRequestKeepAliveServer(.{
                .first_request_line = "GET /max-conns-1 HTTP/1.1",
                .second_request_line = "GET /max-conns-2 HTTP/1.1",
                .first_body = "hello",
                .second_body = "world",
                .reuse_wait_timeout_ms = 150,
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{
                        .max_conns_per_host = 1,
                    });
                    defer transport.deinit();

                    const url1 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/max-conns-1", .{port});
                    defer testing.allocator.free(url1);
                    const url2 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/max-conns-2", .{port});
                    defer testing.allocator.free(url2);

                    var req1 = try Http.Request.init(testing.allocator, "GET", url1);
                    var resp1 = try transport.roundTrip(&req1);

                    var req2 = try Http.Request.init(testing.allocator, "GET", url2);
                    var task = RoundTripTask{
                        .transport = &transport,
                        .req = &req2,
                    };
                    var thread = try lib.Thread.spawn(test_spawn_config, RoundTripTask.run, .{&task});
                    var joined = false;
                    defer if (!joined) thread.join();

                    try testing.expect(!task.waitTimeout(120));
                    resp1.deinit();
                    thread.join();
                    joined = true;

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

        pub fn maxConnsPerHostTwoAllowsSecondLiveConn() !void {
            const accept_count = try withTwoRequestKeepAliveServer(.{
                .first_request_line = "GET /max-two-1 HTTP/1.1",
                .second_request_line = "GET /max-two-2 HTTP/1.1",
                .first_body = "hello",
                .second_body = "world",
                .reuse_wait_timeout_ms = 150,
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{
                        .max_conns_per_host = 2,
                    });
                    defer transport.deinit();

                    const url1 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/max-two-1", .{port});
                    defer testing.allocator.free(url1);
                    const url2 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/max-two-2", .{port});
                    defer testing.allocator.free(url2);

                    var req1 = try Http.Request.init(testing.allocator, "GET", url1);
                    var resp1 = try transport.roundTrip(&req1);
                    defer resp1.deinit();

                    var req2 = try Http.Request.init(testing.allocator, "GET", url2);
                    var task = RoundTripTask{
                        .transport = &transport,
                        .req = &req2,
                    };
                    var thread = try lib.Thread.spawn(test_spawn_config, RoundTripTask.run, .{&task});
                    thread.join();
                    try testing.expect(task.finished);
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

        pub fn maxConnsPerHostWaiterReusesReturnedIdleConn() !void {
            const accept_count = try withTwoRequestKeepAliveServer(.{
                .first_request_line = "GET /max-reuse-1 HTTP/1.1",
                .second_request_line = "GET /max-reuse-2 HTTP/1.1",
                .first_body = "hello",
                .second_body = "world",
                .reuse_wait_timeout_ms = 150,
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{
                        .max_conns_per_host = 1,
                    });
                    defer transport.deinit();

                    const url1 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/max-reuse-1", .{port});
                    defer testing.allocator.free(url1);
                    const url2 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/max-reuse-2", .{port});
                    defer testing.allocator.free(url2);

                    var req1 = try Http.Request.init(testing.allocator, "GET", url1);
                    var resp1 = try transport.roundTrip(&req1);
                    defer resp1.deinit();
                    const body1 = resp1.body() orelse return error.TestUnexpectedResult;
                    var first: [1]u8 = undefined;
                    try testing.expectEqual(@as(usize, 1), try body1.read(&first));

                    var req2 = try Http.Request.init(testing.allocator, "GET", url2);
                    var task = RoundTripTask{
                        .transport = &transport,
                        .req = &req2,
                    };
                    var thread = try lib.Thread.spawn(test_spawn_config, RoundTripTask.run, .{&task});
                    var joined = false;
                    defer if (!joined) thread.join();

                    try testing.expect(!task.waitTimeout(120));
                    const rest1 = try readBody(resp1);
                    defer testing.allocator.free(rest1);
                    thread.join();
                    joined = true;

                    if (task.err) |err| return err;
                    var resp2 = task.resp orelse return error.TestUnexpectedResult;
                    defer resp2.deinit();

                    const body2 = try readBody(resp2);
                    defer testing.allocator.free(body2);
                    try testing.expectEqualStrings("world", body2);
                }
            }.run);

            try testing.expectEqual(@as(usize, 1), accept_count);
        }

        pub fn maxConnsPerHostWaiterDeadlineExceeded() !void {
            const State = struct {};
            try withServerState(
                State{},
                struct {
                    fn run(conn: net_mod.Conn, _: *State) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "GET /max-deadline-1 HTTP/1.1"));
                        io.writeAll(@TypeOf(c), &c, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: keep-alive\r\n\r\nhello") catch {};
                        c.setReadTimeout(80);
                        _ = c.read(&req_buf) catch |err| switch (err) {
                            error.TimedOut, error.EndOfStream => return,
                            else => return err,
                        };
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *State) !void {
                        var transport = try Http.Transport.init(testing.allocator, .{
                            .max_conns_per_host = 1,
                        });
                        defer transport.deinit();

                        const Context = context_mod.make(lib);
                        var ctx_api = try Context.init(testing.allocator);
                        defer ctx_api.deinit();

                        const url1 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/max-deadline-1", .{port});
                        defer testing.allocator.free(url1);
                        const url2 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/max-deadline-2", .{port});
                        defer testing.allocator.free(url2);

                        var req1 = try Http.Request.init(testing.allocator, "GET", url1);
                        var resp1 = try transport.roundTrip(&req1);
                        defer resp1.deinit();

                        var timeout_ctx = try ctx_api.withTimeout(ctx_api.background(), 30 * lib.time.ns_per_ms);
                        defer timeout_ctx.deinit();
                        var req2 = try Http.Request.init(testing.allocator, "GET", url2);
                        req2 = req2.withContext(timeout_ctx);

                        try testing.expectError(error.DeadlineExceeded, transport.roundTrip(&req2));
                    }
                }.run,
            );
        }

        pub fn maxConnsPerHostWaiterCanceled() !void {
            const State = struct {};
            try withServerState(
                State{},
                struct {
                    fn run(conn: net_mod.Conn, _: *State) !void {
                        var c = conn;
                        var req_buf: [4096]u8 = undefined;
                        const req_head = try readRequestHead(conn, &req_buf);
                        try testing.expect(hasRequestLine(req_head, "GET /max-cancel-1 HTTP/1.1"));
                        io.writeAll(@TypeOf(c), &c, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: keep-alive\r\n\r\nhello") catch {};
                        c.setReadTimeout(120);
                        _ = c.read(&req_buf) catch |err| switch (err) {
                            error.TimedOut, error.EndOfStream => return,
                            else => return err,
                        };
                    }
                }.run,
                struct {
                    fn run(port: u16, _: *State) !void {
                        var transport = try Http.Transport.init(testing.allocator, .{
                            .max_conns_per_host = 1,
                        });
                        defer transport.deinit();

                        const Context = context_mod.make(lib);
                        var ctx_api = try Context.init(testing.allocator);
                        defer ctx_api.deinit();

                        const url1 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/max-cancel-1", .{port});
                        defer testing.allocator.free(url1);
                        const url2 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/max-cancel-2", .{port});
                        defer testing.allocator.free(url2);

                        var req1 = try Http.Request.init(testing.allocator, "GET", url1);
                        var resp1 = try transport.roundTrip(&req1);
                        defer resp1.deinit();

                        var cancel_ctx = try ctx_api.withCancel(ctx_api.background());
                        defer cancel_ctx.deinit();
                        var req2 = try Http.Request.init(testing.allocator, "GET", url2);
                        req2 = req2.withContext(cancel_ctx);

                        var task = RoundTripTask{
                            .transport = &transport,
                            .req = &req2,
                        };
                        var thread = try lib.Thread.spawn(test_spawn_config, RoundTripTask.run, .{&task});
                        var joined = false;
                        defer if (!joined) thread.join();
                        try testing.expect(!task.waitTimeout(120));
                        cancel_ctx.cancel();
                        thread.join();
                        joined = true;

                        try testing.expect(task.err != null);
                        try testing.expectEqual(error.Canceled, task.err.?);
                    }
                }.run,
            );
        }

        pub fn closeIdleConnectionsWithMaxConnsPerHostDoesNotLeakCapacity() !void {
            const accept_count = try withTwoRequestKeepAliveServer(.{
                .first_request_line = "GET /close-idle-max-1 HTTP/1.1",
                .second_request_line = "GET /close-idle-max-2 HTTP/1.1",
                .first_body = "one",
                .second_body = "two",
            }, struct {
                fn run(port: u16) !void {
                    var transport = try Http.Transport.init(testing.allocator, .{
                        .max_conns_per_host = 1,
                    });
                    defer transport.deinit();

                    const url1 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/close-idle-max-1", .{port});
                    defer testing.allocator.free(url1);
                    const url2 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/close-idle-max-2", .{port});
                    defer testing.allocator.free(url2);

                    var req1 = try Http.Request.init(testing.allocator, "GET", url1);
                    var resp1 = try transport.roundTrip(&req1);
                    const body1 = try readBody(resp1);
                    defer testing.allocator.free(body1);
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

        pub fn staleIdleConnectionRetriesReplayableGet() !void {
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

        pub fn staleIdleConnectionRetriesIdempotentReplayablePost() !void {
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

        pub fn chunkedRequestUsesTransferEncoding() !void {
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

        pub fn chunkedResponseStreams() !void {
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

        pub fn eofDelimitedResponseStreams() !void {
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

        pub fn headResponseIsBodyless() !void {
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

        pub fn status204ResponseIsBodyless() !void {
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

        pub fn status304ResponseIsBodyless() !void {
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

        pub fn informationalContinueThenFinalResponse() !void {
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

        pub fn expectContinueTimeoutSendsBodyWithoutInformational() !void {
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

        pub fn finalResponseWithoutContinueSkipsRequestBody() !void {
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

        pub fn requestBodyStreamsBeforeRoundTripCompletes() !void {
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
                        var thread = try lib.Thread.spawn(test_spawn_config, RoundTripTask.run, .{&task});

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

        pub fn responseBodyStreamsProgressively() !void {
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

        pub fn fullDuplexRequestAndResponse() !void {
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

        pub fn bodylessEarlyResponseDoesNotWaitForBlockedRequestBody() !void {
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
                .address = addr4(0),
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
            var server_joined = false;
            errdefer if (!server_joined) server_thread.join();

            try ClientFn(port);
            server_thread.join();
            server_joined = true;
            if (server_result) |err| return err;
            return accept_count;
        }

        fn withStaleIdleRetryServer(spec: StaleIdleRetrySpec, comptime ClientFn: anytype) !usize {
            var ln = try Net.listen(testing.allocator, .{
                .address = addr4(0),
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
            var server_joined = false;
            errdefer if (!server_joined) server_thread.join();

            try ClientFn(port);
            server_thread.join();
            server_joined = true;
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
                .address = addr4(0),
            });
            defer ln.deinit();

            const listener_impl = try ln.as(Net.TcpListener);
            const port = try listenerPort(ln, Net);
            var server_result: ?anyerror = null;
            var server_thread = try lib.Thread.spawn(.{}, struct {
                fn run(tcp_listener: *Net.TcpListener, server_spec: ServerSpec, result: *?anyerror) void {
                    var conn = tcp_listener.accept() catch |err| {
                        result.* = err;
                        return;
                    };
                    defer conn.deinit();

                    var req_buf: [4096]u8 = undefined;
                    const req_head = readRequestHead(conn, &req_buf) catch |err| {
                        result.* = err;
                        return;
                    };

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
                    ) catch |err| {
                        result.* = err;
                        return;
                    };
                    io.writeAll(@TypeOf(conn), &conn, head) catch |err| switch (err) {
                        error.BrokenPipe,
                        error.ConnectionReset,
                        => return,
                        else => {
                            result.* = err;
                            return;
                        },
                    };
                    io.writeAll(@TypeOf(conn), &conn, body) catch |err| switch (err) {
                        error.BrokenPipe,
                        error.ConnectionReset,
                        => return,
                        else => {
                            result.* = err;
                            return;
                        },
                    };
                }
            }.run, .{ listener_impl, spec, &server_result });
            var server_joined = false;
            errdefer if (!server_joined) server_thread.join();

            try ClientFn(port);
            server_thread.join();
            server_joined = true;
            if (server_result) |err| return err;
        }

        fn withServerState(state_init: anytype, comptime ServerFn: anytype, comptime ClientFn: anytype) !void {
            const State = @TypeOf(state_init);
            var state = state_init;
            var ln = try Net.listen(testing.allocator, .{
                .address = addr4(0),
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
            var server_joined = false;
            errdefer if (!server_joined) server_thread.join();

            try ClientFn(port, &state);
            server_thread.join();
            server_joined = true;
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

        fn headerCount(head: []const u8, name: []const u8) usize {
            var count: usize = 0;
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
                if (Http.Header.init(header_name, "").is(name)) count += 1;
                if (line_start + rel_end == head.len) break;
                line_start += rel_end + 2;
            }
            return count;
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

    try run_cases(lib, Runner);
}
