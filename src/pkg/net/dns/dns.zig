//! Cross-Platform DNS Resolver
//!
//! Supports UDP, TCP, and DNS over HTTPS (DoH, RFC 8484).
//!
//! Example:
//!   const dns = @import("dns");
//!
//!   // Create resolver with platform socket (UDP/TCP only, no custom resolution)
//!   const R = dns.Resolver(Socket, void);
//!   var resolver = R{ .server = .{ 223, 5, 5, 5 }, .protocol = .udp };
//!
//!   // Create resolver with TLS support (UDP/TCP/HTTPS)
//!   const R2 = dns.ResolverWithTls(Socket, Crypto, Mutex, void);
//!   var resolver_tls = R2{
//!       .server = .{ 223, 5, 5, 5 },
//!       .protocol = .https,
//!       .doh_host = "dns.alidns.com",
//!       .allocator = allocator,
//!   };
//!
//!   const ip = try resolver.resolve("www.google.com");

const std = @import("std");
const runtime = struct {
    pub const socket = @import("../../../runtime/socket.zig");
    pub const sync = @import("../../../runtime/sync.zig");
    pub const std = @import("../../../runtime/std.zig");
};
const conn_mod = @import("../conn.zig");
const tls = struct {
    pub fn Client(comptime Conn: type, comptime Crypto: type, comptime Mutex: type) type {
        return @import("../tls/client.zig").Client(Conn, Crypto, Mutex);
    }
};

pub const Ipv4Address = [4]u8;

/// Well-known public DNS servers
pub const Servers = struct {
    /// AliDNS (China, anycast)
    pub const alidns: Ipv4Address = .{ 223, 5, 5, 5 };
    pub const alidns2: Ipv4Address = .{ 223, 6, 6, 6 };

    /// DNSPod / Tencent (China)
    pub const dnspod: Ipv4Address = .{ 119, 29, 29, 29 };

    /// 114 DNS (China)
    pub const dns114: Ipv4Address = .{ 114, 114, 114, 114 };
    pub const dns114_2: Ipv4Address = .{ 114, 114, 115, 115 };

    /// Google Public DNS (Global)
    pub const google: Ipv4Address = .{ 8, 8, 8, 8 };
    pub const google2: Ipv4Address = .{ 8, 8, 4, 4 };

    /// Cloudflare DNS (Global, anycast)
    pub const cloudflare: Ipv4Address = .{ 1, 1, 1, 1 };
    pub const cloudflare2: Ipv4Address = .{ 1, 0, 0, 1 };

    /// Quad9 (Global, security-focused)
    pub const quad9: Ipv4Address = .{ 9, 9, 9, 9 };

    /// OpenDNS / Cisco (Global)
    pub const opendns: Ipv4Address = .{ 208, 67, 222, 222 };
    pub const opendns2: Ipv4Address = .{ 208, 67, 220, 220 };
};

/// DoH (DNS over HTTPS) server hostnames, paired with Servers addresses
pub const DohHosts = struct {
    pub const alidns: []const u8 = "dns.alidns.com";
    pub const dnspod: []const u8 = "doh.pub";
    pub const google: []const u8 = "dns.google";
    pub const cloudflare: []const u8 = "cloudflare-dns.com";
    pub const quad9: []const u8 = "dns.quad9.net";
};

/// Preset server lists for different network environments
pub const ServerLists = struct {
    /// China optimized
    pub const china = [_]Ipv4Address{
        Servers.alidns,
        Servers.dnspod,
        Servers.dns114,
    };

    /// Global / overseas
    pub const global = [_]Ipv4Address{
        Servers.cloudflare,
        Servers.google,
        Servers.quad9,
    };

    /// Mixed (works everywhere)
    pub const mixed = [_]Ipv4Address{
        Servers.alidns,
        Servers.cloudflare,
        Servers.google,
    };
};

pub const DnsError = error{
    InvalidHostname,
    QueryBuildFailed,
    ResponseParseFailed,
    NoAnswer,
    SocketError,
    Timeout,
    TlsError,
    HttpError,
};

pub const Protocol = enum {
    udp,
    tcp,
    https,
};

/// DNS Resolver - generic over socket type (UDP/TCP only)
///
/// Type parameters:
///   - `Socket`: must satisfy `runtime.socket.from` contract
///   - `DomainResolver`: custom resolver consulted before upstream DNS.
///     Pass `void` to disable (zero overhead).
///
/// For DoH support, use `ResolverWithTls` instead.
pub fn Resolver(comptime Socket: type, comptime DomainResolver: type) type {
    return ResolverImpl(Socket, void, void, DomainResolver);
}

/// DNS Resolver with TLS support (UDP/TCP/HTTPS)
///
/// Type parameters:
///   - `Socket`: must satisfy `runtime.socket.from` contract
///   - `Crypto`: crypto primitives (must satisfy `runtime.crypto` contract)
///   - `Mutex`:  mutex type (must satisfy `runtime.sync.Mutex` contract)
///   - `DomainResolver`: custom resolver consulted before upstream DNS.
///     Pass `void` to disable (zero overhead).
pub fn ResolverWithTls(comptime Socket: type, comptime Crypto: type, comptime Mutex: type, comptime DomainResolver: type) type {
    const SConn = conn_mod.SocketConn(Socket);
    return ResolverImpl(Socket, tls.Client(SConn, Crypto, Mutex), Crypto, DomainResolver);
}

