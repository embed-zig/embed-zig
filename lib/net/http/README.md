# lib/net/http

Low-level Go-style HTTP building blocks for `lib/net`.

Today this package is centered on the client-side request/response model and
the default transport. It does not ship a full high-level `Client` or `Server`
yet.

## Public Surface

`lib/net/http` currently exposes:

- `Header`
- `ReadCloser`
- `Request`
- `Response`
- `status`
- `RoundTripper`
- `Transport`

Import via the `net` package:

```zig
const embed = @import("embed").make(platform);
const net = @import("net").make(embed);
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
  should live in a future `Client`, not in `Transport`, unless Go's
  `http.Transport` already owns that behavior.

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

These are the main HTTP transport gaps today.

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

## Next Planned Types

The next major package-level structures should be `Client` and `Server`.

### Planned `Client`

`Client` should sit above `RoundTripper` / `Transport` and own high-level
request policy.

Likely responsibilities:

- hold a default `RoundTripper` or `Transport`
- provide convenience entry points such as `get`, `post`, or a higher-level
  `do`
- manage redirect policy
- own cookie and auth policy surfaces that should not live in `Transport`
- centralize replay / retry policy that is higher-level than transport safety
- present a stable caller-facing surface while `Transport` stays low-level

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

- use `Transport` for low-level client-side round trips today
- use this README for package-level scope and open gaps
- use `review/lib_net.md` for the compressed review/worklog summary
