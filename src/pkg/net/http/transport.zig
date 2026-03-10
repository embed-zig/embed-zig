//! HTTP Transport layer — Go-style RoundTripper pattern.
//!
//! `RoundTripper` is a contract: given an HTTP request, produce an HTTP response.
//!
//! `Transport` is the default implementation that handles:
//!   - URL parsing
//!   - DNS resolution
//!   - TCP connection establishment
//!   - TLS handshake (for HTTPS)
//!   - HTTP request/response over the wire
//!
//! The `Client` type (in client.zig) depends only on the `RoundTripper` contract,
//! not on `Transport` directly — enabling mock transports for testing.

const std = @import("std");
const runtime = struct {
    pub const socket = @import("../../../runtime/socket.zig");
    pub const std = @import("../../../runtime/std.zig");
};
const conn_mod = @import("../conn.zig");
const tls_mod = struct {
    pub fn Client(comptime Conn: type, comptime Crypto: type, comptime Mutex: type) type {
        return @import("../tls/client.zig").Client(Conn, Crypto, Mutex);
    }
};
const dns_mod = @import("../dns/dns.zig");
const url_mod = @import("../url/url.zig");
const request_mod = @import("request.zig");

pub const Method = request_mod.Method;

pub const Scheme = enum {
    http,
    https,
};

/// HTTP request descriptor for RoundTripper.
pub const RoundTripRequest = struct {
    method: Method = .GET,
    scheme: Scheme = .http,
    host: []const u8,
    port: u16 = 80,
    path: []const u8 = "/",
    body: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    user_agent: []const u8 = "zig-http/0.1",
    timeout_ms: u32 = 30000,
    extra_headers: ?[]const u8 = null,
};

/// HTTP response from RoundTripper.
pub const RoundTripResponse = struct {
    status_code: u16,
    content_length: ?usize,
    chunked: bool,
    headers_end: usize,
    body_start: usize,
    buffer: []u8,
    buffer_len: usize,

    pub fn body(self: *const RoundTripResponse) []const u8 {
        if (self.body_start >= self.buffer_len) return &[_]u8{};
        return self.buffer[self.body_start..self.buffer_len];
    }

    pub fn isSuccess(self: *const RoundTripResponse) bool {
        return self.status_code >= 200 and self.status_code < 300;
    }

    pub fn headerValue(self: *const RoundTripResponse, name: []const u8) ?[]const u8 {
        const headers = self.buffer[0..self.headers_end];
        var i: usize = 0;
        while (i < headers.len) {
            const line_end = std.mem.indexOfPos(u8, headers, i, "\r\n") orelse break;
            const line = headers[i..line_end];
            if (line.len == 0) break;

            const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
                i = line_end + 2;
                continue;
            };
            const hdr_name = std.mem.trim(u8, line[0..colon], " \t");
            if (std.ascii.eqlIgnoreCase(hdr_name, name)) {
                return std.mem.trim(u8, line[colon + 1 ..], " \t");
            }
            i = line_end + 2;
        }
        return null;
    }
};

pub const TransportError = error{
    InvalidUrl,
    DnsResolveFailed,
    ConnectionFailed,
    SendFailed,
    ReceiveFailed,
    Timeout,
    InvalidResponse,
    TlsError,
    TlsHandshakeFailed,
    TlsNotSupported,
    BufferTooSmall,
};

/// Validate that `Impl` satisfies the RoundTripper contract.
///
/// Required method:
///   `fn roundTrip(*Impl, RoundTripRequest, []u8) TransportError!RoundTripResponse`
pub fn RoundTripper(comptime Impl: type) type {
    comptime {
        _ = @as(
            *const fn (*Impl, RoundTripRequest, []u8) TransportError!RoundTripResponse,
            &Impl.roundTrip,
        );
    }
    return Impl;
}

