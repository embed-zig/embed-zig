# lib/net/http

Go-style HTTP building blocks plus an early high-level `Client` for `lib/net`.

Today this package is centered on the client-side request/response model and
the default transport. A first `Client` layer is landed; `Server` is not.

## Public Surface

`lib/net/http` currently exposes:

- `Header`
- `ReadCloser`
- `Request`
- `Response`
- `status`
- `Client`
- `RoundTripper`
- `Transport`

Import via the `net` package:

```zig
const embed = @import("embed").make(platform);
const net = @import("net").make(embed);
```

## Client

`Client` is the first high-level facade above `RoundTripper` / `Transport`.

Current behavior:

- owned default `Transport` or borrowed custom `RoundTripper`
- `do(req: *Request) !Response`
- `get(url)` and `head(url)` convenience helpers
- bounded redirect following with a default limit of `10`
- 301/302/303 rewrite-to-GET behavior
- 307/308 preserve-method behavior only when the body is replayable
- response-scoped request cleanup for helper-built and redirect-hop requests
- in-flight request tracking so `deinit()` waits for returned responses to be
  released via `Response.deinit()`
- new work started after `deinit()` begins fails with `error.Closed`

Current scope boundary:

- `Client` is intentionally still early.
- Cookie jars, auth-policy helpers, total client timeout, `post`, and extra
  client-level retries remain deferred follow-up layers.
- There is intentionally no package-global `DefaultTransport` or
  `DefaultClient`; callers should explicitly own and share the instance they
  want to reuse.
- `Client.deinit()` blocks until every live `Response` from that client has been
  released with `Response.deinit()`.
- Treat `deinit()` as exclusive teardown: once shutdown begins, do not race more
  `Client` method calls against it from other threads.

### Example

```zig
const embed = @import("embed").make(platform);
const net = @import("net").make(embed);

var client = try net.http.Client.init(embed.testing.allocator, .{});
defer client.deinit();

var resp = try client.get("https://example.com/");
defer resp.deinit();

const body = resp.body() orelse return error.MissingBody;
var buf: [1024]u8 = undefined;
const n = try body.read(&buf);
embed.log.info("status={} body={s}", .{ resp.status_code, buf[0..n] });
```

## Transport

`Transport` is the default concrete `http.RoundTripper`, in the role of Go's
`http.Transport`.

Current behavior:

- direct HTTP/1.1 over TCP
- direct HTTPS over TLS
- HTTPS over HTTP CONNECT proxy
- request head serialization
- fixed-length and chunked request body streaming
- fixed-length, chunked, and EOF-delimited response body streaming
- request replay via `Request.GetBody`
- request-context-driven cancellation for blocked dial/read/write paths
- TLS handshake timeout and response-header timeout controls
- response-side TLS metadata at `Response.tls`
- idle connection pooling, reuse, idle limits, and per-host connection caps
- opt-in ALPN-based alternate transport selection via `force_attempt_http2`
- custom alternate transport hooks via `alternate_protocols`

Important scope boundary:

- `Transport` is intentionally low-level.
- Redirects, cookies, auth policy, retries, and other high-level client policy
  should live in `Client`, not in `Transport`, unless Go's
  `http.Transport` already owns that behavior.
- One intentional internal `Transport` caller remains `net.Resolver`'s DoH path:
  it uses a short-lived transport directly for a resolver-internal one-shot DNS
  exchange, without `Client` redirect/policy layering.

### Example

```zig
const embed = @import("embed").make(platform);
const net = @import("net").make(embed);

var transport = try net.http.Transport.init(embed.testing.allocator, .{});
defer transport.deinit();

var req = try net.http.Request.init(
    embed.testing.allocator,
    "GET",
    "https://example.com/",
);
var resp = try transport.roundTrip(&req);
defer resp.deinit();

const body = resp.body() orelse return error.MissingBody;
var buf: [1024]u8 = undefined;
const n = try body.read(&buf);
embed.log.info("status={} body={s}", .{ resp.status_code, buf[0..n] });
```

### Key Options

Common `Transport.Options` knobs:

- `tls_client_config`
- `tls_handshake_timeout_ms`
- `response_header_timeout_ms`
- `expect_continue_timeout_ms`
- `disable_keep_alives`
- `max_conns_per_host`
- `max_idle_conns`
- `max_idle_conns_per_host`
- `idle_conn_timeout_ms`
- `https_proxy`
- `force_attempt_http2`
- `alternate_protocols`
- `max_header_bytes`
- `max_body_bytes`

Notes:

- `max_header_bytes` currently defaults to `32 KiB`. This is an intentional
  embed-side policy, tighter than Go's larger effective zero-value default.
- request framing headers remain transport-owned: conflicting caller-supplied
  `Content-Length` / `Transfer-Encoding` values are rejected instead of being
  serialized alongside a different body framing strategy.
- The idle pool is shared across direct HTTP, direct HTTPS, and
  CONNECT-tunneled HTTPS.
- `https_proxy` is currently a narrow static proxy setting for `https://`
  requests only.
- `alternate_protocols` currently selects another `RoundTripper` after ALPN;
  it does not transfer ownership of the already-negotiated TLS connection.

## Not Supported Yet

These are the main remaining HTTP gaps today.

### Request / Response Semantics

- transparent gzip support: transport-managed `Accept-Encoding: gzip` plus
  streaming decompression
- outbound request trailer serialization
- Go-style `101 Switching Protocols` upgraded-body ownership
- public user-issued `CONNECT`; CONNECT is still transport-internal for proxied
  `https://`

### Response / Type Gaps

- `Response` trailers
- `Response` uncompressed markers / metadata for transparent gzip parity
- writable upgraded response bodies
- richer `Request` helper / legacy cancel surface needed for full Go parity

### Proxy Scope

- general HTTP proxy forwarding for plain `http://` requests
- SOCKS proxy support
- environment-driven proxy helpers such as `ProxyFromEnvironment`
- proxy-response hooks and richer proxy-auth policy beyond static CONNECT
  headers plus URL-userinfo Basic auth

### Go-Surface / API Gaps

- `Client.post(...)`
- client-managed cookie jar integration
- client-managed auth policy helpers
- client-managed total timeout policy
- client-managed retries beyond the current transport replay
- `Clone()`
- `CancelRequest()`
- exact Go-style `RegisterProtocol()` / `TLSNextProto` public surface
- `DialContext`, `Dial`, `DialTLSContext`, `DialTLS`
- `DisableCompression`
- `GetProxyConnectHeader`
- `WriteBufferSize`, `ReadBufferSize`
- `Protocols`, `HTTP2`

### Protocol Evolution

- a built-in HTTP/2 transport behind the current
  `force_attempt_http2` / `alternate_protocols` handoff model

## Next Planned Type

The next major package-level structure should be `Server`.

### Planned `Server`

`Server` should be the package's listener/serve-loop side and own request
parsing plus response writing.

Likely responsibilities:

- serve HTTP over `net.Listener` / `net.Conn`
- parse inbound requests into `Request`
- provide a response-writer surface for headers, status, and body streaming
- own connection lifecycle, keep-alive, and timeout policy for the server side
- expose a handler interface, with routing living either in `Server` or in a
  small adjacent layer built on top
- make it possible to share request/response/header types across client and
  server code

## Current Position

If you want the package's current stable story:

- use `Client` for the current high-level client path
- use `Transport` for low-level client-side round trips
- use this README for package-level scope and open gaps
- use `review/lib_net.md` for the compressed review/worklog summary
