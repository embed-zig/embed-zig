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
  Dialer.zig           Configurable network dialer (Go's net.Dialer)
  url.zig              Zero-alloc URL parser (RFC 3986)
  Resolver.zig         Pure-Zig DNS resolver (RFC 1035, per-server racer)
  tls/
    Conn.zig           TLS client Conn wrapper
    ServerConn.zig     TLS server Conn wrapper
    Dialer.zig         TLS dial helper
    Listener.zig       TLS listener wrapper
    client_handshake.zig TLS client handshake state machine
    server_handshake.zig TLS server handshake state machine
    record.zig         TLS record layer
    common.zig         TLS protocol constants and wire structs
    alert.zig          TLS alert encoding/decoding
    extensions.zig     TLS extension parsing/building
    kdf.zig            TLS 1.2/1.3 key schedule helpers
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
read/write/close/deinit plus timeout setters can be wrapped into a Conn.

```zig
pub const VTable = struct {
    read:  *const fn (*anyopaque, []u8) ReadError!usize,
    write: *const fn (*anyopaque, []const u8) WriteError!usize,
    close: *const fn (*anyopaque) void,
    deinit: *const fn (*anyopaque) void,
    setReadTimeout: *const fn (*anyopaque, ms: ?u32) void,
    setWriteTimeout: *const fn (*anyopaque, ms: ?u32) void,
};
```

Concrete implementations: **TcpConn** (TCP socket fd), **UdpConn** (connected UDP), **tls.Conn** (TLS client), **tls.ServerConn** (TLS server).

### Listener

Type-erased stream listener (Go's `net.Listener`). Returns Conn on accept.

```zig
pub const VTable = struct {
    accept: *const fn (*anyopaque) AcceptError!Conn,
    close:  *const fn (*anyopaque) void,
    deinit: *const fn (*anyopaque) void,
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
type_id: *const anyopaque,

pub const VTable = struct {
    readFrom: *const fn (ptr: *anyopaque, buf: []u8) ReadFromError!ReadFromResult,
    writeTo: *const fn (ptr: *anyopaque, buf: []const u8, addr: [*]const u8, addr_len: u32) WriteToError!usize,
    close: *const fn (ptr: *anyopaque) void,
    deinit: *const fn (ptr: *anyopaque) void,
};

pub const AddrStorage = [128]u8;

pub const ReadFromResult = struct {
    bytes_read: usize,
    addr: AddrStorage,
    addr_len: u32,
};

pub const ReadFromError = error{ ConnectionRefused, TimedOut, Unexpected };
pub const WriteToError = error{ MessageTooLong, NetworkUnreachable, AccessDenied, TimedOut, Unexpected };

pub fn as(self: PacketConn, comptime T: type) error{TypeMismatch}!*T { ... }
pub fn readFrom(self: PacketConn, buf: []u8) ReadFromError!ReadFromResult { ... }
pub fn writeTo(self: PacketConn, buf: []const u8, addr: [*]const u8, addr_len: u32) WriteToError!usize { ... }
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
    const Allocator = lib.mem.Allocator;

    return struct {
        /// Connected UDP -> Conn (read/write after connect).
        pub fn init(allocator: Allocator, fd: posix.socket_t) Allocator.Error!Conn { ... }

        /// Unconnected UDP -> PacketConn (readFrom/writeTo).
        pub fn initPacket(allocator: Allocator, fd: posix.socket_t) Allocator.Error!PacketConn { ... }
    };
}
```

### Dial / Listen

TCP convenience functions (already implemented):

```zig
// Connect to a remote address (TCP):
var conn = try net.dial(allocator, .tcp, Addr.initIp4(.{127,0,0,1}, 80));
defer conn.deinit();

// Listen for TCP connections:
var ln = try net.listen(allocator, .{ .address = Addr.initIp4(.{0,0,0,0}, 8080) });
defer ln.deinit();
```

### ListenPacket

Bind a UDP socket and return a `PacketConn` (Go's `net.ListenPacket`):

```zig
// Listen for UDP datagrams on port 5353:
var pc = try net.listenPacket(.{
    .allocator = allocator,
    .address = Addr.initIp4(.{ 0, 0, 0, 0 }, 5353),
});
defer pc.deinit();

// Receive a datagram:
var buf: [512]u8 = undefined;
const result = try pc.readFrom(&buf);
const data = buf[0..result.bytes_read];

// Send a response back to the sender:
_ = try pc.writeTo("reply", @ptrCast(&result.addr), result.addr_len);
```

Also exposed as `net.listenPacket` in `Make`:

```zig
pub fn listenPacket(opts: ListenPacketOptions) !PacketConn {
    // socket(AF, DGRAM) + bind
}

pub const ListenPacketOptions = struct {
    allocator: Allocator,
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

### Design decisions

| Aspect                  | Zig std (`getAddressList`)            | embed `net.Resolver`                        |
|-------------------------|---------------------------------------|---------------------------------------------|
| Server config           | Parse `/etc/resolv.conf` (Linux only) | Explicit `[]const Server` with per-server protocol  |
| Concurrency             | Single-threaded poll loop             | One detached task per server via `sync.Racer` |
| Result storage          | Heap `ArrayList(LookupAddr)`          | Caller-provided `[]Address` buffer          |
| Timeout / retry         | From resolv.conf (`timeout`, `attempts`) | Explicit in `Options`                    |
| Platform                | Linux-specific, musl port             | Platform-agnostic via `lib.posix`           |
| Protocol                | UDP only (no TCP fallback)            | Per-server `Protocol`: udp, tcp (tls, doh planned) |

### Resolver struct

```zig
pub fn Resolver(comptime lib: type) type {
    return struct {
        allocator: Allocator,
        options: Options,

        pub const Protocol = enum(u3) {
            udp = 0,
            tcp = 1,
            tls = 2,   // planned
            doh = 3,   // planned
        };

        pub const Server = struct {
            addr: Addr,
            protocol: Protocol = .udp,

            pub fn init(comptime ip: []const u8, protocol: Protocol) Server;
        };

        pub const dns = struct {
            pub const ali = struct { v4_1, v4_2, v6_1, v6_2: []const u8 };
            pub const google = struct { ... };
            pub const cloudflare = struct { ... };
            pub const quad9 = struct { ... };
        };

        pub const Options = struct {
            servers: []const Server = &.{
                Server.init(dns.ali.v4_1, .udp),
                Server.init(dns.cloudflare.v4_1, .udp),
                Server.init(dns.ali.v4_2, .udp),
                Server.init(dns.cloudflare.v4_2, .udp),
            },
            timeout_ms: u32 = 1000,
            attempts: u32 = 2,
            mode: QueryMode = .ipv4_only,
            spawn_config: Thread.SpawnConfig = .{},
        };

        pub const QueryMode = enum {
            ipv4_only,
            ipv6_only,
            ipv4_and_ipv6,
        };

        pub fn init(allocator: Allocator, options: Options) Allocator.Error!Self;
        pub fn deinit(self: *Self) void;
        pub fn wait(self: *Self) void;
        pub fn lookupHost(self: *Self, name: []const u8, buf: []Addr) LookupError!usize;
    };
}
```

### Per-server race strategy

```
lookupHost("example.com")
  │
  ├─ Build query packets (A and/or AAAA)
  │
  ├─ Spawn one Racer task per configured server
  │     Server0/udp   Server1/tcp   Server2/udp   ...
  │
  ├─ Each task:
  │     if done flag set → exit
  │     result = switch (server.protocol) {
  │         .udp → udpResolve(server)
  │         .tcp → tcpResolve(server)
  │     }
  │     if addresses found → publish through sync.Racer
  │     if NXDOMAIN / REFUSED → record as fallback error
  │
  ├─ Main thread waits on Racer.race()
  │
  └─ Return first successful result, otherwise the recorded
      DNS error or Timeout if everything was transient
```

Key properties:
- **True parallelism**: UDP and TCP queries run on separate threads simultaneously
- **First successful answer wins**: negative DNS replies do not short-circuit later successes
- **Per-server sockets**: each task opens its own fd, no shared fd coordination
- **Detached cleanup**: `lookupHost()` can return before lagging workers time out
- **SO_RCVTIMEO**: blocking recv with kernel timeout, no poll loop needed

### DNS wire format (internal)

- `buildQuery(buf, name, qtype, id) !usize` — RFC 1035 §4.1 question section
- `parseResponse(pkt, qtype, out) !usize` — parse answer section, extract A/AAAA records
- TCP framing: 2-byte big-endian length prefix per RFC 1035 §4.2.2

### Usage

```zig
const embed = @import("embed").Make(platform);
const net = @import("net").Make(embed);
const Addr = embed.net.Address;

const R = net.Resolver;

// Default resolver (AliDNS + Cloudflare, IPv4-only)
var r = try R.init(allocator, .{});
defer r.deinit();
var addrs: [16]Addr = undefined;
const n = try r.lookupHost("example.com", &addrs);

// UDP + TCP racing with custom servers
var r2 = try R.init(allocator, .{
    .servers = &.{
        R.Server.init(R.dns.ali.v4_1, .udp),
        R.Server.init(R.dns.ali.v4_2, .tcp),
    },
    .timeout_ms = 3000,
    .mode = .ipv4_only,
});
defer r2.deinit();
```

## net/tls

TLS 1.2/1.3 client/server building blocks and concrete wrappers in the
style of Go's `crypto/tls`. The client and server wrappers both return a
type-erased `net.Conn`, and the concrete TLS state can be recovered with
`conn.as(net.tls.Conn)` or `conn.as(net.tls.ServerConn)`.

Supported subset today:

- TLS 1.3 client/server with `X25519` key exchange and the cipher suites `TLS_AES_128_GCM_SHA256`, `TLS_AES_256_GCM_SHA384`, and `TLS_CHACHA20_POLY1305_SHA256`
- Deterministic TLS 1.3 suite selection via `Config.tls13_cipher_suites` and `ServerConfig.tls13_cipher_suites`
- Orderly shutdown with `close_notify`
- Existing TLS 1.2 interoperability path for the currently implemented ECDHE + AES-GCM flow

Core correctness is validated by local deterministic tests. Public-network
smoke coverage lives in `lib/net/test_runner/tls.zig` as a separate optional
runner so `zig test` does not depend on the public internet.

```zig
var tls_conn = try net.tls.dial(allocator, .tcp, ip, .{
    .server_name = "example.com",
    .tls13_cipher_suites = &.{ net.tls.CipherSuite.TLS_AES_256_GCM_SHA384 },
});
defer tls_conn.deinit();

const typed = try tls_conn.as(net.tls.Conn);
try typed.handshake();

// tls_conn still satisfies net.Conn
_ = try tls_conn.write("GET / HTTP/1.0\r\n\r\n");
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
const Addr = embed.net.Address;

var ln = try net.listen(embed.testing.allocator, .{
    .address = Addr.initIp4(.{ 0, 0, 0, 0 }, 9000),
});
defer ln.deinit();

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