/// Validate DomainResolver interface at comptime.
///
/// A valid DomainResolver must have:
///   fn resolve(*const Self, []const u8) ?[4]u8
///
/// Pass `void` to disable custom resolution (zero overhead).
fn validateDomainResolver(comptime Impl: type) type {
    if (Impl == void) return void;

    comptime {
        if (!@hasDecl(Impl, "resolve")) {
            @compileError("DomainResolver must have fn resolve(*const @This(), []const u8) ?[4]u8");
        }
        const resolve_fn = @typeInfo(@TypeOf(Impl.resolve)).@"fn";
        if (resolve_fn.params.len != 2) {
            @compileError("DomainResolver.resolve must take (self, host) — 2 parameters");
        }
        if (resolve_fn.return_type) |ret| {
            if (ret != ?[4]u8) {
                @compileError("DomainResolver.resolve must return ?[4]u8");
            }
        }
    }
    return Impl;
}

fn ResolverImpl(comptime Socket: type, comptime TlsClient: type, comptime Crypto: type, comptime DomainResolver: type) type {
    comptime _ = runtime.socket.from(Socket);
    const has_tls = TlsClient != void;
    const has_custom_resolver = DomainResolver != void;

    // Validate DomainResolver at comptime
    const ValidatedResolver = validateDomainResolver(DomainResolver);

    // Get CaStore type from Crypto if available (same logic as tls.Client)
    const CaStore = if (Crypto != void and @hasDecl(Crypto, "x509") and @hasDecl(Crypto.x509, "CaStore"))
        Crypto.x509.CaStore
    else
        void;

    return struct {
        /// DNS server address (for UDP/TCP)
        server: Ipv4Address = .{ 8, 8, 8, 8 }, // Google DNS default

        /// Protocol to use
        protocol: Protocol = .udp,

        /// Timeout in milliseconds
        timeout_ms: u32 = 5000,

        /// DoH server host (for HTTPS protocol)
        doh_host: []const u8 = "dns.alidns.com",

        /// Allocator for TLS (required for DoH)
        allocator: ?std.mem.Allocator = null,

        /// DoH server port (usually 443)
        doh_port: u16 = 443,

        /// Skip TLS certificate verification (for testing)
        skip_cert_verify: bool = false,

        /// CA store for certificate verification (optional)
        /// If null and skip_cert_verify is false, verification may fail
        ca_store: if (CaStore != void) ?CaStore else void = if (CaStore != void) null else {},

        /// Custom domain resolver (consulted before upstream DNS)
        /// Only present when DomainResolver != void
        custom_resolver: if (has_custom_resolver) ?*const ValidatedResolver else void =
            if (has_custom_resolver) null else {},

        const Self = @This();

        /// Resolve hostname to IPv4 address
        pub fn resolve(self: *const Self, hostname: []const u8) DnsError!Ipv4Address {
            // Consult custom resolver first (comptime eliminated when DomainResolver = void)
            if (has_custom_resolver) {
                if (self.custom_resolver) |r| {
                    if (r.resolve(hostname)) |ip| return ip;
                }
            }

            return switch (self.protocol) {
                .udp => self.resolveUdp(hostname),
                .tcp => self.resolveTcp(hostname),
                .https => self.resolveHttps(hostname),
            };
        }

        fn resolveUdp(self: *const Self, hostname: []const u8) DnsError!Ipv4Address {
            var sock = Socket.udp() catch return error.SocketError;
            defer sock.close();

            sock.setRecvTimeout(self.timeout_ms);

            var query_buf: [512]u8 = undefined;
            const query_len = buildQuery(&query_buf, hostname, generateTxId()) catch return error.QueryBuildFailed;

            _ = sock.sendTo(self.server, 53, query_buf[0..query_len]) catch return error.SocketError;

            var response_buf: [512]u8 = undefined;
            const result = sock.recvFrom(&response_buf) catch |err| {
                return switch (err) {
                    error.Timeout => error.Timeout,
                    else => error.SocketError,
                };
            };

            return parseResponse(response_buf[0..result.len]) catch return error.ResponseParseFailed;
        }

        fn resolveTcp(self: *const Self, hostname: []const u8) DnsError!Ipv4Address {
            var sock = Socket.tcp() catch return error.SocketError;
            defer sock.close();

            sock.setRecvTimeout(self.timeout_ms);
            sock.setSendTimeout(self.timeout_ms);

            // Connect to DNS server
            sock.connect(self.server, 53) catch return error.SocketError;

            // Build query
            var query_buf: [514]u8 = undefined; // 2 bytes length prefix + 512 query
            const query_len = buildQuery(query_buf[2..], hostname, generateTxId()) catch return error.QueryBuildFailed;

            // TCP DNS: prepend 2-byte length
            query_buf[0] = @intCast((query_len >> 8) & 0xFF);
            query_buf[1] = @intCast(query_len & 0xFF);

            // Send query
            _ = sock.send(query_buf[0 .. query_len + 2]) catch return error.SocketError;

            // Receive length prefix
            var len_buf: [2]u8 = undefined;
            _ = sock.recv(&len_buf) catch |err| {
                return switch (err) {
                    error.Timeout => error.Timeout,
                    else => error.SocketError,
                };
            };
            const response_len: usize = (@as(usize, len_buf[0]) << 8) | len_buf[1];

            // Receive response
            var response_buf: [512]u8 = undefined;
            if (response_len > response_buf.len) return error.ResponseParseFailed;

            var total_read: usize = 0;
            while (total_read < response_len) {
                const n = sock.recv(response_buf[total_read..response_len]) catch |err| {
                    return switch (err) {
                        error.Timeout => error.Timeout,
                        else => error.SocketError,
                    };
                };
                if (n == 0) break;
                total_read += n;
            }

            // Parse response
            return parseResponse(response_buf[0..total_read]) catch return error.ResponseParseFailed;
        }

        fn resolveHttps(self: *const Self, hostname: []const u8) DnsError!Ipv4Address {
            if (!has_tls) return error.TlsError;

            const allocator = self.allocator orelse return error.TlsError;

            var query_buf: [512]u8 = undefined;
            const query_len = buildQuery(&query_buf, hostname, generateTxId()) catch return error.QueryBuildFailed;
            const query_data = query_buf[0..query_len];

            const doh_ip = self.resolveDohServer() catch return error.HttpError;

            var sock = Socket.tcp() catch return error.SocketError;
            errdefer sock.close();

            sock.setRecvTimeout(self.timeout_ms);
            sock.setSendTimeout(self.timeout_ms);
            sock.connect(doh_ip, self.doh_port) catch return error.SocketError;

            const SConn = conn_mod.SocketConn(Socket);
            var socket_conn = SConn.init(&sock);

            var tls_client = TlsClient.init(&socket_conn, if (CaStore != void) .{
                .allocator = allocator,
                .hostname = self.doh_host,
                .skip_verify = self.skip_cert_verify,
                .ca_store = self.ca_store,
                .timeout_ms = self.timeout_ms,
            } else .{
                .allocator = allocator,
                .hostname = self.doh_host,
                .skip_verify = self.skip_cert_verify,
                .timeout_ms = self.timeout_ms,
            }) catch return error.TlsError;
            defer tls_client.deinit();

            tls_client.connect() catch return error.TlsError;

            var request_buf: [1024]u8 = undefined;
            const request = buildHttpRequest(&request_buf, self.doh_host, query_data) catch return error.HttpError;

            _ = tls_client.send(request) catch return error.TlsError;

            var response_buf: [2048]u8 = undefined;
            var total_received: usize = 0;

            while (total_received < response_buf.len) {
                const n = tls_client.recv(response_buf[total_received..]) catch {
                    if (total_received > 0) break;
                    return error.TlsError;
                };
                if (n == 0) break;
                total_received += n;

                if (findHttpBody(response_buf[0..total_received])) |_| break;
            }

            const body = findHttpBody(response_buf[0..total_received]) orelse return error.HttpError;

            if (!std.mem.startsWith(u8, response_buf[0..total_received], "HTTP/1.1 200")) {
                return error.HttpError;
            }

            return parseResponse(body) catch return error.ResponseParseFailed;
        }

        fn resolveDohServer(self: *const Self) DnsError!Ipv4Address {
            if (parseIpv4String(self.doh_host)) |ip| return ip;

            var sock = Socket.udp() catch return error.SocketError;
            defer sock.close();

            sock.setRecvTimeout(self.timeout_ms);

            var query_buf: [512]u8 = undefined;
            const query_len = buildQuery(&query_buf, self.doh_host, generateTxId()) catch return error.QueryBuildFailed;

            _ = sock.sendTo(self.server, 53, query_buf[0..query_len]) catch return error.SocketError;

            var response_buf: [512]u8 = undefined;
            const result = sock.recvFrom(&response_buf) catch |err| {
                return switch (err) {
                    error.Timeout => error.Timeout,
                    else => error.SocketError,
                };
            };

            return parseResponse(response_buf[0..result.len]) catch return error.ResponseParseFailed;
        }
    };
}

