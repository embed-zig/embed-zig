//! WebSocket e2e + stress tests — Client ↔ MockWsServer
//!
//! Uses real TCP loopback via `runtime.std.Socket` + `SocketConn` adapter.
//! Tests: text echo, binary echo, ping/pong, sequential messages,
//! server-initiated close, extra headers, concurrent connections,
//! large frames, and latency measurement.

const std = @import("std");
const testing = std.testing;
const conn_mod = @import("../conn.zig");
const ws_client = @import("client.zig");
const frame = @import("frame.zig");
const handshake = @import("handshake.zig");
const runtime_std = @import("../../../runtime/std.zig");
const Socket = runtime_std.Socket;
const SConn = conn_mod.SocketConn(Socket);

fn rngFill(buf: []u8) void {
    std.crypto.random.bytes(buf);
}

// ==========================================================================
// MockWsServer — minimal WebSocket echo server over real TCP
// ==========================================================================

const MockWsServer = struct {
    listener: Socket,
    port: u16,
    server_thread: ?std.Thread = null,
    captured_headers: [2048]u8 = undefined,
    captured_headers_len: usize = 0,

    fn init() !MockWsServer {
        var listener = try Socket.tcp();
        try listener.bind(.{ 127, 0, 0, 1 }, 0);
        try listener.listen();
        const port = try listener.getBoundPort();
        return .{ .listener = listener, .port = port };
    }

    fn start(self: *MockWsServer) !void {
        self.server_thread = try std.Thread.spawn(.{}, serverLoop, .{self});
    }

    fn stop(self: *MockWsServer) void {
        self.listener.close();
        if (self.server_thread) |t| t.join();
    }

    fn serverLoop(self: *MockWsServer) void {
        var client_sock = self.listener.accept() catch return;
        defer client_sock.close();
        serverHandleClient(self, &client_sock) catch {};
    }

    fn serverHandleClient(self: *MockWsServer, sock: *Socket) !void {
        var buf: [4096]u8 = undefined;
        var total: usize = 0;

        while (total < buf.len) {
            const n = sock.recv(buf[total..]) catch return;
            if (n == 0) return;
            total += n;
            if (findCRLFCRLF(buf[0..total])) |_| break;
        }

        const cap_len = @min(total, self.captured_headers.len);
        @memcpy(self.captured_headers[0..cap_len], buf[0..cap_len]);
        self.captured_headers_len = cap_len;

        const key = extractKey(buf[0..total]) orelse return;
        var accept: [28]u8 = undefined;
        handshake.computeAcceptKey(key, &accept);

        var resp_buf: [512]u8 = undefined;
        const resp = buildResponse(&resp_buf, &accept);
        _ = sock.send(resp) catch return;

        echoLoop(sock) catch {};
    }
};

fn echoLoop(sock: *Socket) !void {
    var read_buf: [131072]u8 = undefined;
    var read_len: usize = 0;

    while (true) {
        const n = sock.recv(read_buf[read_len..]) catch return;
        if (n == 0) return;
        read_len += n;

        while (read_len >= 2) {
            const header = frame.decodeHeader(read_buf[0..read_len]) catch break;
            const total_frame = header.header_size + @as(usize, @intCast(header.payload_len));
            if (read_len < total_frame) break;

            const payload = read_buf[header.header_size..total_frame];
            if (header.masked) {
                frame.applyMask(@constCast(payload), header.mask_key);
            }

            if (header.opcode == .close) {
                var close_buf: [frame.MAX_HEADER_SIZE + 2]u8 = undefined;
                const hdr_len = frame.encodeHeader(&close_buf, .close, payload.len, true, null);
                if (payload.len > 0) @memcpy(close_buf[hdr_len..][0..payload.len], payload);
                _ = sock.send(close_buf[0 .. hdr_len + payload.len]) catch {};
                return;
            } else if (header.opcode == .ping) {
                var pong_buf: [frame.MAX_HEADER_SIZE + 125]u8 = undefined;
                const hdr_len = frame.encodeHeader(&pong_buf, .pong, payload.len, true, null);
                if (payload.len > 0) @memcpy(pong_buf[hdr_len..][0..payload.len], payload);
                _ = sock.send(pong_buf[0 .. hdr_len + payload.len]) catch {};
            } else {
                var echo_hdr: [frame.MAX_HEADER_SIZE]u8 = undefined;
                const hdr_len = frame.encodeHeader(&echo_hdr, header.opcode, payload.len, true, null);
                _ = sock.send(echo_hdr[0..hdr_len]) catch return;
                if (payload.len > 0) {
                    _ = sock.send(payload) catch return;
                }
            }

            const remaining = read_len - total_frame;
            if (remaining > 0) {
                ws_client.copyForward(&read_buf, read_buf[total_frame..read_len]);
            }
            read_len = remaining;
        }
    }
}

