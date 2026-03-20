# lib/net — Go-style networking for embed-zig

High-level networking package built on top of `embed`. Takes a comptime
`lib` (the result of `embed.Make(platform)`) and provides Go-style
networking primitives.

## Table of Contents

- [Design principles](#design-principles)
- [Dependency](#dependency)
- [Package structure](#package-structure)
- [Layer diagram](#layer-diagram)
- [net (root)](#net-root)
  - [Conn](#conn)
  - [Listener](#listener)
  - [PacketConn](#packetconn)
  - [Dial / Listen](#dial--listen)
  - [ListenPacket](#listenpacket)
- [net/url](#neturl)
- [net/Resolver (DNS)](#netresolver-dns)
- [net/tls](#nettls)
- [net/http](#nethttp)
- [net/ws](#netws)
- [Usage examples](#usage-examples)

## Design principles

1. **Comptime `lib` injection.** Every module takes `comptime lib: type`
   (the sealed embed namespace) and builds types from `lib.posix`,
   `lib.Thread`, `lib.time`, etc. No global state, no runtime dispatch.

2. **Contract-based composition.** `Conn` is the universal byte stream
   contract (like Go's `net.Conn`). TLS wraps a Conn and produces a Conn.
   HTTP and WebSocket consume a Conn. Any transport satisfying `Conn`
   composes with any protocol layer.

3. **Zero-allocation parsing.** URL, HTTP request/response, DNS packets
   — parsers return slices into the input buffer.

4. **Allocator-explicit.** Types that need heap take an `Allocator`
   parameter. No hidden allocations.

5. **Go naming, Zig idioms.** Follow Go's `net` package naming where
   possible (`Dial`, `Listen`, `Conn`, `Listener`), but use Zig error
   unions, comptime generics, and explicit allocators.

## Dependency

```zig
const embed = @import("embed").Make(platform);
const net = @import("net").Make(embed);
```

`lib/net` depends on the sealed `embed` namespace for:
- `lib.posix` — socket, bind, listen, accept, connect, send, recv, poll, close
- `lib.Thread` — Mutex (TLS thread safety)
- `lib.time` — timeouts
- `lib.net.Ip4Address` — address construction

## Package structure

```
lib/net/
  net.zig              Root; Make(lib) entry point, Conn, Listener, PacketConn, Dial, Listen
  Conn.zig             Type-erased byte stream interface (Go's net.Conn)
  Listener.zig         Type-erased stream listener interface (Go's net.Listener)
  PacketConn.zig       Type-erased datagram interface (Go's net.PacketConn)
  TcpConn.zig          Conn over TCP socket fd (Go's net.TCPConn)
  UdpConn.zig          PacketConn + Conn over UDP socket fd (Go's net.UDPConn)
  TcpListener.zig      Listener for TCP (Go's net.TCPListener)
  Dialer.zig           Configurable TCP dialer (Go's net.Dialer)
  url.zig              Zero-alloc URL parser (RFC 3986)
  Resolver.zig         Pure-Zig DNS resolver (RFC 1035, UDP with TCP fallback)
  tls/
    stream.zig         TLS stream (Conn -> Conn)
    client.zig         TLS client state machine
    handshake.zig      TLS 1.2/1.3 handshake
    record.zig         TLS record layer
    ...
  http/
    client.zig         HTTP client
    transport.zig      RoundTripper contract + default Transport
    request.zig        HTTP request builder/parser
    response.zig       HTTP response parser
    server.zig         HTTP/1.1 server
    router.zig         Path-based request router
  ws/
    client.zig         WebSocket client (RFC 6455)
    frame.zig          WebSocket frame codec
```

## Layer diagram

```
┌─────────────────────────────────────────────────┐
│                  User code                       │
├──────────┬──────────┬───────────────────────────┤
│ net/http │  net/ws  │       (future)             │
├──────────┴──────────┤                            │
│       net/tls       │                            │
│  (Conn -> Conn)     │                            │
├─────────────────────┼───────────────────────────┤
│   Conn (stream)     │   PacketConn (datagram)    │
│   TcpConn           │   UdpConn                  │
├──────────┬──────────┼───────────────────────────┤
│   Dial   │  Listen  │   ListenPacket             │
├──────────┴──────────┴───────────────────────────┤
│              net/Resolver    net/url              │
├─────────────────────────────────────────────────┤
│              lib (embed.Make)                    │
│   posix / Thread / time / net.Address           │
└─────────────────────────────────────────────────┘
```

## net (root)

The root package provides the core types and top-level functions,
mirroring Go's `net` package.

### Conn

Type-erased bidirectional byte stream (Go's `net.Conn`). VTable-based,
same pattern as `std.mem.Allocator`. Any concrete type with
read/write/close can be wrapped into a Conn.

```zig
pub const VTable = struct {
    read:  *const fn (*anyopaque, []u8) ReadError!usize,
    write: *const fn (*anyopaque, []const u8) WriteError!usize,
    close: *const fn (*anyopaque) void,
    deinit: ?*const fn (*anyopaque) void = null,
};
```

Concrete implementations: **TcpConn** (TCP socket fd), **UdpConn** (connected UDP), **tls.Stream** (future).

### Listener

Type-erased stream listener (Go's `net.Listener`). Returns Conn on accept.

```zig
pub const VTable = struct {
    accept: *const fn (*anyopaque) AcceptError!Conn,
    close:  *const fn (*anyopaque) void,
};
```

Concrete implementation: **TcpListener**.

### PacketConn

Type-erased datagram interface (Go's `net.PacketConn`). VTable-based,
for connectionless protocols like UDP.

Unlike `Conn` (stream-oriented), `PacketConn` is message-oriented:
each `readFrom`/`writeTo` operates on a single datagram with an
associated remote address.

```zig
// PacketConn.zig
const PacketConn = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    readFrom:  *const fn (ptr: *anyopaque, buf: []u8) ReadFromError!ReadResult,
    writeTo:   *const fn (ptr: *anyopaque, buf: []const u8, addr: *const posix.sockaddr, addr_len: posix.socklen_t) WriteToError!usize,
    close:     *const fn (ptr: *anyopaque) void,
    deinit:    ?*const fn (ptr: *anyopaque) void = null,
};

pub const ReadResult = struct {
    bytes_read: usize,
    src_addr: posix.sockaddr.storage,
    addr_len: posix.socklen_t,
};

pub const ReadFromError = error{ WouldBlock, TimedOut, Unexpected };
pub const WriteToError = error{ MessageTooLong, NetworkUnreachable, TimedOut, Unexpected };

pub fn readFrom(self: PacketConn, buf: []u8) ReadFromError!ReadResult { ... }
pub fn writeTo(self: PacketConn, buf: []const u8, addr: Address) WriteToError!usize { ... }
pub fn close(self: PacketConn) void { ... }
pub fn deinit(self: PacketConn) void { ... }

/// Wrap any concrete type with readFrom/writeTo/close into a PacketConn.
pub fn init(pointer: anytype) PacketConn { ... }
```

Concrete implementation: **UdpConn**.

**UdpConn** — wraps a UDP socket fd into a PacketConn:

```zig
// UdpConn.zig
pub fn UdpConn(comptime lib: type) type {
    const posix = lib.posix;
    const Addr = lib.net.Address;
    const Allocator = lib.mem.Allocator;

    return struct {
        fd: posix.socket_t,
        allocator: ?Allocator = null,
        closed: bool = false,

        pub fn init(fd: posix.socket_t) Self { ... }

        /// Receive a datagram. Returns bytes read + source address.
        pub fn readFrom(self: *Self, buf: []u8) PacketConn.ReadFromError!PacketConn.ReadResult { ... }

        /// Send a datagram to the given address.
        pub fn writeTo(self: *Self, buf: []const u8, addr: Addr) PacketConn.WriteToError!usize { ... }

        pub fn close(self: *Self) void { ... }
        pub fn deinit(self: *Self) void { ... }

        /// Return the bound local address (useful after binding to port 0).
        pub fn localAddr(self: *Self) !Addr { ... }

        /// Type-erase into PacketConn.
        pub fn packetConn(self: *Self) PacketConn { ... }
    };
}
```

### Dial / Listen

TCP convenience functions (already implemented):

```zig
// Connect to a remote address (TCP):
var conn = try net.dial(allocator, Addr.initIp4(.{127,0,0,1}, 80));
defer conn.deinit();

// Listen for TCP connections:
var ln = try net.listen(allocator, .{ .address = Addr.initIp4(.{0,0,0,0}, 8080) });
defer ln.close();
```

`dialHost` resolves a hostname via DNS before connecting:

```zig
var conn = try net.dialHost(allocator, "example.com", 443);
defer conn.deinit();
```

### ListenPacket

Bind a UDP socket and return a UdpConn (Go's `net.ListenPacket`):

```zig
// Listen for UDP datagrams on port 5353:
var uc = try net.listenPacket(allocator, .{
    .address = Addr.initIp4(.{ 0, 0, 0, 0 }, 5353),
});
defer uc.close();

// Receive a datagram:
var buf: [512]u8 = undefined;
const result = try uc.readFrom(&buf);
const data = buf[0..result.bytes_read];

// Send a response back to the sender:
_ = try uc.writeTo("reply", result.srcAddr());
```

Also exposed as `net.listenPacket` in `Make`:

```zig
pub fn listenPacket(allocator: Allocator, opts: ListenPacketOptions) !UdpConn {
    // socket(AF, DGRAM) + bind
}

pub const ListenPacketOptions = struct {
    address: Addr = Addr.initIp4(.{ 0, 0, 0, 0 }, 0),
    reuse_addr: bool = true,
};
```

## net/url

Zero-allocation URL parser (Go's `net/url`). Pure function, no platform
dependency, no comptime `lib` needed.

```zig
const u = try net.url.parse("https://user:pass@example.com:8080/path?q=1#frag");
// u.scheme, u.host, u.port, u.path, u.raw_query, u.fragment, ...
```

All fields are slices into the input string.

## net/Resolver (DNS)

Pure-Zig DNS resolver (Go's `net.Resolver`). Builds and parses DNS
wire-format packets (RFC 1035) directly — no libc `getaddrinfo`,
no CGO, fully portable across embed platforms.

Reference: Zig std's `ResolvConf` + `resMSendRc` (ported from musl)
already supports multiple nameservers and parallel A+AAAA queries.
We adopt the same strategy but with a cleaner API.

### Design decisions

| Aspect                  | Zig std (`getAddressList`)            | embed `net.Resolver`                        |
|-------------------------|---------------------------------------|---------------------------------------------|
| Server config           | Parse `/etc/resolv.conf` (Linux only) | Explicit `[]const Addr` array               |
| Parallel queries        | A+AAAA sent to all NS in parallel     | Same: fan-out to all servers, A+AAAA        |
| Result storage          | Heap `ArrayList(LookupAddr)`          | Caller-provided `[]Address` buffer          |
| Timeout / retry         | From resolv.conf (`timeout`, `attempts`) | Explicit in `Options`                    |
| Platform                | Linux-specific, musl port             | Platform-agnostic via `lib.posix`           |
| Protocol                | UDP only (no TCP fallback)            | UDP + TCP fallback on truncation            |

### Resolver struct

```zig
pub fn Resolver(comptime lib: type) type {
    const posix = lib.posix;
    const Addr = lib.net.Address;
    const Allocator = lib.mem.Allocator;

    return struct {
        allocator: Allocator,
        options: Options,

        const Self = @This();

        pub const Options = struct {
            /// DNS server addresses. Queries are sent to ALL servers in parallel.
            /// Default: Google DNS (8.8.8.8) + Cloudflare (1.1.1.1).
            servers: []const Addr = &.{
                Addr.initIp4(.{ 8, 8, 8, 8 }, 53),
                Addr.initIp4(.{ 1, 1, 1, 1 }, 53),
            },
            /// Total timeout in milliseconds (default: 5000ms).
            timeout_ms: u32 = 5000,
            /// Number of retry attempts per server (default: 2).
            attempts: u32 = 2,
            /// Query mode: which record types to request.
            mode: QueryMode = .ipv4_and_ipv6,
        };

        pub const QueryMode = enum {
            ipv4_only,      // A records only
            ipv6_only,      // AAAA records only
            ipv4_and_ipv6,  // Both A + AAAA in parallel (like std)
        };

        pub const LookupError = error{
            NameNotFound,       // NXDOMAIN (rcode 3)
            ServerFailure,      // SERVFAIL (rcode 2)
            Refused,            // REFUSED (rcode 5)
            Timeout,
            InvalidResponse,
            NoServerConfigured,
        } || posix.SocketError || posix.SendToError || posix.RecvFromError;

        pub fn init(allocator: Allocator, options: Options) Self {
            return .{ .allocator = allocator, .options = options };
        }

        /// Resolve hostname to IP addresses.
        /// Returns the number of addresses written to `buf`.
        ///
        /// Strategy (mirrors Zig std's resMSendRc):
        ///   1. Build query packets (A, and AAAA if mode includes ipv6)
        ///   2. Open a single UDP socket (NONBLOCK)
        ///   3. Fan-out: send each query to ALL configured servers
        ///   4. Poll for responses; match by query ID
        ///   5. On SERVFAIL, retry up to `attempts` times
        ///   6. Retry all unanswered queries at `timeout / attempts` intervals
        ///   7. Extract A/AAAA records from responses into `buf`
        pub fn lookupHost(self: Self, name: []const u8, buf: []Addr) LookupError!usize {
            _ = self;
            _ = name;
            _ = buf;
            // Implementation follows resMSendRc pattern
        }

        /// Reverse DNS lookup (PTR record).
        /// Writes the resolved hostname into `name_buf`.
        /// Returns the written slice.
        pub fn lookupAddr(self: Self, addr: Addr, name_buf: []u8) LookupError![]const u8 {
            _ = self;
            _ = addr;
            _ = name_buf;
            // Build PTR query for in-addr.arpa / ip6.arpa
        }
    };
}
```

### Query flow (internal)

```
lookupHost("example.com")
  │
  ├─ buildQuery(buf[0], "example.com", A,    random_id)
  ├─ buildQuery(buf[1], "example.com", AAAA, random_id)   ← if ipv4_and_ipv6
  │
  ├─ socket(AF_INET or AF_INET6, DGRAM | NONBLOCK)
  │
  ├─ for each retry interval:
  │     for each unanswered query:
  │       for each server in options.servers:
  │         sendto(fd, query, server_addr)                 ← parallel fan-out
  │
  │     poll(fd, remaining_timeout)
  │
  │     while recvfrom():
  │       match response ID → query slot
  │       verify source addr ∈ servers                     ← security check
  │       if SERVFAIL → retry (up to limit)
  │       if NOERROR or NXDOMAIN → store answer
  │
  ├─ parseResponse(answer[0], buf) → extract A records
  ├─ parseResponse(answer[1], buf) → extract AAAA records
  │
  └─ return count
```

### DNS wire format (internal)

All wire format helpers are private functions inside `Resolver.zig`:

- `buildQuery(buf: *[512]u8, name, qtype, id) []u8` — RFC 1035 §4.1
  question section. Domain name → label encoding. Returns used slice.
- `parseResponse(response: []u8, port, out: []Addr) !usize` — parse
  answer section, handle label compression (§4.1.4), extract A/AAAA
  resource records into caller's buffer.

### Usage

```zig
const embed = @import("embed").Make(platform);
const net = @import("net").Make(embed);
const Addr = embed.net.Address;

// Default resolver (Google + Cloudflare, A+AAAA parallel)
var r = net.Resolver.init(allocator, .{});

var addrs: [16]Addr = undefined;
const n = try r.lookupHost("example.com", &addrs);

var addr = addrs[0];
addr.setPort(443);
var conn = try net.dial(allocator, addr);
defer conn.deinit();

// Custom: IPv4-only, single server, short timeout
var r2 = net.Resolver.init(allocator, .{
    .servers = &.{ Addr.initIp4(.{ 10, 0, 0, 1 }, 53) },
    .timeout_ms = 2000,
    .mode = .ipv4_only,
});
```

### Convenience: `net.dialHost`

Top-level helper that resolves + dials in one call:

```zig
pub fn dialHost(allocator: Allocator, host: []const u8, port: u16) !Conn {
    var r = Resolver.init(allocator, .{});
    var addrs: [8]Addr = undefined;
    const n = try r.lookupHost(host, &addrs);
    if (n == 0) return error.NameNotFound;
    var addr = addrs[0];
    addr.setPort(port);
    return dial(allocator, addr);
}
```

## net/tls

TLS 1.2/1.3 client (Go's `crypto/tls`). Wraps any Conn into an
encrypted Conn — the output type also satisfies the Conn contract,
so protocol layers compose transparently.

```zig
var tcp = try net.dial(.{ .host = ip, .port = 443 });
var tls = try net.tls.Stream.init(&tcp, allocator, "example.com", .{});
try tls.handshake();
defer tls.close();

// tls satisfies Conn — pass to http, ws, etc.
_ = try tls.write("GET / HTTP/1.0\r\n\r\n");
```

## net/http

HTTP/1.1 client and server (Go's `net/http`).

**Client** — uses a RoundTripper abstraction (like Go's `http.Transport`):

```zig
var transport = net.http.Transport.init(allocator, .{});
var client = net.http.Client.init(&transport);

var buf: [8192]u8 = undefined;
const resp = try client.get("https://example.com/api", &buf);
```

**Server** — per-connection handler with path-based routing:

```zig
const routes = [_]net.http.Route{
    net.http.router.get("/health", handleHealth),
    net.http.router.post("/api/data", handleData),
};
var server = net.http.Server.init(allocator, &routes);

var ln = try net.listen(.{ .port = 8080 });
while (true) {
    var conn = try ln.accept();
    _ = try lib.Thread.spawn(.{}, server.serveConn, .{conn});
}
```

**RoundTripper** contract (for custom/mock transports):

```zig
fn roundTrip(*Self, RoundTripRequest, []u8) !RoundTripResponse
```

## net/ws

WebSocket client (Go's `golang.org/x/net/websocket` / `nhooyr.io/websocket`).
Works over any Conn — plain TCP or TLS.

```zig
var ws = try net.ws.Client.init(allocator, &tls_conn, .{
    .host = "echo.websocket.org",
    .path = "/",
});
defer ws.deinit();

try ws.sendText("hello");
while (try ws.recv()) |msg| {
    // msg.type (.text, .binary, .ping, .pong)
    // msg.payload
}
```

## Usage examples

### TCP echo server

```zig
const embed = @import("embed").Make(platform);
const net = @import("net").Make(embed);

var ln = try net.listen(.{ .port = 9000 });
defer ln.close();

while (true) {
    var conn = try ln.accept();
    _ = try embed.Thread.spawn(.{}, struct {
        fn handle(c: *net.Conn) void {
            defer c.close();
            var buf: [1024]u8 = undefined;
            while (true) {
                const n = c.read(&buf) catch break;
                if (n == 0) break;
                _ = c.write(buf[0..n]) catch break;
            }
        }
    }.handle, .{&conn});
}
```

### HTTPS GET

```zig
const embed = @import("embed").Make(platform);
const net = @import("net").Make(embed);

var transport = net.http.Transport.init(allocator, .{});
var client = net.http.Client.init(&transport);

var buf: [16384]u8 = undefined;
const resp = try client.get("https://httpbin.org/get", &buf);
embed.log.info("status={} body={s}", .{ resp.status_code, resp.body() });
```