/// Default HTTP Transport — handles DNS, TCP, TLS, and HTTP over the wire.
///
/// Type parameters:
///   - `Socket`: must satisfy `runtime.socket.from` contract
///   - `Crypto`: crypto primitives for TLS (pass `void` for HTTP-only)
///   - `Mutex`: mutex type for TLS thread safety (pass `void` for HTTP-only)
///   - `DomainResolver`: custom DNS resolver (pass `void` to disable)
pub fn Transport(
    comptime Socket: type,
    comptime Crypto: type,
    comptime Mutex: type,
    comptime DomainResolver: type,
) type {
    comptime _ = runtime.socket.from(Socket);

    const has_tls = Crypto != void and Mutex != void;
    const has_custom_resolver = DomainResolver != void;

    const SConn = conn_mod.SocketConn(Socket);
    const TlsClient = if (has_tls) tls_mod.Client(SConn, Crypto, Mutex) else void;
    const DnsResolver = dns_mod.Resolver(Socket, DomainResolver);

    const CaStore = if (Crypto != void and @hasDecl(Crypto, "x509") and @hasDecl(Crypto.x509, "CaStore"))
        Crypto.x509.CaStore
    else
        void;

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        dns_server: [4]u8 = dns_mod.Servers.alidns,
        dns_timeout_ms: u32 = 5000,
        ca_store: if (CaStore != void) ?CaStore else void = if (CaStore != void) null else {},
        user_agent: []const u8 = "zig-http/0.1",
        custom_resolver: if (has_custom_resolver) ?*const DomainResolver else void =
            if (has_custom_resolver) null else {},

        pub const CaStoreType = CaStore;

        pub fn roundTrip(self: *Self, req: RoundTripRequest, buffer: []u8) TransportError!RoundTripResponse {
            const addr = self.resolveHost(req.host) orelse return error.DnsResolveFailed;

            var socket = Socket.tcp() catch return error.ConnectionFailed;

            socket.setRecvTimeout(req.timeout_ms);
            socket.setSendTimeout(req.timeout_ms);
            socket.setTcpNoDelay(true);

            socket.connect(addr, req.port) catch {
                socket.close();
                return error.ConnectionFailed;
            };

            if (req.scheme == .https) {
                if (!has_tls) return error.TlsNotSupported;
                return self.roundTripHttps(&socket, req, buffer);
            }

            return roundTripPlain(&socket, req, buffer);
        }

        fn resolveHost(self: *const Self, host: []const u8) ?[4]u8 {
            if (runtime.socket.parseIpv4(host)) |addr| return addr;

            var resolver = DnsResolver{
                .server = self.dns_server,
                .protocol = .udp,
                .timeout_ms = self.dns_timeout_ms,
            };
            if (has_custom_resolver) {
                resolver.custom_resolver = self.custom_resolver;
            }

            return resolver.resolve(host) catch null;
        }

        fn roundTripPlain(socket: *Socket, req: RoundTripRequest, buffer: []u8) TransportError!RoundTripResponse {
            defer socket.close();

            try sendHttpRequest(socket, req);
            return recvHttpResponse(socket, buffer);
        }

        fn roundTripHttps(self: *Self, socket: *Socket, req: RoundTripRequest, buffer: []u8) TransportError!RoundTripResponse {
            defer socket.close();

            var socket_conn = SConn.init(socket);

            const skip_verify = if (CaStore != void) self.ca_store == null else true;
            const ca_store_val = if (CaStore != void) self.ca_store else {};

            var tls_client = TlsClient.init(&socket_conn, .{
                .allocator = self.allocator,
                .hostname = req.host,
                .skip_verify = skip_verify,
                .ca_store = ca_store_val,
                .timeout_ms = req.timeout_ms,
            }) catch return error.TlsError;
            defer tls_client.deinit();

            tls_client.connect() catch return error.TlsHandshakeFailed;

            var req_buf: [2048]u8 = undefined;
            const req_len = buildHttpRequest(&req_buf, req) catch return error.BufferTooSmall;

            _ = tls_client.send(req_buf[0..req_len]) catch return error.SendFailed;

            var total_received: usize = 0;
            while (total_received < buffer.len) {
                const n = tls_client.recv(buffer[total_received..]) catch {
                    if (total_received > 0) break;
                    return error.ReceiveFailed;
                };
                if (n == 0) break;
                total_received += n;

                if (isResponseComplete(buffer[0..total_received])) break;
            }

            return parseHttpResponse(buffer, total_received);
        }

        fn sendHttpRequest(socket: *Socket, req: RoundTripRequest) TransportError!void {
            var req_buf: [2048]u8 = undefined;
            const req_len = buildHttpRequest(&req_buf, req) catch return error.BufferTooSmall;

            _ = socket.send(req_buf[0..req_len]) catch return error.SendFailed;
        }

        fn recvHttpResponse(socket: *Socket, buffer: []u8) TransportError!RoundTripResponse {
            var total_received: usize = 0;
            while (total_received < buffer.len) {
                const n = socket.recv(buffer[total_received..]) catch |err| {
                    if ((err == error.Timeout or err == error.Closed) and total_received > 0) break;
                    return error.ReceiveFailed;
                };
                if (n == 0) break;
                total_received += n;

                if (isResponseComplete(buffer[0..total_received])) break;
            }

            return parseHttpResponse(buffer, total_received);
        }

        comptime {
            _ = RoundTripper(Self);
        }
    };
}

