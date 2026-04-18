# lib/net/fd

Internal non-blocking socket-I/O substrate for `lib/net`.

`lib/net/fd` is not part of the public `net.make(lib)` surface. Public callers
still go through `Dialer`, `TcpConn`, `TcpListener`, `UdpConn`, `Conn`,
`Listener`, and `PacketConn`. This directory exists to give those public
wrappers a shared host-side fd layer with consistent connect, read, write, and
deadline semantics.

## Current Status

### Completed

- The fd migration is landed. `Dialer`, `TcpConn`, and `UdpConn` now treat
  `lib/net/fd` as the active host-side foundation rather than as a parallel
  rewrite.
- The host-side `embed.posix` contract already exposes the primitives the fd
  layer depends on: `fcntl`, `F.GETFL`, `F.SETFL`, `O.NONBLOCK`, `poll`,
  `getsockopt`, and `SO.ERROR`.
- The core internal files are in place:
  - `lib/net/fd.zig`
  - `lib/net/fd/Stream.zig`
  - `lib/net/fd/Packet.zig`
  - `lib/net/fd/Listener.zig`
  - `lib/net/fd/SockAddr.zig`
- Direct fd runner coverage is in place through:
  - `lib/net/test_runner/integration/fd_stream.zig`
  - `lib/net/test_runner/integration/fd_packet.zig`
- Non-blocking connect, `connectContext(...)`, deadline storage, timeout
  accounting, and non-blocking read/write wait loops are implemented.
- Each netfd now owns a wake-fd pair used for close signaling. Context-aware
  waits reuse that same wake fd through `context.bindFd(...)` in the common
  case instead of creating a temporary context node.
- Public `net` integration coverage was added after migration so the higher
  wrappers continue to match fd-layer error and timeout semantics.

### Not Completed

- Context-aware packet read/write is still not implemented beyond the current
  deadline-driven packet I/O model.
- Optional internal refactors such as `Poller.zig`, `Deadline.zig`, and
  `errors.zig` are still future work, not required pieces of the current fd
  design.
- Broader TLS, alert-policy, and other higher-layer API design questions are
  not solved in `lib/net/fd`; they belong to the wrapper and protocol layers
  above fd.

## Role In `lib/net`

`lib/net/fd` is the low-level foundation for:

- `DialContext` with real in-flight cancellation and deadline handling
- deadline-aware stream and packet I/O
- transport layers such as `tls` and `http` that need consistent socket
  semantics across connect, read, and write

The intended semantic direction is closer to Go's `netFD` /
`internal/poll.FD` than to blocking `recv` / `send` wrappers, but implemented
with explicit synchronous polling plus per-netfd wake sockets rather than with a
global runtime poller.

## Current Preconditions

The fd layer assumes that the host-side `embed.posix` contract exposes:

- `fcntl`
- `F.GETFL`
- `F.SETFL`
- `O.NONBLOCK`
- `poll`
- `getsockopt`
- `SO.ERROR`

These contract surfaces are covered by
`lib/embed/test_runner/std/posix.zig`.

## Scope Rules

- Treat `lib/net/fd` as an internal package. Keep it unexported through
  `lib/net.zig`.
- Evolve the public wrappers to match fd semantics rather than forcing fd to
  mimic older blocking wrappers.
- Centralize raw `fcntl` / `poll` / `getsockopt` details inside the fd layer
  instead of scattering them across wrapper code.
- Do not use thread-per-connect cancellation. In-flight cancellation should be
  driven by non-blocking connect plus polling.
- Do not rely on socket-level read/write timeout options inside fd for host
  paths. The fd layer owns its wait loops and deadline behavior directly.
- Keep allocator use explicit, and keep host / lwIP portability in mind through
  the existing `embed.posix` abstraction boundary.

## Design

### High-Level Shape

The main internal entry points are:

- `lib/net/fd.zig`
- `lib/net/fd/Stream.zig`
- `lib/net/fd/Packet.zig`
- `lib/net/fd/Listener.zig`
- `lib/net/fd/Wake.zig`
- `lib/net/fd/SockAddr.zig`