// ============================================================================
// HTTP Helpers for DoH
// ============================================================================

/// Build HTTP POST request for DoH
pub fn buildHttpRequest(buf: []u8, host: []const u8, dns_query: []const u8) ![]const u8 {
    // HTTP/1.1 POST request with DNS wireformat body
    const header_fmt =
        "POST /dns-query HTTP/1.1\r\n" ++
        "Host: {s}\r\n" ++
        "Content-Type: application/dns-message\r\n" ++
        "Accept: application/dns-message\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";

    const header_len = std.fmt.bufPrint(buf, header_fmt, .{ host, dns_query.len }) catch return error.QueryBuildFailed;

    // Append DNS query body
    if (header_len.len + dns_query.len > buf.len) return error.QueryBuildFailed;

    @memcpy(buf[header_len.len..][0..dns_query.len], dns_query);

    return buf[0 .. header_len.len + dns_query.len];
}

/// Find HTTP body (after \r\n\r\n)
fn findHttpBody(data: []const u8) ?[]const u8 {
    const separator = "\r\n\r\n";
    if (std.mem.indexOf(u8, data, separator)) |pos| {
        return data[pos + separator.len ..];
    }
    return null;
}

/// Parse IPv4 string to address
fn parseIpv4String(s: []const u8) ?Ipv4Address {
    var result: Ipv4Address = undefined;
    var octet_idx: usize = 0;
    var current: u16 = 0;

    for (s) |c| {
        if (c == '.') {
            if (current > 255 or octet_idx >= 3) return null;
            result[octet_idx] = @intCast(current);
            octet_idx += 1;
            current = 0;
        } else if (c >= '0' and c <= '9') {
            current = current * 10 + (c - '0');
        } else {
            return null; // Not a pure IP address
        }
    }

    if (current > 255 or octet_idx != 3) return null;
    result[3] = @intCast(current);

    return result;
}