// =========================================================================
// Shared HTTP helpers
// =========================================================================

fn buildHttpRequest(buf: []u8, req: RoundTripRequest) !usize {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    try w.print("{s} {s} HTTP/1.1\r\n", .{ req.method.toString(), req.path });
    try w.print("Host: {s}\r\n", .{req.host});
    try w.print("User-Agent: {s}\r\n", .{req.user_agent});
    try w.writeAll("Connection: close\r\n");

    if (req.body) |data| {
        try w.print("Content-Length: {d}\r\n", .{data.len});
    }

    if (req.content_type) |ct| {
        try w.print("Content-Type: {s}\r\n", .{ct});
    }

    if (req.extra_headers) |hdrs| {
        try w.writeAll(hdrs);
    }

    try w.writeAll("\r\n");

    if (req.body) |data| {
        try w.writeAll(data);
    }

    return fbs.pos;
}

fn findHeaderEnd(data: []const u8) ?usize {
    if (data.len < 4) return null;
    for (0..data.len - 3) |i| {
        if (std.mem.eql(u8, data[i .. i + 4], "\r\n\r\n")) {
            return i + 4;
        }
    }
    return null;
}

fn parseContentLength(headers: []const u8) ?usize {
    var i: usize = 0;
    while (i < headers.len) {
        const line_end = std.mem.indexOfPos(u8, headers, i, "\r\n") orelse break;
        const line = headers[i..line_end];

        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const value = std.mem.trim(u8, line["content-length:".len..], " ");
            return std.fmt.parseInt(usize, value, 10) catch null;
        }

        i = line_end + 2;
    }
    return null;
}

fn isResponseComplete(data: []const u8) bool {
    const headers_end = findHeaderEnd(data) orelse return false;
    const content_len = parseContentLength(data[0..headers_end]) orelse return false;
    return data.len >= headers_end + content_len;
}

fn parseHttpResponse(buffer: []u8, len: usize) TransportError!RoundTripResponse {
    if (len < 12) return error.InvalidResponse;

    if (!std.mem.startsWith(u8, buffer[0..len], "HTTP/1.")) {
        return error.InvalidResponse;
    }

    const status_start = 9;
    if (len < status_start + 3) return error.InvalidResponse;

    const status_code = std.fmt.parseInt(u16, buffer[status_start .. status_start + 3], 10) catch {
        return error.InvalidResponse;
    };

    const headers_end = findHeaderEnd(buffer[0..len]) orelse return error.InvalidResponse;

    var content_length: ?usize = null;
    var chunked = false;

    var i: usize = 0;
    while (i < headers_end) {
        const line_end = std.mem.indexOfPos(u8, buffer[0..headers_end], i, "\r\n") orelse break;
        const line = buffer[i..line_end];

        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const value = std.mem.trim(u8, line["content-length:".len..], " ");
            content_length = std.fmt.parseInt(usize, value, 10) catch null;
        } else if (std.ascii.startsWithIgnoreCase(line, "transfer-encoding:")) {
            const value = std.mem.trim(u8, line["transfer-encoding:".len..], " ");
            chunked = std.ascii.indexOfIgnoreCase(value, "chunked") != null;
        }

        i = line_end + 2;
    }

    return .{
        .status_code = status_code,
        .content_length = content_length,
        .chunked = chunked,
        .headers_end = headers_end,
        .body_start = headers_end,
        .buffer = buffer,
        .buffer_len = len,
    };
}

/// Parse a URL string into a RoundTripRequest (method defaults to GET).
pub fn requestFromUrl(url_str: []const u8) TransportError!RoundTripRequest {
    const parsed = url_mod.parse(url_str) catch return error.InvalidUrl;

    const scheme_str = parsed.scheme orelse "";
    const scheme: Scheme = if (std.mem.eql(u8, scheme_str, "https"))
        .https
    else if (std.mem.eql(u8, scheme_str, "http") or scheme_str.len == 0)
        .http
    else
        return error.InvalidUrl;

    const host = parsed.host orelse return error.InvalidUrl;
    if (host.len == 0) return error.InvalidUrl;

    const default_port: u16 = if (scheme == .https) 443 else 80;
    const port = parsed.port orelse default_port;
    const path = if (parsed.path.len > 0) parsed.path else "/";

    return .{
        .scheme = scheme,
        .host = host,
        .port = port,
        .path = path,
    };
}