// ==========================================================================
// MultiConnServer — echo server supporting multiple concurrent clients
// ==========================================================================

const MultiConnServer = struct {
    listener: Socket,
    port: u16,
    accept_thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    fn init() !MultiConnServer {
        var listener = try Socket.tcp();
        try listener.bind(.{ 127, 0, 0, 1 }, 0);
        try listener.listen();
        const port = try listener.getBoundPort();
        return .{ .listener = listener, .port = port };
    }

    fn start(self: *MultiConnServer) !void {
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    fn stop(self: *MultiConnServer) void {
        self.running.store(false, .release);
        self.listener.close();
        if (self.accept_thread) |t| t.join();
    }

    const ClientCtx = struct {
        sock: Socket,
    };

    fn acceptLoop(self: *MultiConnServer) void {
        while (self.running.load(.acquire)) {
            const client_sock = self.listener.accept() catch return;
            const ctx = std.heap.page_allocator.create(ClientCtx) catch {
                var s = client_sock;
                s.close();
                continue;
            };
            ctx.* = .{ .sock = client_sock };
            _ = std.Thread.spawn(.{}, handleClientOwned, .{ctx}) catch {
                ctx.sock.close();
                std.heap.page_allocator.destroy(ctx);
                continue;
            };
        }
    }

    fn handleClientOwned(ctx: *ClientCtx) void {
        defer {
            ctx.sock.close();
            std.heap.page_allocator.destroy(ctx);
        }
        var buf: [8192]u8 = undefined;
        var total: usize = 0;

        while (total < buf.len) {
            const n = ctx.sock.recv(buf[total..]) catch return;
            if (n == 0) return;
            total += n;
            if (findCRLFCRLF(buf[0..total])) |_| break;
        }

        const key = extractKey(buf[0..total]) orelse return;
        var accept: [28]u8 = undefined;
        handshake.computeAcceptKey(key, &accept);

        var resp_buf: [512]u8 = undefined;
        const resp = buildResponse(&resp_buf, &accept);
        _ = ctx.sock.send(resp) catch return;

        echoLoop(&ctx.sock) catch {};
    }
};

// ==========================================================================
// Helpers
// ==========================================================================

fn findCRLFCRLF(data: []const u8) ?usize {
    if (data.len < 4) return null;
    for (0..data.len - 3) |i| {
        if (data[i] == '\r' and data[i + 1] == '\n' and data[i + 2] == '\r' and data[i + 3] == '\n')
            return i;
    }
    return null;
}

fn extractKey(request: []const u8) ?[]const u8 {
    const needle = "Sec-WebSocket-Key: ";
    if (request.len < needle.len) return null;
    for (0..request.len - needle.len) |i| {
        if (std.mem.eql(u8, request[i..][0..needle.len], needle)) {
            const start = i + needle.len;
            var end = start;
            while (end < request.len and request[end] != '\r') : (end += 1) {}
            return request[start..end];
        }
    }
    return null;
}

fn buildResponse(buf: []u8, accept: []const u8) []const u8 {
    const parts = [_][]const u8{
        "HTTP/1.1 101 Switching Protocols\r\n",
        "Upgrade: websocket\r\n",
        "Connection: Upgrade\r\n",
        "Sec-WebSocket-Accept: ",
        accept,
        "\r\n\r\n",
    };
    var pos: usize = 0;
    for (parts) |part| {
        @memcpy(buf[pos..][0..part.len], part);
        pos += part.len;
    }
    return buf[0..pos];
}

fn containsStr(haystack: []const u8, needle_str: []const u8) bool {
    if (needle_str.len > haystack.len) return false;
    for (0..haystack.len - needle_str.len + 1) |i| {
        if (std.mem.eql(u8, haystack[i..][0..needle_str.len], needle_str)) return true;
    }
    return false;
}

fn formatNum(buf: []u8, n: usize) []const u8 {
    const prefix = "msg-";
    @memcpy(buf[0..prefix.len], prefix);
    const pos: usize = prefix.len;

    if (n == 0) {
        buf[pos] = '0';
        return buf[0 .. pos + 1];
    }

    var tmp: [20]u8 = undefined;
    var tmp_len: usize = 0;
    var val = n;
    while (val > 0) {
        tmp[tmp_len] = @intCast(val % 10 + '0');
        tmp_len += 1;
        val /= 10;
    }
    for (0..tmp_len) |i| {
        buf[pos + i] = tmp[tmp_len - 1 - i];
    }
    return buf[0 .. pos + tmp_len];
}

// ==========================================================================
// E1: Text echo roundtrip
// ==========================================================================

test "E1: text echo roundtrip" {
    const allocator = std.testing.allocator;

    var server = try MockWsServer.init();
    try server.start();
    defer server.stop();

    var sock = try Socket.tcp();
    defer sock.close();
    try sock.connect(.{ 127, 0, 0, 1 }, server.port);

    var sconn = SConn.init(&sock);
    var client = try ws_client.Client(SConn).init(allocator, &sconn, .{
        .host = "localhost",
        .path = "/",
        .rng_fill = rngFill,
    });
    defer client.deinit();

    try client.sendText("hello");
    const msg1 = (try client.recv()) orelse return error.UnexpectedNull;
    try std.testing.expectEqual(ws_client.MessageType.text, msg1.type);
    try std.testing.expectEqualSlices(u8, "hello", msg1.payload);

    try client.sendText("world");
    const msg2 = (try client.recv()) orelse return error.UnexpectedNull;
    try std.testing.expectEqual(ws_client.MessageType.text, msg2.type);
    try std.testing.expectEqualSlices(u8, "world", msg2.payload);

    client.close();
}

// ==========================================================================
// E2: Binary echo
// ==========================================================================

test "E2: binary echo" {
    const allocator = std.testing.allocator;

    var server = try MockWsServer.init();
    try server.start();
    defer server.stop();

    var sock = try Socket.tcp();
    defer sock.close();
    try sock.connect(.{ 127, 0, 0, 1 }, server.port);

    var sconn = SConn.init(&sock);
    var client = try ws_client.Client(SConn).init(allocator, &sconn, .{
        .host = "localhost",
        .path = "/",
        .rng_fill = rngFill,
    });
    defer client.deinit();

    var data: [256]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i % 256);

    try client.sendBinary(&data);
    const msg = (try client.recv()) orelse return error.UnexpectedNull;
    try std.testing.expectEqual(ws_client.MessageType.binary, msg.type);
    try std.testing.expectEqualSlices(u8, &data, msg.payload);

    client.close();
}