// ============================================================================
// DNS Protocol Helpers
// ============================================================================

/// Simple transaction ID generator
var tx_id_counter: u16 = 0x1234;

fn generateTxId() u16 {
    tx_id_counter +%= 1;
    return tx_id_counter;
}

/// Build DNS query packet
pub fn buildQuery(buf: []u8, hostname: []const u8, transaction_id: u16) !usize {
    if (hostname.len == 0 or hostname.len > 253) return error.InvalidHostname;

    var pos: usize = 0;

    // Transaction ID
    buf[pos] = @intCast((transaction_id >> 8) & 0xFF);
    buf[pos + 1] = @intCast(transaction_id & 0xFF);
    pos += 2;

    // Flags: standard query, recursion desired
    buf[pos] = 0x01;
    buf[pos + 1] = 0x00;
    pos += 2;

    // Questions: 1
    buf[pos] = 0x00;
    buf[pos + 1] = 0x01;
    pos += 2;

    // Answer RRs: 0
    buf[pos] = 0x00;
    buf[pos + 1] = 0x00;
    pos += 2;

    // Authority RRs: 0
    buf[pos] = 0x00;
    buf[pos + 1] = 0x00;
    pos += 2;

    // Additional RRs: 0
    buf[pos] = 0x00;
    buf[pos + 1] = 0x00;
    pos += 2;

    // Question section: encode hostname
    // "www.google.com" -> "\x03www\x06google\x03com\x00"
    var label_start = pos;
    pos += 1; // reserve space for label length

    for (hostname) |ch| {
        if (ch == '.') {
            // Write label length
            buf[label_start] = @intCast(pos - label_start - 1);
            label_start = pos;
            pos += 1;
        } else {
            buf[pos] = ch;
            pos += 1;
        }
    }
    // Last label
    buf[label_start] = @intCast(pos - label_start - 1);
    buf[pos] = 0x00; // null terminator
    pos += 1;

    // Type: A (1)
    buf[pos] = 0x00;
    buf[pos + 1] = 0x01;
    pos += 2;

    // Class: IN (1)
    buf[pos] = 0x00;
    buf[pos + 1] = 0x01;
    pos += 2;

    return pos;
}

/// Parse DNS response and extract first A record
pub fn parseResponse(data: []const u8) !Ipv4Address {
    if (data.len < 12) return error.ResponseParseFailed;

    // Check response code (lower 4 bits of byte 3)
    const rcode = data[3] & 0x0F;
    if (rcode != 0) return error.NoAnswer;

    // Get answer count
    const answer_count = (@as(u16, data[6]) << 8) | data[7];
    if (answer_count == 0) return error.NoAnswer;

    // Skip header (12 bytes)
    var pos: usize = 12;

    // Skip question section
    while (pos < data.len and data[pos] != 0) {
        if ((data[pos] & 0xC0) == 0xC0) {
            // Compression pointer
            pos += 2;
            break;
        }
        pos += @as(usize, data[pos]) + 1;
    }
    if (pos < data.len and data[pos] == 0) pos += 1;
    pos += 4; // Skip QTYPE and QCLASS

    // Parse answers
    var i: u16 = 0;
    while (i < answer_count and pos + 12 <= data.len) : (i += 1) {
        // Skip name (handle compression)
        if ((data[pos] & 0xC0) == 0xC0) {
            pos += 2;
        } else {
            while (pos < data.len and data[pos] != 0) {
                pos += @as(usize, data[pos]) + 1;
            }
            pos += 1;
        }

        if (pos + 10 > data.len) break;

        const rtype = (@as(u16, data[pos]) << 8) | data[pos + 1];
        pos += 2;
        // Skip class
        pos += 2;
        // Skip TTL
        pos += 4;
        const rdlength = (@as(u16, data[pos]) << 8) | data[pos + 1];
        pos += 2;

        // Type A (1) with 4-byte address
        if (rtype == 1 and rdlength == 4 and pos + 4 <= data.len) {
            return .{ data[pos], data[pos + 1], data[pos + 2], data[pos + 3] };
        }

        pos += rdlength;
    }

    return error.NoAnswer;
}

/// Format IPv4 address as string
pub fn formatIpv4(addr: Ipv4Address, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ addr[0], addr[1], addr[2], addr[3] }) catch "?.?.?.?";
}

// ============================================================================
// Tests
// ============================================================================

test "buildQuery" {
    var buf: [512]u8 = undefined;
    const len = try buildQuery(&buf, "www.google.com", 0x1234);

    // Check transaction ID
    try std.testing.expectEqual(@as(u8, 0x12), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x34), buf[1]);

    // Check query is reasonable length
    try std.testing.expect(len > 12);
    try std.testing.expect(len < 100);
}

test "parseIpv4String" {
    const ip = parseIpv4String("192.168.1.1").?;
    try std.testing.expectEqual(@as(u8, 192), ip[0]);
    try std.testing.expectEqual(@as(u8, 168), ip[1]);
    try std.testing.expectEqual(@as(u8, 1), ip[2]);
    try std.testing.expectEqual(@as(u8, 1), ip[3]);

    // Not an IP
    try std.testing.expect(parseIpv4String("dns.google.com") == null);
}