The current implementation keeps stream, packet, and listener logic small and
direct. Optional helper files such as `Poller.zig`, `Deadline.zig`, and
`errors.zig` remain future cleanups rather than hard architectural
requirements.

### Stream Semantics

`Stream` owns a socket fd and provides the base stream operations used by the
public wrappers:

- `initSocket(...)`
- `adopt(...)`
- `deinit()`
- `close()`
- `shutdown(how)`
- `connect(addr)`
- `connectContext(ctx, addr)`
- `read(buf)`
- `write(buf)`
- `setReadDeadline(deadline_ms)`
- `setWriteDeadline(deadline_ms)`
- `setDeadline(deadline_ms)`

Timeout convenience wrappers can still be added later if they are useful, but
the internal representation prefers absolute deadlines.

### Non-Blocking Policy

Sockets in the fd layer are internally non-blocking.

Typical operation shape:

1. Attempt the syscall.
2. If it succeeds, return.
3. If it returns `WouldBlock` or an in-progress result, compute the remaining
   wait budget.
4. Poll for readability or writability.
5. Retry the syscall.

Listener sockets follow the same model: the listen fd stays non-blocking, and
`accept()` waits via `poll` when a direct non-blocking accept returns
`WouldBlock`.

For `connectContext(...)`, writability alone is not enough. When `connect()`
goes in progress, completion must be verified with
`getsockopt(..., SO.ERROR, ...)`.

### Cancellation And Deadlines

`Context` support currently exists for:

- `connectContext(ctx, addr)`, which returns `error.Canceled` when the context
  is canceled
- `connectContext(ctx, addr)`, which returns `error.DeadlineExceeded` when the
  context deadline expires
- `Stream.readContext(...)` and `Stream.writeContext(...)`, so higher layers
  such as `TcpConn`, `tls`, and `http` can surface request cancellation while
  blocked in I/O

For those context-aware waits, each netfd already owns a close-wake fd. fd
temporarily binds the caller's `Context` to that same wake fd through
`ctx.bindFd(...)` and polls both the target fd and the netfd wake fd. When the
context is canceled, that wake fd becomes readable and the blocked `poll(...)`
returns immediately. The older short-timeout context poll loop is kept only as a
fallback path when the context is already bound to some other wake fd.

At the public `net.Conn` boundary, stream-side context cancellation and
deadline expiry are still collapsed into `error.TimedOut`, because
`lib/net/Conn.zig` intentionally keeps a small shared error surface. Higher
layers such as `http.Transport` preserve `Canceled` / `DeadlineExceeded`
semantics by interpreting that timeout in request-context-aware code paths.
That public fold is now covered in `lib/net/test_runner/integration/tcp.zig`.

Packet I/O remains primarily deadline-driven today. Context-aware packet
read/write should only be added when a concrete caller needs it and the
semantics are clear.

## Testing

Use two layers of coverage:

- `lib/net/test_runner/integration/fd_*` for direct fd semantics
- `lib/net/test_runner/integration/*` for public `net` API integration after migration

Do not skip the fd-local layer. Behavior such as non-blocking connect,
`SO.ERROR` verification, and deadline wait loops should remain testable without
going through `Dialer`, `Conn`, or higher protocols.

The fd layer should continue to keep the following areas covered:

- loopback connect success
- already-canceled and already-expired `connectContext(...)`
- in-flight `connectContext(...)` cancel and deadline behavior
- non-blocking read/write wait loops
- blocked read / accept wakeup on close
- read and write deadline behavior
- operation-after-close behavior
- idempotent `close()`
- packet-oriented datagram boundaries
- bidirectional streaming without deadlock

## Maintenance Direction

Further work here should be treated as incremental tightening of the active fd
substrate plus its wrapper, test, and documentation surface.

Current priority order:

1. Keep fd-local behavior covered by `fd_stream` / `fd_packet`.
2. Keep `Dialer`, `TcpConn`, `TcpListener`, and `UdpConn` aligned with fd-layer
   error and timeout semantics.
3. Tighten higher-layer regressions (`tls`, `http`) whenever fd behavior shifts.
4. Update this README and `lib/net/README.md` whenever fd behavior or scope
   changes materially.
