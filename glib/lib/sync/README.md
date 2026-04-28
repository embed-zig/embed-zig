# lib/sync

`lib/sync` provides thread-coordination primitives that sit above the injected
runtime layer.

Today it has a few main pieces:

- `Channel(std, factory)` for typed channels with close semantics
- `Pool.make(std, T)` for thread-safe object reuse
- `Racer(std, time, T)` for "first result wins" task coordination
- `Timer.make(std, time)` for resettable deadline callbacks
- `WakeFd.make(std)` for fd-backed wake/interrupt signaling

## Quick start

```zig
const sync = @import("sync");

const Channel = sync.Channel(std, platform.ChannelFactory);
const IntChan = Channel(u32);
const BytesPool = sync.Pool.make(std, [256]u8);
const U32Racer = sync.Racer(std, time, u32);
const TimerImpl = sync.Timer.make(std, time);
const WakeFdImpl = sync.WakeFd.make(std);
```

`Channel` is parameterized by a platform channel factory, which is first bound to
the sealed `std` namespace and then exposed as a typed channel constructor.
`Pool.make(std, T)` is built from the sealed `std`
namespace so they can use the runtime's allocator, thread, timing, and shared
data-structure primitives. `Racer(std, time, T)` and `Timer.make(std, time)`
receive the platform `std` shape and monotonic `time` source separately for
deadline checks. `Timer.make(std, time)` runs a background worker that waits for
absolute monotonic deadlines.
`WakeFd.make(std)` builds a tiny fd-backed wake primitive suitable for
interrupting blocking waits from another thread or cancellation path.

## Package shape

```text
lib/sync/
  Channel.zig
  Pool.zig
  Racer.zig
  Timer.zig
  WakeFd.zig
  test_runner/
    unit.zig
    integration.zig
    integration/
      channel.zig
      racer.zig
```

## Testing

`lib/sync` follows the shared runner layout:

- unit tests live next to `Channel.zig`, `Pool.zig`, `Racer.zig`, `Timer.zig`, and `WakeFd.zig`
- aggregate runners live under `sync/test_runner/`
- integration cases live under `sync/test_runner/integration/`
- integration or compatibility entrypoints call those runners from the shared
  test trees

For a std-backed host implementation, use
`@import("gstd").runtime.sync.ChannelFactory` with the `glib.sync` test runners
and helpers. `gstd` exposes the pre-instantiated runtime namespace instead of
re-exporting `sync` directly.