// =========================================================================
// Tests
// =========================================================================

test "RoundTripper contract with mock" {
    const MockTransport = struct {
        const Self = @This();
        pub fn roundTrip(_: *Self, _: RoundTripRequest, buffer: []u8) TransportError!RoundTripResponse {
            const resp_text = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK";
            @memcpy(buffer[0..resp_text.len], resp_text);
            return parseHttpResponse(buffer, resp_text.len);
        }
    };
    _ = RoundTripper(MockTransport);

    var mock = MockTransport{};
    var buf: [256]u8 = undefined;
    const resp = try mock.roundTrip(.{ .host = "example.com" }, &buf);
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqualStrings("OK", resp.body());
}

test "requestFromUrl — HTTP" {
    const req = try requestFromUrl("http://example.com/api/v1?key=val");
    try std.testing.expectEqual(Scheme.http, req.scheme);
    try std.testing.expectEqualStrings("example.com", req.host);
    try std.testing.expectEqual(@as(u16, 80), req.port);
    try std.testing.expectEqualStrings("/api/v1", req.path);
}

test "requestFromUrl — HTTPS with port" {
    const req = try requestFromUrl("https://api.example.com:8443/data");
    try std.testing.expectEqual(Scheme.https, req.scheme);
    try std.testing.expectEqualStrings("api.example.com", req.host);
    try std.testing.expectEqual(@as(u16, 8443), req.port);
    try std.testing.expectEqualStrings("/data", req.path);
}

test "requestFromUrl — HTTPS default port" {
    const req = try requestFromUrl("https://secure.example.com/");
    try std.testing.expectEqual(Scheme.https, req.scheme);
    try std.testing.expectEqual(@as(u16, 443), req.port);
}

test "requestFromUrl — no path" {
    const req = try requestFromUrl("http://example.com");
    try std.testing.expectEqualStrings("/", req.path);
}

test "requestFromUrl — empty host" {
    try std.testing.expectError(error.InvalidUrl, requestFromUrl("http:///path"));
}

test "buildHttpRequest — GET" {
    var buf: [2048]u8 = undefined;
    const len = try buildHttpRequest(&buf, .{
        .host = "example.com",
        .path = "/api",
    });
    const req = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, req, "GET /api HTTP/1.1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Host: example.com\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Connection: close\r\n") != null);
}

test "buildHttpRequest — POST with body" {
    var buf: [2048]u8 = undefined;
    const len = try buildHttpRequest(&buf, .{
        .method = .POST,
        .host = "api.example.com",
        .path = "/submit",
        .body = "hello",
        .content_type = "text/plain",
    });
    const req = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, req, "POST /submit HTTP/1.1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Content-Length: 5\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Content-Type: text/plain\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, req, "hello"));
}

test "findHeaderEnd" {
    const data = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\nBody";
    const end = findHeaderEnd(data).?;
    try std.testing.expectEqual(@as(usize, 44), end);
    try std.testing.expectEqualStrings("Body", data[end..]);
}

test "findHeaderEnd — incomplete" {
    try std.testing.expect(findHeaderEnd("HTTP/1.1 200 OK\r\n") == null);
}

test "parseContentLength" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Length: 1234\r\n\r\n";
    try std.testing.expectEqual(@as(usize, 1234), parseContentLength(headers).?);
}

test "parseContentLength — absent" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n";
    try std.testing.expect(parseContentLength(headers) == null);
}

test "parseHttpResponse — 200 OK" {
    var buffer: [256]u8 = undefined;
    const text = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 13\r\n\r\nHello, World!";
    @memcpy(buffer[0..text.len], text);

    const resp = try parseHttpResponse(&buffer, text.len);
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqual(@as(usize, 13), resp.content_length.?);
    try std.testing.expect(!resp.chunked);
    try std.testing.expectEqualStrings("Hello, World!", resp.body());
}

test "parseHttpResponse — 404" {
    var buffer: [256]u8 = undefined;
    const text = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found";
    @memcpy(buffer[0..text.len], text);

    const resp = try parseHttpResponse(&buffer, text.len);
    try std.testing.expectEqual(@as(u16, 404), resp.status_code);
}