// ==========================================================================
// E3: Ping/pong
// ==========================================================================

test "E3: ping pong" {
    const allocator = std.testing.allocator;

    var server = try MockWsServer.init();
    try server.start();
    defer server.stop();

    var sock = try Socket.tcp();
    defer sock.close();
    try sock.connect(.{ 127, 0, 0, 1 }, server.port);

    var sconn = SConn.init(&sock);
    var client = try ws_client.Client(SConn).init(allocator, &sconn, .{
        .host = "localhost",
        .path = "/",
        .rng_fill = rngFill,
    });
    defer client.deinit();

    try client.sendPing();
    const msg = (try client.recv()) orelse return error.UnexpectedNull;
    try std.testing.expectEqual(ws_client.MessageType.pong, msg.type);

    client.close();
}

// ==========================================================================
// E4: 50 consecutive messages
// ==========================================================================

test "E4: 50 consecutive messages" {
    const allocator = std.testing.allocator;

    var server = try MockWsServer.init();
    try server.start();
    defer server.stop();

    var sock = try Socket.tcp();
    defer sock.close();
    try sock.connect(.{ 127, 0, 0, 1 }, server.port);

    var sconn = SConn.init(&sock);
    var client = try ws_client.Client(SConn).init(allocator, &sconn, .{
        .host = "localhost",
        .path = "/",
        .rng_fill = rngFill,
    });
    defer client.deinit();

    var buf: [32]u8 = undefined;
    for (0..50) |i| {
        const msg_text = formatNum(&buf, i);
        try client.sendText(msg_text);
        const msg = (try client.recv()) orelse return error.UnexpectedNull;
        try std.testing.expectEqual(ws_client.MessageType.text, msg.type);
        try std.testing.expectEqualSlices(u8, msg_text, msg.payload);
    }

    client.close();
}

// ==========================================================================
// E5: Server-initiated close
// ==========================================================================

test "E5: server-initiated close" {
    const allocator = std.testing.allocator;

    var server = try MockWsServer.init();
    try server.start();
    defer server.stop();

    var sock = try Socket.tcp();
    defer sock.close();
    try sock.connect(.{ 127, 0, 0, 1 }, server.port);

    var sconn = SConn.init(&sock);
    var client = try ws_client.Client(SConn).init(allocator, &sconn, .{
        .host = "localhost",
        .path = "/",
        .rng_fill = rngFill,
    });
    defer client.deinit();

    try client.sendClose(1000);

    const result = try client.recv();
    try std.testing.expectEqual(@as(?ws_client.Message, null), result);
}

