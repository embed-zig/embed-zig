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
  - [Dial](#dial)
  - [Listen](#listen)
- [net/url](#neturl)
- [net/dns](#netdns)
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
  net.zig              Root; Make(lib) entry point, Conn, Listener, Dial, Listen
  url/
    url.zig            Zero-alloc URL parser (RFC 3986)
  dns/
    resolver.zig       DNS resolver (UDP/TCP/DoH)
    packet.zig         DNS wire format parser/builder
    cache.zig          TTL-aware DNS cache
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
├─────────────────────┤                            │
│   Conn contract     │       net/dns              │
├──────────┬──────────┤       net/url              │
│   Dial   │  Listen  │                            │
├──────────┴──────────┴───────────────────────────┤
│              lib (embed.Make)                    │
│   posix / Thread / time / net.Ip4Address        │
└─────────────────────────────────────────────────┘
```

## net (root)

The root package provides the core types and top-level functions,
mirroring Go's `net` package.

### Conn

The universal bidirectional byte stream contract (Go's `net.Conn`).
Any type with these methods satisfies Conn:

```zig
fn read(*Self, []u8) Conn.Error!usize
fn write(*Self, []const u8) Conn.Error!usize
fn close(*Self) void

pub const Error = error{ ReadFailed, WriteFailed, Closed, Timeout };
```

**SocketConn** adapts a raw posix socket fd into a Conn.
**tls.Stream** also satisfies Conn, enabling transparent layering.

### Listener

A stream-oriented network listener (Go's `net.Listener`):

```zig
fn accept(*Self) !Conn
fn close(*Self) void
fn addr(*Self) Ip4Address
```

### Dial

Connect to a remote address, returning a Conn (Go's `net.Dial`):

```zig
var conn = try net.dial(.{ .host = .{ 93, 184, 216, 34 }, .port = 80 });
defer conn.close();

pub const DialOptions = struct {
    host: [4]u8,
    port: u16,
    timeout_ms: u32 = 30000,
};
```

`dialHost` resolves a hostname via DNS before connecting:

```zig
var conn = try net.dialHost("example.com", 443, &resolver);
```

### Listen

Bind and listen on a local address, returning a Listener (Go's `net.Listen`):

```zig
var ln = try net.listen(.{ .port = 8080 });
defer ln.close();

while (true) {
    var conn = try ln.accept();
    // handle conn
}

pub const ListenOptions = struct {
    address: [4]u8 = .{ 0, 0, 0, 0 },
    port: u16,
    backlog: u31 = 128,
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

## net/dns

DNS resolver (Go's `net.Resolver`). Supports UDP, TCP, and
DNS-over-HTTPS (DoH, RFC 8484).

```zig
var resolver = net.dns.Resolver.init(allocator, .{
    .server = .{ 8, 8, 8, 8 },
    .protocol = .udp,
});
const ip = try resolver.resolve("example.com");
```

Sub-modules:
- `packet.zig` — DNS wire format parser/builder
- `cache.zig` — TTL-aware resolution cache

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
