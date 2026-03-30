# lib/net — Go-style networking for embed-zig

High-level networking package built on top of `embed`. Takes a comptime
`lib` (the result of `embed.make(platform)`) and provides Go-style
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
- [net/ntp](#netntp)
- [net/tls](#nettls)
- [net/http](#nethttp)
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
const embed = @import("embed").make(platform);
const net = @import("net").make(embed);
```

`lib/net` depends on the sealed `embed` namespace for:
- `lib.posix` — socket, bind, listen, accept, connect, send, recv, sendto, recvfrom, poll, fcntl, getsockopt, close
- `lib.Thread` — synchronization and worker threads used by TLS, resolver, and runners
- `lib.time` — deadlines and timeout accounting
- `net.netip` — `Addr` / `AddrPort` construction and parsing for public addresses

## Package structure

```zig
lib/
  net.zig              Root; make(lib) entry point, Conn, Listener, PacketConn, Dial, Listen
  net/
    Conn.zig           Type-erased byte stream interface (Go's net.Conn)
    Listener.zig       Type-erased stream listener interface (Go's net.Listener)
    PacketConn.zig     Type-erased datagram interface (Go's net.PacketConn)
    Dialer.zig         Configurable network dialer (Go's net.Dialer)
    TcpConn.zig        Conn over TCP socket fd (Go's net.TCPConn)
    UdpConn.zig        PacketConn + Conn over UDP socket fd (Go's net.UDPConn)
    TcpListener.zig    Listener for TCP (Go's net.TCPListener)
    fd.zig             Internal fd-layer namespace and fd-local test runners
    fd/
      Stream.zig       Internal non-blocking stream socket wrapper
      Packet.zig       Internal non-blocking datagram socket wrapper
      Listener.zig     Internal non-blocking listen/accept wrapper
      SockAddr.zig     AddrPort <-> sockaddr bridge
    netip/
      Addr.zig         IP address value type
      AddrPort.zig     IP address + port value type
    stack.zig          Network stack helpers
    url.zig            Zero-alloc URL parser (RFC 3986)
    Resolver.zig       Pure-Zig DNS resolver (RFC 1035, per-server racer)
    ntp.zig            UDP NTP client and wire helpers
    tls/
      Conn.zig         TLS client Conn wrapper
      ServerConn.zig   TLS server Conn wrapper
      Dialer.zig       TLS dial helper
      Listener.zig     TLS listener wrapper
      client_handshake.zig TLS client handshake state machine
      server_handshake.zig TLS server handshake state machine
      record.zig       TLS record layer
      common.zig       TLS protocol constants and wire structs
      alert.zig        TLS alert encoding/decoding
      extensions.zig   TLS extension parsing/building
      kdf.zig          TLS 1.2/1.3 key schedule helpers
    http/
      Header.zig       HTTP header entry
      ReadCloser.zig   HTTP body read+close contract
      RoundTripper.zig RoundTripper contract
      Request.zig      HTTP request builder/parser
      Response.zig     HTTP response parser
      Client.zig       High-level client facade above RoundTripper/Transport
      Transport.zig    Default HTTP/1.1 client transport
      status.zig       HTTP status codes and helpers
```

## Layer diagram

```
┌──────────────────────────────────────────────────────┐
│                      User code                       │
├────────────┬────────────┬────────────────────────────┤
│  net/http  │         (future)                       │
├────────────┴────────────────────────────────────────┤
│        net/tls          │                            │
│       (Conn -> Conn)    │                            │
├─────────────────────────┼────────────────────────────┤
│ Conn / Listener         │ PacketConn                 │
│ TcpConn / TcpListener   │ UdpConn                    │
│ Dialer / listen         │ listenPacket               │
├──────────────────────────────────────────────────────┤
│ internal fd layer (not exported through make(lib))  │
│ fd.Stream / fd.Packet / fd.Listener / fd.SockAddr   │
├──────────────────────────────────────────────────────┤
│ sibling helpers: netip / Resolver / url / stack     │
├──────────────────────────────────────────────────────┤
│ lib (embed.make)                                     │
│ posix / Thread / time                                │
└──────────────────────────────────────────────────────┘
```

Internally, stream and packet sockets now run through `lib/net/fd` as the
shared non-blocking substrate. Public callers still work with `Dialer`,
`TcpConn`, `TcpListener`, `UdpConn`, `Conn`, `Listener`, and `PacketConn`;
the fd layer remains an internal implementation detail.

Regression coverage is split between fd-local runners
(`lib/net/test_runner/fd_stream.zig`, `lib/net/test_runner/fd_packet.zig`)
and public API runners (`lib/net/test_runner/tcp.zig`,
`lib/net/test_runner/udp.zig`), all wired from `lib/integration.zig`.

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

pub const ReadError = error{ EndOfStream, ShortRead, ConnectionReset, ConnectionRefused, BrokenPipe, TimedOut, Unexpected };
pub const WriteError = error{ ConnectionRefused, ConnectionReset, BrokenPipe, TimedOut, Unexpected };
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
    setReadTimeout: *const fn (ptr: *anyopaque, ms: ?u32) void,
    setWriteTimeout: *const fn (ptr: *anyopaque, ms: ?u32) void,
};

pub const AddrStorage = [128]u8;

pub const ReadFromResult = struct {
    bytes_read: usize,
    addr: AddrStorage,
    addr_len: u32,
};

pub const ReadFromError = error{ ConnectionReset, Closed, ConnectionRefused, TimedOut, Unexpected };
pub const WriteToError = error{ Closed, MessageTooLong, NetworkUnreachable, AccessDenied, TimedOut, Unexpected };

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
var conn = try net.dial(allocator, .tcp, net.netip.AddrPort.from4(.{ 127, 0, 0, 1 }, 80));
defer conn.deinit();

// Listen for TCP connections:
var ln = try net.listen(allocator, .{ .address = net.netip.AddrPort.from4(.{ 0, 0, 0, 0 }, 8080) });
defer ln.deinit();
```

### ListenPacket

Bind a UDP socket and return a `PacketConn` (Go's `net.ListenPacket`):

```zig
// Listen for UDP datagrams on port 5353:
var pc = try net.listenPacket(.{
    .allocator = allocator,
    .address = net.netip.AddrPort.from4(.{ 0, 0, 0, 0 }, 5353),
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
    address: net.netip.AddrPort = net.netip.AddrPort.from4(.{ 0, 0, 0, 0 }, 0),
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
| Protocol                | UDP only (no TCP fallback)            | Per-server `Protocol`: udp, tcp, tls, doh |

Resolver-specific note:

- The internal DoH path intentionally uses a short-lived `http.Transport`
  directly, not `http.Client`. It is treated as a resolver-internal DNS wire
  exchange, with explicit timeout / no-keepalive / no-recursive-resolver
  behavior, rather than as a general high-level HTTP client call.

### Resolver struct

```zig
pub fn Resolver(comptime lib: type) type {
    return struct {
        allocator: Allocator,
        options: Options,

        pub const Protocol = enum(u3) {
            udp = 0,
            tcp = 1,
            tls = 2,
            doh = 3,
        };

        pub const Server = struct {
            addr: AddrPort,
            protocol: Protocol = .udp,
            tls_config: ?TlsConfig = null,
            doh_path: []const u8 = "",

            pub fn init(comptime ip: []const u8, protocol: Protocol) Server;
            pub fn initTls(comptime ip: []const u8, comptime server_name: []const u8) Server;
            pub fn initDoh(comptime ip: []const u8, comptime server_name: []const u8) Server;
            pub fn initDohPath(comptime ip: []const u8, comptime server_name: []const u8, comptime path: []const u8) Server;
        };

        pub const dns = struct {
            pub const ali = struct { v4_1, v4_2, v6_1, v6_2, server_name: []const u8 };
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
        pub fn lookupHost(self: *Self, name: []const u8, buf: []Addr) anyerror!usize;
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
  │     Server0/udp   Server1/tcp   Server2/tls   Server3/doh ...
  │
  ├─ Each task:
  │     if done flag set → exit
  │     result = switch (server.protocol) {
  │         .udp → udpResolve(server)
  │         .tcp → tcpResolve(server)
  │         .tls → tlsResolve(server)
  │         .doh → dohResolve(server)
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
- **True parallelism**: UDP, TCP, TLS, and DoH queries run on separate threads simultaneously
- **First successful answer wins**: negative DNS replies do not short-circuit later successes
- **Per-server sockets**: each task opens its own fd, no shared fd coordination
- **Detached cleanup**: `lookupHost()` can return before lagging workers time out
- **SO_RCVTIMEO**: blocking recv with kernel timeout, no poll loop needed

### DNS wire format (internal)

- `buildQuery(buf, name, qtype, id) !usize` — RFC 1035 §4.1 question section
- `parseResponse(pkt, qtype, out) !usize` — parse answer section, extract A/AAAA records
- TCP framing: 2-byte big-endian length prefix per RFC 1035 §4.2.2
- DNS-over-TLS reuses the same TCP framing inside a `net.tls.Conn`

### Usage

```zig
const embed = @import("embed").make(platform);
const net = @import("net").make(embed);
const Addr = net.netip.Addr;
const AddrPort = net.netip.AddrPort;

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

// DNS-over-TLS with built-in SNI defaults for well-known providers
var r3 = try R.init(allocator, .{
    .servers = &.{
        R.Server.init(R.dns.ali.v4_1, .tls),
        R.Server.init(R.dns.google.v4_1, .tls),
    },
    .timeout_ms = 5000,
});
defer r3.deinit();

// Custom DNS-over-TLS server
var r4 = try R.init(allocator, .{
    .servers = &.{.{
        .addr = AddrPort.from4(.{ 127, 0, 0, 1 }, 853),
        .protocol = .tls,
        .tls_config = .{
            .server_name = "example.com",
            .verification = .self_signed,
        },
    }},
});
defer r4.deinit();
```

## net/ntp

Small UDP-based NTP client plus RFC 5905 wire helpers.

Highlights:

- Pure timestamp conversion and packet encode/decode helpers at module root
- `Client(lib)` with single-server query and multi-server race support
- Per-server race workers built on `sync.Racer`
- Public-network Aliyun test coverage in `lib/net/test_runner/ntp.zig`

```zig
const embed = @import("embed").make(platform);
const net = @import("net").make(embed);

var client = try net.ntp.Client.init(embed.testing.allocator, .{
    .servers = &.{net.ntp.Servers.aliyun},
    .timeout_ms = 5000,
});
defer client.deinit();

const resp = try client.query(embed.time.milliTimestamp());
const current_time_ms = try client.getTime(embed.time.milliTimestamp());
_ = resp;
_ = current_time_ms;
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
- Post-handshake application reads and writes preserve the same typed transport I/O failures as cleartext `net.Conn` where available (`ConnectionRefused`, `ConnectionReset`, `BrokenPipe`, `TimedOut`)
- Handshake-stage peer alerts and malformed-record failures are kept more distinct than plain `RecordIoFailed`, but the handshake error surface still remains intentionally coarser than post-handshake application I/O
- Handshake-stage transport write failures now stop outbound flights without synthesizing an extra local fatal alert, while local protocol/record failures still emit the matching fatal alert

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

HTTP/1.1 client-side request/response model plus the default transport.
Today the package exposes:

- `Header`, `ReadCloser`, `Request`, `Response`
- `status` helpers
- `Client` as the current high-level client facade
- `RoundTripper` contract
- `Transport` as the default HTTP/1.1 client transport

The current `Client` layer supports `do`, `get`, `head`, owned-default vs
borrowed-transport setup, and bounded redirects. Server/router layers are not
landed yet.

There is intentionally no package-global `DefaultTransport` or `DefaultClient`.
Callers that want app-wide reuse should hold and share an explicit `Client` or
`Transport` instance at the application boundary.

For package-local transport behavior, unsupported items, and the planned
`Client` / `Server` structures, see `lib/net/http/README.md`.

**Default transport**:

```zig
var transport = try net.http.Transport.init(allocator, .{});
defer transport.deinit();

var req = try net.http.Request.init(allocator, "GET", "http://example.com/api");
var resp = try transport.roundTrip(&req);
defer resp.deinit();

const body = resp.body() orelse return error.MissingBody;
var buf: [1024]u8 = undefined;
const n = try body.read(&buf);
_ = n;
```

**Client**:

```zig
var client = try net.http.Client.init(allocator, .{});
defer client.deinit();

var resp = try client.get("http://example.com/api");
defer resp.deinit();

const body = resp.body() orelse return error.MissingBody;
var buf: [1024]u8 = undefined;
const n = try body.read(&buf);
_ = n;
```

**Custom transport** — implement `RoundTripper`:

```zig
const MyTransport = struct {
    fn roundTrip(self: *@This(), req: *const net.http.Request) !net.http.Response {
        _ = self;
        _ = req;
        return error.Todo;
    }
};

var impl = MyTransport{};
var round_tripper = net.http.RoundTripper.init(&impl);
```

**RoundTripper** contract (for custom/mock transports):

```zig
fn roundTrip(*Self, *const http.Request) !http.Response
```

## net/ws

Planned, but not landed in the current tree yet.

## Usage examples

### TCP echo server

```zig
const embed = @import("embed").make(platform);
const net = @import("net").make(embed);
const Addr = net.netip.AddrPort;

var ln = try net.listen(embed.testing.allocator, .{
    .address = Addr.from4(.{ 0, 0, 0, 0 }, 9000),
});
defer ln.deinit();

while (true) {
    var conn = try ln.accept();
    _ = try embed.Thread.spawn(.{}, struct {
        fn handle(c: *net.Conn) void {
            defer c.deinit();
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

### HTTP GET

```zig
const embed = @import("embed").make(platform);
const net = @import("net").make(embed);

var transport = try net.http.Transport.init(embed.testing.allocator, .{});
defer transport.deinit();

var req = try net.http.Request.init(embed.testing.allocator, "GET", "http://example.com/");
var body_buf: [1024]u8 = undefined;
var resp = try transport.roundTrip(&req);
defer resp.deinit();

const body = resp.body() orelse return error.MissingBody;
const n = try body.read(&body_buf);
embed.log.info("status={} body={s}", .{ resp.status_code, body_buf[0..n] });
```
