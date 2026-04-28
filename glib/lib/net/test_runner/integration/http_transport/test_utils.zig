//! Shared harness and IO helpers for HTTP transport integration cases.

const io = @import("io");

pub fn make2(comptime std: type, comptime net: type) type {
    const NetNs = net;
    const HttpNs = NetNs.http;
    const AddrPort = net.netip.AddrPort;

    return struct {
        pub const Http = HttpNs;
        pub const Net = NetNs;
        pub const test_spawn_config: std.Thread.SpawnConfig = .{};

        pub const testing = struct {
            pub const expect = std.testing.expect;
            pub const expectEqual = std.testing.expectEqual;
            pub const expectEqualStrings = std.testing.expectEqualStrings;
            pub const expectError = std.testing.expectError;
        };

        pub fn addr4(port: u16) AddrPort {
            return AddrPort.from4(.{ 127, 0, 0, 1 }, port);
        }

        pub fn listenerPort(ln: net.Listener, comptime NetApi: type) !u16 {
            const typed = try ln.as(NetApi.TcpListener);
            return typed.port();
        }

        pub fn withTwoRequestKeepAliveServer(
            allocator: std.mem.Allocator,
            spec: anytype,
            comptime ClientFn: anytype,
        ) !usize {
            var ln = try NetNs.listen(allocator, .{
                .address = addr4(0),
            });
            defer ln.deinit();

            const listener_impl = try ln.as(NetNs.TcpListener);
            const port = try listenerPort(ln, NetNs);
            var accept_count: usize = 0;
            var server_result: ?anyerror = null;

            var server_thread = try std.Thread.spawn(.{}, struct {
                fn run(tcp_listener: *NetNs.TcpListener, server_spec: @TypeOf(spec), accepts: *usize, result: *?anyerror) void {
                    serveTwoKeepAliveRequests(tcp_listener, server_spec, accepts) catch |err| {
                        result.* = err;
                    };
                }
            }.run, .{ listener_impl, spec, &accept_count, &server_result });
            var server_joined = false;
            errdefer {
                if (!server_joined) {
                    ln.close();
                    server_thread.join();
                }
            }

            try ClientFn(allocator, port);
            ln.close();
            server_thread.join();
            server_joined = true;
            if (server_result) |err| return err;
            return accept_count;
        }

        pub fn withStaleIdleRetryServer(
            allocator: std.mem.Allocator,
            spec: anytype,
            comptime ClientFn: anytype,
        ) !usize {
            var ln = try NetNs.listen(allocator, .{
                .address = addr4(0),
            });
            defer ln.deinit();

            const listener_impl = try ln.as(NetNs.TcpListener);
            const port = try listenerPort(ln, NetNs);
            var accept_count: usize = 0;
            var server_result: ?anyerror = null;

            var server_thread = try std.Thread.spawn(.{}, struct {
                fn run(tcp_listener: *NetNs.TcpListener, server_spec: @TypeOf(spec), accepts: *usize, result: *?anyerror) void {
                    serveStaleIdleRetryRequests(tcp_listener, server_spec, accepts) catch |err| {
                        result.* = err;
                    };
                }
            }.run, .{ listener_impl, spec, &accept_count, &server_result });
            var server_joined = false;
            errdefer {
                if (!server_joined) {
                    ln.close();
                    server_thread.join();
                }
            }

            try ClientFn(allocator, port);
            ln.close();
            server_thread.join();
            server_joined = true;
            if (server_result) |err| return err;
            return accept_count;
        }

        pub fn withRedirectServer(
            allocator: std.mem.Allocator,
            spec: anytype,
            comptime ClientFn: anytype,
        ) !usize {
            var ln = try NetNs.listen(allocator, .{
                .address = addr4(0),
            });
            defer ln.deinit();

            const listener_impl = try ln.as(NetNs.TcpListener);
            const port = try listenerPort(ln, NetNs);
            var accept_count: usize = 0;
            var server_result: ?anyerror = null;

            var server_thread = try std.Thread.spawn(.{}, struct {
                fn run(tcp_listener: *NetNs.TcpListener, server_spec: @TypeOf(spec), accepts: *usize, result: *?anyerror) void {
                    serveRedirectRequests(tcp_listener, server_spec, accepts) catch |err| {
                        result.* = err;
                    };
                }
            }.run, .{ listener_impl, spec, &accept_count, &server_result });
            var server_joined = false;
            errdefer {
                if (!server_joined) {
                    ln.close();
                    server_thread.join();
                }
            }

            try ClientFn(allocator, port);
            ln.close();
            server_thread.join();
            server_joined = true;
            if (server_result) |err| return err;
            return accept_count;
        }

        pub fn withOneShotServer(
            allocator: std.mem.Allocator,
            spec: anytype,
            comptime ClientFn: anytype,
        ) !void {
            var ln = try NetNs.listen(allocator, .{
                .address = addr4(0),
            });
            defer ln.deinit();

            const listener_impl = try ln.as(NetNs.TcpListener);
            const port = try listenerPort(ln, NetNs);
            var server_result: ?anyerror = null;
            var server_thread = try std.Thread.spawn(.{}, struct {
                fn run(tcp_listener: *NetNs.TcpListener, server_spec: @TypeOf(spec), result: *?anyerror) void {
                    var conn = tcp_listener.accept() catch |err| switch (err) {
                        error.Closed => return,
                        else => {
                            result.* = err;
                            return;
                        },
                    };
                    defer conn.deinit();

                    var req_buf: [4096]u8 = undefined;
                    const req_head = readRequestHead(conn, &req_buf) catch |err| {
                        result.* = err;
                        return;
                    };

                    const line_matches = hasRequestLine(req_head, server_spec.expected_request_line);
                    const body_matches = if (line_matches)
                        if (serverExpectedRequestBody(server_spec)) |expected_body|
                            requestBodyMatches(conn, req_head, expected_body)
                        else
                            true
                    else
                        false;
                    const matched = line_matches and body_matches;
                    const status_code = if (matched) server_spec.status_code else HttpNs.status.internal_server_error;
                    const body = if (matched)
                        server_spec.body
                    else if (!line_matches)
                        "unexpected request line"
                    else
                        "unexpected request body";
                    const content_type = serverContentType(server_spec);

                    if (serverDelayMs(server_spec) != 0) {
                        std.Thread.sleep(@intCast(@as(net.time.duration.Duration, @intCast(serverDelayMs(server_spec))) * net.time.duration.MilliSecond));
                    }

                    const reason = HttpNs.status.text(status_code) orelse "Unknown";
                    var head_buf: [256]u8 = undefined;
                    const head = std.fmt.bufPrint(
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
            errdefer {
                if (!server_joined) {
                    ln.close();
                    server_thread.join();
                }
            }

            try ClientFn(allocator, port);
            ln.close();
            server_thread.join();
            server_joined = true;
            if (server_result) |err| return err;
        }

        pub fn withServerState(
            allocator: std.mem.Allocator,
            state_init: anytype,
            comptime ServerFn: anytype,
            comptime ClientFn: anytype,
        ) !void {
            const State = @TypeOf(state_init);
            var state = state_init;
            var ln = try NetNs.listen(allocator, .{
                .address = addr4(0),
            });
            defer ln.deinit();

            const listener_impl = try ln.as(NetNs.TcpListener);
            const port = try listenerPort(ln, NetNs);
            var server_result: ?anyerror = null;

            var server_thread = try std.Thread.spawn(.{}, struct {
                fn run(tcp_listener: *NetNs.TcpListener, state_ptr: *State, result: *?anyerror) void {
                    var conn = tcp_listener.accept() catch |err| switch (err) {
                        error.Closed => return,
                        else => {
                            result.* = err;
                            return;
                        },
                    };
                    defer conn.deinit();

                    ServerFn(conn, state_ptr) catch |err| {
                        result.* = err;
                    };
                }
            }.run, .{ listener_impl, &state, &server_result });
            var server_joined = false;
            errdefer {
                if (!server_joined) {
                    ln.close();
                    server_thread.join();
                }
            }

            try ClientFn(allocator, port, &state);
            ln.close();
            server_thread.join();
            server_joined = true;
            if (server_result) |err| return err;
        }

        pub fn readRequestHead(conn: net.Conn, buf: *[4096]u8) ![]const u8 {
            var filled: usize = 0;
            while (filled < buf.len) {
                const n = try conn.read(buf[filled..]);
                if (n == 0) break;
                filled += n;
                if (std.mem.indexOf(u8, buf[0..filled], "\r\n\r\n") != null) break;
            }
            return buf[0..filled];
        }

        pub fn hasRequestLine(req_head: []const u8, expected: []const u8) bool {
            const line_end = std.mem.indexOf(u8, req_head, "\r\n") orelse req_head.len;
            return std.mem.eql(u8, req_head[0..line_end], expected);
        }

        pub fn requestBodyMatches(conn: net.Conn, req_head: []const u8, expected: []const u8) bool {
            var c = conn;
            const head_end = std.mem.indexOf(u8, req_head, "\r\n\r\n") orelse return false;
            const content_length_value = headerValue(req_head[0..head_end], Http.Header.content_length) orelse return false;
            const content_length = std.fmt.parseInt(usize, content_length_value, 10) catch return false;
            if (content_length != expected.len) return false;

            const prefix = req_head[head_end + 4 ..];
            if (prefix.len > expected.len) return false;
            if (!std.mem.eql(u8, prefix, expected[0..prefix.len])) return false;

            var matched: usize = prefix.len;
            var buf: [1024]u8 = undefined;
            while (matched < expected.len) {
                const want = @min(buf.len, expected.len - matched);
                io.readFull(@TypeOf(c), &c, buf[0..want]) catch return false;
                if (!std.mem.eql(u8, buf[0..want], expected[matched..][0..want])) return false;
                matched += want;
            }

            return true;
        }

        pub fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
            var line_start: usize = 0;
            while (line_start < head.len) {
                const rel_end = std.mem.indexOf(u8, head[line_start..], "\r\n") orelse head.len - line_start;
                const line = head[line_start .. line_start + rel_end];
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
                    if (line_start + rel_end == head.len) break;
                    line_start += rel_end + 2;
                    continue;
                };

                const header_name = std.mem.trim(u8, line[0..colon], " ");
                if (HttpNs.Header.init(header_name, "").is(name)) {
                    return std.mem.trim(u8, line[colon + 1 ..], " ");
                }
                if (line_start + rel_end == head.len) break;
                line_start += rel_end + 2;
            }

            return null;
        }

        pub fn headerCount(head: []const u8, name: []const u8) usize {
            var count: usize = 0;
            var line_start: usize = 0;
            while (line_start < head.len) {
                const rel_end = std.mem.indexOf(u8, head[line_start..], "\r\n") orelse head.len - line_start;
                const line = head[line_start .. line_start + rel_end];
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
                    if (line_start + rel_end == head.len) break;
                    line_start += rel_end + 2;
                    continue;
                };

                const header_name = std.mem.trim(u8, line[0..colon], " ");
                if (HttpNs.Header.init(header_name, "").is(name)) count += 1;
                if (line_start + rel_end == head.len) break;
                line_start += rel_end + 2;
            }
            return count;
        }

        pub fn readUntilTerminator(
            allocator: std.mem.Allocator,
            conn: net.Conn,
            prefix: []const u8,
            terminator: []const u8,
        ) ![]u8 {
            var c = conn;
            var bytes = try std.ArrayList(u8).initCapacity(allocator, prefix.len);
            errdefer bytes.deinit(allocator);
            try bytes.appendSlice(allocator, prefix);

            var buf: [128]u8 = undefined;
            while (true) {
                if (bytes.items.len >= terminator.len and std.mem.eql(u8, bytes.items[bytes.items.len - terminator.len ..], terminator)) {
                    return bytes.toOwnedSlice(allocator);
                }

                const n = try c.read(&buf);
                if (n == 0) return error.EndOfStream;
                try bytes.appendSlice(allocator, buf[0..n]);
            }
        }

        pub fn readExpectedBytes(conn: net.Conn, prefix: []const u8, out: []u8) !void {
            if (prefix.len > out.len) return error.TestUnexpectedResult;
            @memcpy(out[0..prefix.len], prefix);
            if (prefix.len == out.len) return;

            var c = conn;
            try io.readFull(@TypeOf(c), &c, out[prefix.len..]);
        }

        pub fn readBody(allocator: std.mem.Allocator, resp: HttpNs.Response) ![]u8 {
            const body = resp.body() orelse return allocator.dupe(u8, "");

            var reader = body;
            var bytes = try std.ArrayList(u8).initCapacity(allocator, 0);
            errdefer bytes.deinit(allocator);

            var buf: [256]u8 = undefined;
            while (true) {
                const n = try reader.read(&buf);
                if (n == 0) break;
                try bytes.appendSlice(allocator, buf[0..n]);
            }

            return bytes.toOwnedSlice(allocator);
        }

        fn serveTwoKeepAliveRequests(tcp_listener: *NetNs.TcpListener, spec: anytype, accept_count: *usize) !void {
            var conn = try tcp_listener.accept();
            accept_count.* += 1;
            {
                defer conn.deinit();

                _ = try serveKeepAliveRequest(conn, spec.first_request_line, spec.first_body, false);

                conn.setReadDeadline(net.time.instant.add(net.time.instant.now(), twoRequestReuseWaitTimeout(spec)));
                const reused = serveKeepAliveRequest(conn, spec.second_request_line, spec.second_body, true) catch |err| switch (err) {
                    error.TimedOut, error.EndOfStream => false,
                    else => return err,
                };
                conn.setReadDeadline(null);
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

        fn serveStaleIdleRetryRequests(tcp_listener: *NetNs.TcpListener, spec: anytype, accept_count: *usize) !void {
            var warmup_conn = try tcp_listener.accept();
            accept_count.* += 1;
            {
                defer warmup_conn.deinit();
                var c = warmup_conn;
                var req_buf: [4096]u8 = undefined;
                const req_head = try readRequestHead(warmup_conn, &req_buf);
                try testing.expect(hasRequestLine(req_head, spec.warmup_request_line));

                var head_buf: [256]u8 = undefined;
                const head = try std.fmt.bufPrint(
                    &head_buf,
                    "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n",
                    .{spec.warmup_body.len},
                );
                try io.writeAll(@TypeOf(c), &c, head);
                try io.writeAll(@TypeOf(c), &c, spec.warmup_body);
            }

            var retry_conn = tcp_listener.accept() catch |err| switch (err) {
                error.Closed => return,
                else => return err,
            };
            accept_count.* += 1;
            defer retry_conn.deinit();
            var c = retry_conn;
            var req_buf: [4096]u8 = undefined;
            const req_head = try readRequestHead(retry_conn, &req_buf);
            try testing.expect(hasRequestLine(req_head, spec.retry_request_line));
            if (staleIdleRetryRequestBody(spec)) |expected_body| {
                try testing.expect(requestBodyMatches(retry_conn, req_head, expected_body));
            }

            var head_buf: [256]u8 = undefined;
            const head = try std.fmt.bufPrint(
                &head_buf,
                "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
                .{spec.retry_response_body.len},
            );
            try io.writeAll(@TypeOf(c), &c, head);
            try io.writeAll(@TypeOf(c), &c, spec.retry_response_body);
        }

        fn serveRedirectRequests(tcp_listener: *NetNs.TcpListener, spec: anytype, accept_count: *usize) !void {
            var conn = try tcp_listener.accept();
            accept_count.* += 1;
            const second_req_head = blk: {
                defer conn.deinit();
                var c = conn;
                var req_buf: [4096]u8 = undefined;
                const req_head = try readRequestHead(conn, &req_buf);
                try testing.expect(hasRequestLine(req_head, spec.first_request_line));

                var first_head_buf: [256]u8 = undefined;
                const first_head = try std.fmt.bufPrint(
                    &first_head_buf,
                    "HTTP/1.1 302 Found\r\nLocation: {s}\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n",
                    .{spec.location},
                );
                try io.writeAll(@TypeOf(c), &c, first_head);
                conn.setReadDeadline(net.time.instant.add(net.time.instant.now(), redirectReuseWaitTimeout(spec)));
                const next_req_head = readRequestHead(conn, &req_buf) catch |err| switch (err) {
                    error.TimedOut, error.EndOfStream => &.{},
                    else => return err,
                };
                conn.setReadDeadline(null);

                if (next_req_head.len != 0) {
                    try testing.expect(hasRequestLine(next_req_head, spec.second_request_line));
                    var second_head_buf: [256]u8 = undefined;
                    const second_head = try std.fmt.bufPrint(
                        &second_head_buf,
                        "HTTP/1.1 {d} OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
                        .{ redirectFinalStatusCode(spec), spec.final_body.len },
                    );
                    try io.writeAll(@TypeOf(c), &c, second_head);
                    try io.writeAll(@TypeOf(c), &c, spec.final_body);
                }
                break :blk next_req_head;
            };
            if (second_req_head.len != 0) return;

            var req_buf: [4096]u8 = undefined;

            var second_conn = tcp_listener.accept() catch |err| switch (err) {
                error.Closed => return,
                else => return err,
            };
            accept_count.* += 1;
            defer second_conn.deinit();
            var c = second_conn;
            const second_head = try readRequestHead(second_conn, &req_buf);
            try testing.expect(hasRequestLine(second_head, spec.second_request_line));

            var second_head_buf: [256]u8 = undefined;
            const final_head = try std.fmt.bufPrint(
                &second_head_buf,
                "HTTP/1.1 {d} OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
                .{ redirectFinalStatusCode(spec), spec.final_body.len },
            );
            try io.writeAll(@TypeOf(c), &c, final_head);
            try io.writeAll(@TypeOf(c), &c, spec.final_body);
        }

        fn serverExpectedRequestBody(spec: anytype) ?[]const u8 {
            if (!@hasField(@TypeOf(spec), "expected_request_body")) return null;
            return spec.expected_request_body;
        }

        fn serverContentType(spec: anytype) []const u8 {
            if (!@hasField(@TypeOf(spec), "content_type")) return "text/plain";
            return spec.content_type;
        }

        fn serverDelayMs(spec: anytype) u32 {
            if (!@hasField(@TypeOf(spec), "delay_ms")) return 0;
            return spec.delay_ms;
        }

        fn twoRequestReuseWaitTimeout(spec: anytype) net.time.duration.Duration {
            if (!@hasField(@TypeOf(spec), "reuse_wait_timeout")) return 100 * net.time.duration.MilliSecond;
            return spec.reuse_wait_timeout;
        }

        fn staleIdleRetryRequestBody(spec: anytype) ?[]const u8 {
            if (!@hasField(@TypeOf(spec), "retry_request_body")) return null;
            return spec.retry_request_body;
        }

        fn redirectFinalStatusCode(spec: anytype) u16 {
            if (!@hasField(@TypeOf(spec), "final_status_code")) return 200;
            return spec.final_status_code;
        }

        fn redirectReuseWaitTimeout(spec: anytype) net.time.duration.Duration {
            if (!@hasField(@TypeOf(spec), "reuse_wait_timeout")) return 100 * net.time.duration.MilliSecond;
            return spec.reuse_wait_timeout;
        }

        fn serveKeepAliveRequest(conn: net.Conn, expected_request_line: []const u8, body: []const u8, close_conn: bool) !bool {
            var c = conn;
            var req_buf: [4096]u8 = undefined;
            const req_head = try readRequestHead(conn, &req_buf);
            if (req_head.len == 0) return error.EndOfStream;
            try testing.expect(hasRequestLine(req_head, expected_request_line));

            var head_buf: [256]u8 = undefined;
            const head = try std.fmt.bufPrint(
                &head_buf,
                "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: {s}\r\n\r\n",
                .{ body.len, if (close_conn) "close" else "keep-alive" },
            );
            try io.writeAll(@TypeOf(c), &c, head);
            try io.writeAll(@TypeOf(c), &c, body);
            return true;
        }
    };
}