test "parseHttpResponse — chunked" {
    var buffer: [256]u8 = undefined;
    const text = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n";
    @memcpy(buffer[0..text.len], text);

    const resp = try parseHttpResponse(&buffer, text.len);
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expect(resp.chunked);
}

test "parseHttpResponse — too short" {
    var buffer: [8]u8 = undefined;
    try std.testing.expectError(error.InvalidResponse, parseHttpResponse(&buffer, 5));
}

test "RoundTripResponse.isSuccess" {
    var buffer: [256]u8 = undefined;

    const ok_text = "HTTP/1.1 200 OK\r\n\r\n";
    @memcpy(buffer[0..ok_text.len], ok_text);
    const ok_resp = try parseHttpResponse(&buffer, ok_text.len);
    try std.testing.expect(ok_resp.isSuccess());

    const err_text = "HTTP/1.1 500 Internal Server Error\r\n\r\n";
    @memcpy(buffer[0..err_text.len], err_text);
    const err_resp = try parseHttpResponse(&buffer, err_text.len);
    try std.testing.expect(!err_resp.isSuccess());
}

test "RoundTripResponse.headerValue" {
    var buffer: [256]u8 = undefined;
    const text = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Custom: hello\r\n\r\n{}";
    @memcpy(buffer[0..text.len], text);

    const resp = try parseHttpResponse(&buffer, text.len);
    try std.testing.expectEqualStrings("application/json", resp.headerValue("content-type").?);
    try std.testing.expectEqualStrings("hello", resp.headerValue("X-Custom").?);
    try std.testing.expect(resp.headerValue("X-Missing") == null);
}

test "isResponseComplete" {
    const complete = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello";
    try std.testing.expect(isResponseComplete(complete));

    const partial = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nhello";
    try std.testing.expect(!isResponseComplete(partial));

    const no_headers = "HTTP/1.1 200 OK\r\n";
    try std.testing.expect(!isResponseComplete(no_headers));
}

// =========================================================================
// Real network tests — Transport(Socket, void, void, void) for HTTP-only
// =========================================================================

test "Transport comptime validation" {
    const Socket = runtime.std.Socket;
    const T = Transport(Socket, void, void, void);
    _ = RoundTripper(T);
}

test "HTTP GET httpbin.org/get" {
    const Socket = runtime.std.Socket;
    const T = Transport(Socket, void, void, void);
    var t = T{ .allocator = std.testing.allocator, .dns_server = dns_mod.Servers.alidns };

    var buf: [8192]u8 = undefined;
    const resp = t.roundTrip(.{
        .host = "httpbin.org",
        .path = "/get",
        .timeout_ms = 10000,
    }, &buf) catch |err| switch (err) {
        error.ConnectionFailed, error.DnsResolveFailed, error.Timeout, error.ReceiveFailed => return,
        else => return err,
    };
    try std.testing.expect(resp.status_code == 200 or resp.status_code == 301 or resp.status_code == 302);
}

test "HTTP GET to IP address (no DNS)" {
    const Socket = runtime.std.Socket;
    const T = Transport(Socket, void, void, void);
    var t = T{ .allocator = std.testing.allocator };

    var buf: [4096]u8 = undefined;
    const resp = t.roundTrip(.{
        .host = "93.184.215.14",
        .port = 80,
        .path = "/",
        .timeout_ms = 10000,
    }, &buf) catch |err| switch (err) {
        error.ConnectionFailed, error.Timeout, error.ReceiveFailed => return,
        else => return err,
    };
    try std.testing.expect(resp.status_code >= 200 and resp.status_code < 600);
}

test "HTTP GET with DNS resolution" {
    const Socket = runtime.std.Socket;
    const T = Transport(Socket, void, void, void);
    var t = T{ .allocator = std.testing.allocator, .dns_server = dns_mod.Servers.alidns };

    var buf: [8192]u8 = undefined;
    const resp = t.roundTrip(.{
        .host = "www.baidu.com",
        .path = "/",
        .timeout_ms = 10000,
    }, &buf) catch |err| switch (err) {
        error.ConnectionFailed, error.DnsResolveFailed, error.Timeout, error.ReceiveFailed => return,
        else => return err,
    };
    try std.testing.expect(resp.status_code >= 200 and resp.status_code < 600);
    try std.testing.expect(resp.body().len > 0);
}