// ==========================================================================
// E6: Extra headers
// ==========================================================================

test "E6: extra headers" {
    const allocator = std.testing.allocator;

    var server = try MockWsServer.init();
    try server.start();
    defer server.stop();

    var sock = try Socket.tcp();
    defer sock.close();
    try sock.connect(.{ 127, 0, 0, 1 }, server.port);

    const headers = [_][2][]const u8{
        .{ "X-Api-App-Key", "test-key-12345" },
        .{ "X-Api-Access-Key", "access-token-abc" },
        .{ "X-Api-Resource-Id", "volc.speech.dialog" },
    };

    var sconn = SConn.init(&sock);
    var client = try ws_client.Client(SConn).init(allocator, &sconn, .{
        .host = "localhost",
        .path = "/api/v3/realtime",
        .extra_headers = &headers,
        .rng_fill = rngFill,
    });
    defer client.deinit();

    std.Thread.sleep(10 * std.time.ns_per_ms);

    const captured = server.captured_headers[0..server.captured_headers_len];
    try std.testing.expect(containsStr(captured, "X-Api-App-Key: test-key-12345"));
    try std.testing.expect(containsStr(captured, "X-Api-Access-Key: access-token-abc"));
    try std.testing.expect(containsStr(captured, "X-Api-Resource-Id: volc.speech.dialog"));
    try std.testing.expect(containsStr(captured, "GET /api/v3/realtime HTTP/1.1"));

    try client.sendText("doubao-test");
    const msg = (try client.recv()) orelse return error.UnexpectedNull;
    try std.testing.expectEqual(ws_client.MessageType.text, msg.type);
    try std.testing.expectEqualSlices(u8, "doubao-test", msg.payload);

    client.close();
}

// ==========================================================================
// BM1: 1000 sequential text messages
// ==========================================================================

test "BM1: 1000 text messages sequential" {
    const allocator = std.testing.allocator;

    var server = try MockWsServer.init();
    try server.start();
    defer server.stop();

    var sock = try Socket.tcp();
    defer sock.close();
    try sock.connect(.{ 127, 0, 0, 1 }, server.port);

    var sconn = SConn.init(&sock);
    var client = try ws_client.Client(SConn).init(allocator, &sconn, .{
        .host = "localhost",
        .path = "/",
        .rng_fill = rngFill,
    });
    defer client.deinit();

    var timer = std.time.Timer.start() catch unreachable;

    var msg_buf: [32]u8 = undefined;
    for (0..1000) |i| {
        const msg_text = formatNum(&msg_buf, i);
        try client.sendText(msg_text);
        const msg = (try client.recv()) orelse return error.UnexpectedNull;
        try std.testing.expectEqualSlices(u8, msg_text, msg.payload);
    }

    const elapsed_ns = timer.read();
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
    std.debug.print("\n[bench] WS text: 1000 msg in {}ms\n", .{elapsed_ms});

    client.close();
}

// ==========================================================================
// BM2: 500 × 1KB binary frames
// ==========================================================================

test "BM2: 500x1KB binary frames" {
    const allocator = std.testing.allocator;

    var server = try MockWsServer.init();
    try server.start();
    defer server.stop();

    var sock = try Socket.tcp();
    defer sock.close();
    try sock.connect(.{ 127, 0, 0, 1 }, server.port);

    var sconn = SConn.init(&sock);
    var client = try ws_client.Client(SConn).init(allocator, &sconn, .{
        .host = "localhost",
        .path = "/",
        .rng_fill = rngFill,
    });
    defer client.deinit();

    var data: [1024]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i % 256);

    var timer = std.time.Timer.start() catch unreachable;

    for (0..500) |_| {
        try client.sendBinary(&data);
        const msg = (try client.recv()) orelse return error.UnexpectedNull;
        try std.testing.expectEqual(ws_client.MessageType.binary, msg.type);
        try std.testing.expectEqual(@as(usize, 1024), msg.payload.len);
        try std.testing.expectEqualSlices(u8, &data, msg.payload);
    }

    const elapsed_ns = timer.read();
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
    std.debug.print("\n[bench] WS binary: 500x1KB in {}ms\n", .{elapsed_ms});

    client.close();
}

// ==========================================================================
// BM3: 10 concurrent connections × 100 messages
// ==========================================================================