test "buildHttpRequest" {
    var buf: [1024]u8 = undefined;
    const dns_query = [_]u8{ 0x00, 0x01, 0x02 };
    const request = try buildHttpRequest(&buf, "dns.google.com", &dns_query);

    try std.testing.expect(std.mem.indexOf(u8, request, "POST /dns-query") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "Host: dns.google.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "Content-Length: 3") != null);
}

test "findHttpBody" {
    const response = "HTTP/1.1 200 OK\r\nContent-Type: application/dns-message\r\n\r\nBODY";
    const body = findHttpBody(response).?;
    try std.testing.expectEqualStrings("BODY", body);

    // No body separator
    try std.testing.expect(findHttpBody("incomplete") == null);
}

// ============================================================================
// DomainResolver Tests
// ============================================================================

test "validateDomainResolver: void is valid" {
    const V = validateDomainResolver(void);
    try std.testing.expect(V == void);
}

test "validateDomainResolver: valid resolver" {
    const MockResolver = struct {
        suffix: []const u8,

        pub fn resolve(self: *const @This(), host: []const u8) ?[4]u8 {
            if (std.mem.endsWith(u8, host, self.suffix)) {
                return .{ 10, 0, 0, 1 };
            }
            return null;
        }
    };

    const Validated = validateDomainResolver(MockResolver);
    try std.testing.expect(Validated == MockResolver);

    const resolver = MockResolver{ .suffix = ".zigor.net" };
    try std.testing.expectEqual(@as(?[4]u8, .{ 10, 0, 0, 1 }), resolver.resolve("abc.host.zigor.net"));
    try std.testing.expectEqual(@as(?[4]u8, null), resolver.resolve("www.google.com"));
}

const TestMockSocket = struct {
    pub fn udp() runtime.socket.Error!@This() {
        return .{};
    }
    pub fn tcp() runtime.socket.Error!@This() {
        return .{};
    }
    pub fn close(_: *@This()) void {}
    pub fn connect(_: *@This(), _: [4]u8, _: u16) runtime.socket.Error!void {}
    pub fn send(_: *@This(), _: []const u8) runtime.socket.Error!usize {
        return 0;
    }
    pub fn recv(_: *@This(), _: []u8) runtime.socket.Error!usize {
        return 0;
    }
    pub fn sendTo(_: *@This(), _: [4]u8, _: u16, _: []const u8) runtime.socket.Error!usize {
        return 0;
    }
    pub fn recvFrom(_: *@This(), _: []u8) runtime.socket.Error!runtime.socket.RecvFromResult {
        return .{ .len = 0, .src_addr = .{ 0, 0, 0, 0 }, .src_port = 0 };
    }
    pub fn setRecvTimeout(_: *@This(), _: u32) void {}
    pub fn setSendTimeout(_: *@This(), _: u32) void {}
    pub fn setTcpNoDelay(_: *@This(), _: bool) void {}
    pub fn getFd(_: *@This()) i32 {
        return 0;
    }
    pub fn setNonBlocking(_: *@This(), _: bool) runtime.socket.Error!void {}
    pub fn bind(_: *@This(), _: [4]u8, _: u16) runtime.socket.Error!void {}
    pub fn getBoundPort(_: *@This()) runtime.socket.Error!u16 {
        return 0;
    }
    pub fn listen(_: *@This()) runtime.socket.Error!void {}
    pub fn accept(_: *@This()) runtime.socket.Error!@This() {
        return .{};
    }
};

test "Resolver with void DomainResolver: custom_resolver is void (zero overhead)" {
    const R = Resolver(TestMockSocket, void);
    const fields = @typeInfo(R).@"struct".fields;
    comptime {
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, "custom_resolver")) {
                if (f.type != void) @compileError("expected void field");
            }
        }
    }
}

test "Resolver with DomainResolver has custom_resolver field" {
    const MockResolver = struct {
        pub fn resolve(_: *const @This(), host: []const u8) ?[4]u8 {
            if (std.mem.endsWith(u8, host, ".zigor.net")) {
                return .{ 10, 0, 0, 1 };
            }
            return null;
        }
    };

    const R = Resolver(TestMockSocket, MockResolver);
    try std.testing.expect(@hasField(R, "custom_resolver"));
}

// ============================================================================
// Real Network Tests (using runtime.std.Socket)
// ============================================================================

fn isAliDnsIp(ip: Ipv4Address) bool {
    return std.mem.eql(u8, &ip, &Servers.alidns) or std.mem.eql(u8, &ip, &Servers.alidns2);
}

test "UDP resolve dns.alidns.com via 223.5.5.5" {
    const Socket = runtime.std.Socket;
    const R = Resolver(Socket, void);
    const resolver = R{ .server = Servers.alidns, .protocol = .udp, .timeout_ms = 5000 };
    const ip = try resolver.resolve("dns.alidns.com");
    try std.testing.expect(isAliDnsIp(ip));
}

test "TCP resolve dns.alidns.com via 223.5.5.5" {
    const Socket = runtime.std.Socket;
    const R = Resolver(Socket, void);
    const resolver = R{ .server = Servers.alidns, .protocol = .tcp, .timeout_ms = 5000 };
    const ip = try resolver.resolve("dns.alidns.com");
    try std.testing.expect(isAliDnsIp(ip));
}