test "HTTP POST with body" {
    const Socket = runtime.std.Socket;
    const T = Transport(Socket, void, void, void);
    var t = T{ .allocator = std.testing.allocator, .dns_server = dns_mod.Servers.alidns };

    var buf: [8192]u8 = undefined;
    const resp = t.roundTrip(.{
        .method = .POST,
        .host = "httpbin.org",
        .path = "/post",
        .body = "{\"test\": true}",
        .content_type = "application/json",
        .timeout_ms = 10000,
    }, &buf) catch |err| switch (err) {
        error.ConnectionFailed, error.DnsResolveFailed, error.Timeout, error.ReceiveFailed => return,
        else => return err,
    };
    try std.testing.expect(resp.status_code == 200 or resp.status_code == 301 or resp.status_code == 302);
}

test "HTTP nonexistent host returns DnsResolveFailed" {
    const Socket = runtime.std.Socket;
    const T = Transport(Socket, void, void, void);
    var t = T{ .allocator = std.testing.allocator, .dns_server = dns_mod.Servers.alidns };

    var buf: [4096]u8 = undefined;
    const result = t.roundTrip(.{
        .host = "this.host.does.not.exist.invalid",
        .path = "/",
        .timeout_ms = 5000,
    }, &buf);
    try std.testing.expectError(error.DnsResolveFailed, result);
}

test "HTTP HTTPS without TLS returns TlsNotSupported" {
    const Socket = runtime.std.Socket;
    const T = Transport(Socket, void, void, void);
    var t = T{ .allocator = std.testing.allocator, .dns_server = dns_mod.Servers.alidns };

    var buf: [4096]u8 = undefined;
    const result = t.roundTrip(.{
        .scheme = .https,
        .host = "example.com",
        .port = 443,
        .path = "/",
        .timeout_ms = 5000,
    }, &buf);
    if (result) |_| {
        return error.ExpectedError;
    } else |err| {
        try std.testing.expect(err == error.TlsNotSupported or err == error.DnsResolveFailed);
    }
}

test "Transport with DomainResolver intercepts" {
    const Socket = runtime.std.Socket;
    const FakeResolver = struct {
        pub fn resolve(_: *const @This(), host: []const u8) ?[4]u8 {
            if (std.mem.eql(u8, host, "mydevice.local")) return .{ 127, 0, 0, 1 };
            return null;
        }
    };
    const T = Transport(Socket, void, void, FakeResolver);
    const custom = FakeResolver{};
    var t = T{
        .allocator = std.testing.allocator,
        .custom_resolver = &custom,
    };

    var buf: [4096]u8 = undefined;
    const result = t.roundTrip(.{
        .host = "mydevice.local",
        .port = 1,
        .path = "/",
        .timeout_ms = 1000,
    }, &buf);
    if (result) |_| {} else |err| {
        try std.testing.expect(err == error.ConnectionFailed);
    }
}

test "concurrent HTTP GETs from multiple threads" {
    const Socket = runtime.std.Socket;
    const T = Transport(Socket, void, void, void);

    const Worker = struct {
        fn run(host: []const u8) void {
            var t = T{ .allocator = std.testing.allocator, .dns_server = dns_mod.Servers.alidns };
            var buf: [8192]u8 = undefined;
            const resp = t.roundTrip(.{
                .host = host,
                .path = "/",
                .timeout_ms = 10000,
            }, &buf) catch return;
            std.debug.assert(resp.status_code >= 100 and resp.status_code < 600);
        }
    };

    var threads: [3]std.Thread = undefined;
    const hosts = [_][]const u8{ "www.baidu.com", "httpbin.org", "www.example.com" };
    for (hosts, 0..) |host, i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{host});
    }
    for (&threads) |*t| t.join();
}

test "concurrent HTTP requests — same host" {
    const Socket = runtime.std.Socket;
    const T = Transport(Socket, void, void, void);

    const Worker = struct {
        fn run() void {
            var t = T{ .allocator = std.testing.allocator, .dns_server = dns_mod.Servers.alidns };
            var buf: [8192]u8 = undefined;
            const resp = t.roundTrip(.{
                .host = "www.baidu.com",
                .path = "/",
                .timeout_ms = 10000,
            }, &buf) catch return;
            std.debug.assert(resp.status_code >= 100 and resp.status_code < 600);
        }
    };

    var threads: [4]std.Thread = undefined;
    for (0..4) |i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{});
    }
    for (&threads) |*t| t.join();
}
