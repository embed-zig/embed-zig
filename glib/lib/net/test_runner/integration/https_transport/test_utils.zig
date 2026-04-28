//! Shared harness and IO helpers for HTTPS transport integration cases.

const io = @import("io");
const fixtures_mod = @import("../../../tls/test_fixtures.zig");

pub fn make(comptime std: type, comptime net: type) type {
    const NetNs = net;
    const HttpNs = NetNs.http;
    const AddrPort = net.netip.AddrPort;
    const Thread = std.Thread;

    return struct {
        pub const Http = HttpNs;
        pub const Net = NetNs;
        pub const fixtures = fixtures_mod;
        pub const test_spawn_config: Thread.SpawnConfig = .{ .stack_size = 2 * 1024 * 1024 };

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

        pub fn addr4(port: u16) AddrPort {
            return AddrPort.from4(.{ 127, 0, 0, 1 }, port);
        }

        pub fn tlsTransportOptions() HttpNs.Transport.Options {
            return .{
                .tls_client_config = .{
                    .server_name = "example.com",
                    .verification = .self_signed,
                },
            };
        }

        pub fn tlsServerConfig() NetNs.tls.ServerConfig {
            return .{
                .certificates = &.{.{
                    .chain = &.{fixtures_mod.self_signed_cert_der[0..]},
                    .private_key = .{ .ecdsa_p256_sha256 = fixtures_mod.self_signed_key_scalar },
                }},
            };
        }

        pub fn tlsServerConfigWithAlpn(protocols: []const []const u8) NetNs.tls.ServerConfig {
            var config = tlsServerConfig();
            config.alpn_protocols = protocols;
            return config;
        }

        pub fn tcpListenerPort(ln: net.Listener, comptime NetApi: type) !u16 {
            _ = NetApi;
            const listener = try ln.as(NetNs.TcpListener);
            return listener.port();
        }

        pub fn tlsListenerPort(ln: net.Listener, comptime NetApi: type) !u16 {
            _ = NetApi;
            const tls_listener = try ln.as(NetNs.tls.Listener);
            const tcp_impl = try tls_listener.inner.as(NetNs.TcpListener);
            return tcp_impl.port();
        }

        pub fn bridgeTunnel(client: net.Conn, upstream: net.Conn) !void {
            var slot = BridgeErrorSlot{};
            var stop = BridgeStopFlag{};
            const upstream_thread = try Thread.spawn(test_spawn_config, struct {
                fn run(src: net.Conn, dst: net.Conn, err_slot: *BridgeErrorSlot, stop_flag: *BridgeStopFlag) void {
                    bridgeOneWay(src, dst, err_slot, stop_flag);
                }
            }.run, .{ client, upstream, &slot, &stop });
            defer upstream_thread.join();

            bridgeOneWay(upstream, client, &slot, &stop);
            stop.signal();
            if (slot.load()) |err| return err;
        }

        fn bridgeOneWay(src: net.Conn, dst: net.Conn, err_slot: *BridgeErrorSlot, stop_flag: *BridgeStopFlag) void {
            var reader = src;
            var writer = dst;
            reader.setReadDeadline(net.time.instant.add(net.time.instant.now(), 250 * net.time.duration.MilliSecond));

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

        pub fn serveKeepAliveRequest(conn: net.Conn, expected_request_line: []const u8, body: []const u8, close_conn: bool) !bool {
            var c = conn;
            var req_buf: [4096]u8 = undefined;
            const req_head = try readRequestHead(conn, &req_buf);
            if (req_head.len == 0) return error.EndOfStream;
            try std.testing.expect(hasRequestLine(req_head, expected_request_line));

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
    };
}