test "UDP and TCP resolve dns.alidns.com return same result" {
    const Socket = runtime.std.Socket;
    const R = Resolver(Socket, void);
    const udp_resolver = R{ .server = Servers.alidns, .protocol = .udp, .timeout_ms = 5000 };
    const tcp_resolver = R{ .server = Servers.alidns, .protocol = .tcp, .timeout_ms = 5000 };
    const udp_ip = try udp_resolver.resolve("dns.alidns.com");
    const tcp_ip = try tcp_resolver.resolve("dns.alidns.com");
    try std.testing.expect(isAliDnsIp(udp_ip));
    try std.testing.expect(isAliDnsIp(tcp_ip));
}

test "UDP resolve www.baidu.com returns valid IPv4" {
    const Socket = runtime.std.Socket;
    const R = Resolver(Socket, void);
    const resolver = R{ .server = Servers.alidns, .protocol = .udp, .timeout_ms = 5000 };
    const ip = try resolver.resolve("www.baidu.com");
    try std.testing.expect(ip[0] != 0);
}

test "TCP resolve www.baidu.com returns valid IPv4" {
    const Socket = runtime.std.Socket;
    const R = Resolver(Socket, void);
    const resolver = R{ .server = Servers.alidns, .protocol = .tcp, .timeout_ms = 5000 };
    const ip = try resolver.resolve("www.baidu.com");
    try std.testing.expect(ip[0] != 0);
}

test "UDP resolve via Google DNS 8.8.8.8" {
    const Socket = runtime.std.Socket;
    const R = Resolver(Socket, void);
    const resolver = R{ .server = Servers.google, .protocol = .udp, .timeout_ms = 5000 };
    const ip = try resolver.resolve("dns.google");
    try std.testing.expect(ip[0] == 8 and ip[1] == 8);
}

test "UDP resolve nonexistent domain returns error" {
    const Socket = runtime.std.Socket;
    const R = Resolver(Socket, void);
    const resolver = R{ .server = Servers.alidns, .protocol = .udp, .timeout_ms = 5000 };
    if (resolver.resolve("this.domain.does.not.exist.invalid")) |_| {
        return error.ExpectedError;
    } else |err| {
        try std.testing.expect(err == error.NoAnswer or err == error.ResponseParseFailed);
    }
}

test "UDP resolve multiple domains sequentially" {
    const Socket = runtime.std.Socket;
    const R = Resolver(Socket, void);
    const resolver = R{ .server = Servers.alidns, .protocol = .udp, .timeout_ms = 5000 };

    const domains = [_][]const u8{ "www.google.com", "www.baidu.com", "github.com" };
    for (domains) |domain| {
        const ip = try resolver.resolve(domain);
        try std.testing.expect(ip[0] != 0);
    }
}

test "DomainResolver intercepts before upstream" {
    const Socket = runtime.std.Socket;
    const FakeResolver = struct {
        pub fn resolve(_: *const @This(), host: []const u8) ?[4]u8 {
            if (std.mem.eql(u8, host, "fake.local")) return .{ 10, 0, 0, 99 };
            return null;
        }
    };
    const R = Resolver(Socket, FakeResolver);
    const custom = FakeResolver{};
    const resolver = R{
        .server = Servers.alidns,
        .protocol = .udp,
        .timeout_ms = 5000,
        .custom_resolver = &custom,
    };

    const ip = try resolver.resolve("fake.local");
    try std.testing.expectEqual(Ipv4Address{ 10, 0, 0, 99 }, ip);

    const real_ip = try resolver.resolve("dns.alidns.com");
    try std.testing.expect(isAliDnsIp(real_ip));
}

test "UDP resolve via Cloudflare DNS 1.1.1.1" {
    const Socket = runtime.std.Socket;
    const R = Resolver(Socket, void);
    const resolver = R{ .server = Servers.cloudflare, .protocol = .udp, .timeout_ms = 5000 };
    const ip = try resolver.resolve("cloudflare.com");
    try std.testing.expect(ip[0] != 0);
}

test "TCP resolve via Cloudflare DNS 1.1.1.1" {
    const Socket = runtime.std.Socket;
    const R = Resolver(Socket, void);
    const resolver = R{ .server = Servers.cloudflare, .protocol = .tcp, .timeout_ms = 5000 };
    const ip = try resolver.resolve("cloudflare.com");
    try std.testing.expect(ip[0] != 0);
}

test "UDP resolve dns.google via Google DNS returns 8.8.x.x" {
    const Socket = runtime.std.Socket;
    const R = Resolver(Socket, void);
    const resolver = R{ .server = Servers.google, .protocol = .udp, .timeout_ms = 5000 };
    const ip = try resolver.resolve("dns.google");
    try std.testing.expect(ip[0] == 8 and ip[1] == 8);
}

test "formatIpv4 round-trip" {
    const ip = Ipv4Address{ 223, 5, 5, 5 };
    var buf: [16]u8 = undefined;
    const s = formatIpv4(ip, &buf);
    try std.testing.expectEqualStrings("223.5.5.5", s);
}

test "formatIpv4 zeros" {
    var buf: [16]u8 = undefined;
    const s = formatIpv4(.{ 0, 0, 0, 0 }, &buf);
    try std.testing.expectEqualStrings("0.0.0.0", s);
}

test "formatIpv4 max" {
    var buf: [16]u8 = undefined;
    const s = formatIpv4(.{ 255, 255, 255, 255 }, &buf);
    try std.testing.expectEqualStrings("255.255.255.255", s);
}