test "BM3: 10 concurrent connections x100 messages" {
    const allocator = std.testing.allocator;

    var server = try MultiConnServer.init();
    try server.start();
    defer server.stop();

    const N_CLIENTS = 10;
    const N_MSGS = 100;

    var pass_count = std.atomic.Value(u32).init(0);

    var timer = std.time.Timer.start() catch unreachable;

    var threads: [N_CLIENTS]std.Thread = undefined;
    for (0..N_CLIENTS) |i| {
        threads[i] = try std.Thread.spawn(.{}, clientWorker, .{
            allocator, server.port, i, N_MSGS, &pass_count,
        });
    }
    for (&threads) |t| t.join();

    const elapsed_ns = timer.read();
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
    std.debug.print("\n[bench] WS 10-concurrent: {}x{} msg in {}ms\n", .{ N_CLIENTS, N_MSGS, elapsed_ms });

    try std.testing.expectEqual(@as(u32, N_CLIENTS), pass_count.load(.acquire));
}

fn clientWorker(
    allocator: std.mem.Allocator,
    port: u16,
    client_id: usize,
    n_msgs: usize,
    pass_count: *std.atomic.Value(u32),
) void {
    var sock = Socket.tcp() catch return;
    defer sock.close();
    sock.connect(.{ 127, 0, 0, 1 }, port) catch return;

    var sconn = SConn.init(&sock);
    var client = ws_client.Client(SConn).init(allocator, &sconn, .{
        .host = "localhost",
        .path = "/",
        .rng_fill = rngFill,
    }) catch return;
    defer client.deinit();

    var msg_buf: [64]u8 = undefined;
    var ok: bool = true;
    for (0..n_msgs) |i| {
        _ = client_id;
        const full = formatNum(&msg_buf, i);

        client.sendText(full) catch {
            ok = false;
            break;
        };
        const msg = (client.recv() catch null) orelse {
            ok = false;
            break;
        };
        if (!std.mem.eql(u8, full, msg.payload)) {
            ok = false;
            break;
        }
    }

    client.close();
    if (ok) _ = pass_count.fetchAdd(1, .acq_rel);
}

// ==========================================================================
// BM4: 64KB binary roundtrip
// ==========================================================================

test "BM4: 64KB binary roundtrip" {
    const allocator = std.testing.allocator;

    var server = try MockWsServer.init();
    try server.start();
    defer server.stop();

    var sock = try Socket.tcp();
    defer sock.close();
    try sock.connect(.{ 127, 0, 0, 1 }, server.port);

    var sconn = SConn.init(&sock);
    var client = try ws_client.Client(SConn).init(allocator, &sconn, .{
        .host = "localhost",
        .path = "/",
        .rng_fill = rngFill,
        .buffer_size = 65536 + 1024,
    });
    defer client.deinit();

    const data = try allocator.alloc(u8, 65536);
    defer allocator.free(data);
    for (data, 0..) |*b, i| b.* = @intCast(i % 256);

    var timer = std.time.Timer.start() catch unreachable;

    try client.sendBinary(data);
    const msg = (try client.recv()) orelse return error.UnexpectedNull;
    try std.testing.expectEqual(ws_client.MessageType.binary, msg.type);
    try std.testing.expectEqual(@as(usize, 65536), msg.payload.len);
    try std.testing.expectEqualSlices(u8, data, msg.payload);

    const elapsed_ns = timer.read();
    const elapsed_us = elapsed_ns / std.time.ns_per_us;
    std.debug.print("\n[bench] WS large-frame: 64KB roundtrip in {}us\n", .{elapsed_us});

    client.close();
}

// ==========================================================================
// BM5: Latency P50/P99
// ==========================================================================

test "BM5: latency P50/P99" {
    const allocator = std.testing.allocator;

    var server = try MockWsServer.init();
    try server.start();
    defer server.stop();

    var sock = try Socket.tcp();
    defer sock.close();
    try sock.connect(.{ 127, 0, 0, 1 }, server.port);

    var sconn = SConn.init(&sock);
    var client = try ws_client.Client(SConn).init(allocator, &sconn, .{
        .host = "localhost",
        .path = "/",
        .rng_fill = rngFill,
    });
    defer client.deinit();

    const N = 100;
    var latencies: [N]u64 = undefined;

    for (0..N) |i| {
        var t0 = std.time.Timer.start() catch unreachable;
        try client.sendText("ping");
        _ = (try client.recv()) orelse return error.UnexpectedNull;
        latencies[i] = t0.read();
    }

    std.mem.sort(u64, &latencies, {}, std.sort.asc(u64));

    const p50 = latencies[N / 2] / std.time.ns_per_us;
    const p99 = latencies[N * 99 / 100] / std.time.ns_per_us;
    std.debug.print("\n[bench] WS latency: P50={}us, P99={}us\n", .{ p50, p99 });

    client.close();
}