test "parseResponse: too short" {
    const data = [_]u8{ 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.ResponseParseFailed, parseResponse(&data));
}

test "parseResponse: rcode NXDOMAIN" {
    var data = [_]u8{0} ** 12;
    data[3] = 0x03; // NXDOMAIN
    try std.testing.expectError(error.NoAnswer, parseResponse(&data));
}

test "parseResponse: zero answers" {
    var data = [_]u8{0} ** 12;
    data[2] = 0x81; // QR=1, RD=1
    data[3] = 0x80; // RA=1, rcode=0
    data[6] = 0; // ANCOUNT = 0
    data[7] = 0;
    try std.testing.expectError(error.NoAnswer, parseResponse(&data));
}

test "buildQuery: empty hostname" {
    var buf: [512]u8 = undefined;
    try std.testing.expectError(error.InvalidHostname, buildQuery(&buf, "", 0x1234));
}

test "buildQuery: hostname too long" {
    const long = "a" ** 254;
    var buf: [512]u8 = undefined;
    try std.testing.expectError(error.InvalidHostname, buildQuery(&buf, long, 0x1234));
}

test "buildQuery: single label" {
    var buf: [512]u8 = undefined;
    const len = try buildQuery(&buf, "localhost", 0xABCD);
    try std.testing.expectEqual(@as(u8, 0xAB), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xCD), buf[1]);
    try std.testing.expect(len > 12);
}

test "Servers constants are valid" {
    try std.testing.expectEqual(Ipv4Address{ 223, 5, 5, 5 }, Servers.alidns);
    try std.testing.expectEqual(Ipv4Address{ 223, 6, 6, 6 }, Servers.alidns2);
    try std.testing.expectEqual(Ipv4Address{ 119, 29, 29, 29 }, Servers.dnspod);
    try std.testing.expectEqual(Ipv4Address{ 8, 8, 8, 8 }, Servers.google);
    try std.testing.expectEqual(Ipv4Address{ 8, 8, 4, 4 }, Servers.google2);
    try std.testing.expectEqual(Ipv4Address{ 1, 1, 1, 1 }, Servers.cloudflare);
    try std.testing.expectEqual(Ipv4Address{ 1, 0, 0, 1 }, Servers.cloudflare2);
    try std.testing.expectEqual(Ipv4Address{ 9, 9, 9, 9 }, Servers.quad9);
}

test "DohHosts constants are non-empty" {
    try std.testing.expect(DohHosts.alidns.len > 0);
    try std.testing.expect(DohHosts.google.len > 0);
    try std.testing.expect(DohHosts.cloudflare.len > 0);
}

test "ServerLists have entries" {
    try std.testing.expect(ServerLists.china.len >= 2);
    try std.testing.expect(ServerLists.global.len >= 2);
    try std.testing.expect(ServerLists.mixed.len >= 2);
}

test "concurrent UDP resolves from multiple threads" {
    const Socket = runtime.std.Socket;
    const R = Resolver(Socket, void);

    const Worker = struct {
        fn run(domain: []const u8) void {
            const resolver = R{ .server = Servers.alidns, .protocol = .udp, .timeout_ms = 5000 };
            const ip = resolver.resolve(domain) catch return;
            std.debug.assert(ip[0] != 0);
        }
    };

    var threads: [4]std.Thread = undefined;
    const domains = [_][]const u8{ "www.baidu.com", "www.google.com", "github.com", "dns.alidns.com" };
    for (domains, 0..) |domain, i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{domain});
    }
    for (&threads) |*t| t.join();
}

test "concurrent TCP resolves from multiple threads" {
    const Socket = runtime.std.Socket;
    const R = Resolver(Socket, void);

    const Worker = struct {
        fn run(domain: []const u8) void {
            const resolver = R{ .server = Servers.alidns, .protocol = .tcp, .timeout_ms = 5000 };
            const ip = resolver.resolve(domain) catch return;
            std.debug.assert(ip[0] != 0);
        }
    };

    var threads: [4]std.Thread = undefined;
    const domains = [_][]const u8{ "www.baidu.com", "www.google.com", "github.com", "dns.alidns.com" };
    for (domains, 0..) |domain, i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{domain});
    }
    for (&threads) |*t| t.join();
}

test "concurrent mixed UDP+TCP resolves" {
    const Socket = runtime.std.Socket;
    const R = Resolver(Socket, void);

    const Worker = struct {
        fn run(proto: Protocol) void {
            const resolver = R{ .server = Servers.alidns, .protocol = proto, .timeout_ms = 5000 };
            const ip = resolver.resolve("dns.alidns.com") catch return;
            std.debug.assert(std.mem.eql(u8, &ip, &Servers.alidns) or std.mem.eql(u8, &ip, &Servers.alidns2));
        }
    };

    var threads: [6]std.Thread = undefined;
    const protos = [_]Protocol{ .udp, .tcp, .udp, .tcp, .udp, .tcp };
    for (protos, 0..) |proto, i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{proto});
    }
    for (&threads) |*t| t.join();
}

test "concurrent resolves with different DNS servers" {
    const Socket = runtime.std.Socket;
    const R = Resolver(Socket, void);

    const Worker = struct {
        fn run(server: Ipv4Address) void {
            const resolver = R{ .server = server, .protocol = .udp, .timeout_ms = 5000 };
            const ip = resolver.resolve("www.baidu.com") catch return;
            std.debug.assert(ip[0] != 0);
        }
    };

    var threads: [3]std.Thread = undefined;
    const servers = [_]Ipv4Address{ Servers.alidns, Servers.google, Servers.cloudflare };
    for (servers, 0..) |server, i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{server});
    }
    for (&threads) |*t| t.join();
}

// =========================================================================
// DoH (DNS over HTTPS) tests — requires TLS + Crypto
// =========================================================================

test "DoH resolve dns.alidns.com via AliDNS" {
    const Socket = runtime.std.Socket;
    const Crypto = runtime.std.Crypto;
    const Mutex = runtime.std.Mutex;
    const R = ResolverWithTls(Socket, Crypto, Mutex, void);
    const resolver = R{
        .server = Servers.alidns,
        .protocol = .https,
        .doh_host = DohHosts.alidns,
        .doh_port = 443,
        .skip_cert_verify = true,
        .allocator = std.testing.allocator,
        .timeout_ms = 15000,
    };
    const ip = resolver.resolve("dns.alidns.com") catch |err| switch (err) {
        error.TlsError, error.Timeout, error.SocketError, error.HttpError => return,
        else => return err,
    };
    try std.testing.expect(isAliDnsIp(ip));
}

test "DoH resolve www.baidu.com via AliDNS" {
    const Socket = runtime.std.Socket;
    const Crypto = runtime.std.Crypto;
    const Mutex = runtime.std.Mutex;
    const R = ResolverWithTls(Socket, Crypto, Mutex, void);
    const resolver = R{
        .server = Servers.alidns,
        .protocol = .https,
        .doh_host = DohHosts.alidns,
        .doh_port = 443,
        .skip_cert_verify = true,
        .allocator = std.testing.allocator,
        .timeout_ms = 15000,
    };
    const ip = resolver.resolve("www.baidu.com") catch |err| switch (err) {
        error.TlsError, error.Timeout, error.SocketError, error.HttpError => return,
        else => return err,
    };
    try std.testing.expect(ip[0] != 0);
}

test "DoH resolve via Cloudflare" {
    const Socket = runtime.std.Socket;
    const Crypto = runtime.std.Crypto;
    const Mutex = runtime.std.Mutex;
    const R = ResolverWithTls(Socket, Crypto, Mutex, void);
    const resolver = R{
        .server = Servers.cloudflare,
        .protocol = .https,
        .doh_host = DohHosts.cloudflare,
        .doh_port = 443,
        .skip_cert_verify = true,
        .allocator = std.testing.allocator,
        .timeout_ms = 15000,
    };
    const ip = resolver.resolve("www.google.com") catch |err| switch (err) {
        error.TlsError, error.Timeout, error.SocketError, error.HttpError => return,
        else => return err,
    };
    try std.testing.expect(ip[0] != 0);
}

test "DoH resolve via Google" {
    const Socket = runtime.std.Socket;
    const Crypto = runtime.std.Crypto;
    const Mutex = runtime.std.Mutex;
    const R = ResolverWithTls(Socket, Crypto, Mutex, void);
    const resolver = R{
        .server = Servers.google,
        .protocol = .https,
        .doh_host = DohHosts.google,
        .doh_port = 443,
        .skip_cert_verify = true,
        .allocator = std.testing.allocator,
        .timeout_ms = 15000,
    };
    const ip = resolver.resolve("github.com") catch |err| switch (err) {
        error.TlsError, error.Timeout, error.SocketError, error.HttpError => return,
        else => return err,
    };
    try std.testing.expect(ip[0] != 0);
}

test "DoH nonexistent domain returns error" {
    const Socket = runtime.std.Socket;
    const Crypto = runtime.std.Crypto;
    const Mutex = runtime.std.Mutex;
    const R = ResolverWithTls(Socket, Crypto, Mutex, void);
    const resolver = R{
        .server = Servers.alidns,
        .protocol = .https,
        .doh_host = DohHosts.alidns,
        .doh_port = 443,
        .skip_cert_verify = true,
        .allocator = std.testing.allocator,
        .timeout_ms = 15000,
    };
    if (resolver.resolve("this.domain.does.not.exist.invalid")) |_| {
        return error.ExpectedError;
    } else |err| {
        try std.testing.expect(err == error.NoAnswer or err == error.ResponseParseFailed or
            err == error.TlsError or err == error.Timeout or err == error.HttpError);
    }
}

test "concurrent DoH resolves from multiple threads" {
    const Socket = runtime.std.Socket;
    const Crypto = runtime.std.Crypto;
    const Mutex = runtime.std.Mutex;
    const R = ResolverWithTls(Socket, Crypto, Mutex, void);

    const Worker = struct {
        fn run(domain: []const u8) void {
            const resolver = R{
                .server = Servers.alidns,
                .protocol = .https,
                .doh_host = DohHosts.alidns,
                .doh_port = 443,
                .skip_cert_verify = true,
                .allocator = std.testing.allocator,
                .timeout_ms = 15000,
            };
            const ip = resolver.resolve(domain) catch return;
            std.debug.assert(ip[0] != 0);
        }
    };

    var threads: [3]std.Thread = undefined;
    const domains = [_][]const u8{ "www.baidu.com", "www.google.com", "github.com" };
    for (domains, 0..) |domain, i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{domain});
    }
    for (&threads) |*t| t.join();
}
