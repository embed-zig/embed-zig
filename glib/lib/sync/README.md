# lib/sync

`lib/sync` provides thread-coordination primitives that sit above the injected
runtime layer.

Today it has a few main pieces:

- `Channel(lib, factory)` for typed channels with close semantics
- `Pool.make(lib, T)` for thread-safe object reuse
- `Racer(lib, T)` for "first result wins" task coordination
- `Timer.make(lib)` for resettable deadline callbacks
- `WakeFd.make(lib)` for fd-backed wake/interrupt signaling

## Quick start

```zig
const sync = @import("sync");

const Channel = sync.Channel(lib, platform.ChannelFactory);
const IntChan = Channel(u32);
const BytesPool = sync.Pool.make(lib, [256]u8);
const U32Racer = sync.Racer(lib, u32);
const TimerImpl = sync.Timer.make(lib);
const WakeFdImpl = sync.WakeFd.make(lib);
```

`Channel` is parameterized by a platform channel factory, which is first bound to
the sealed `lib` namespace and then exposed as a typed channel constructor.
`Pool.make(lib, T)`, `Racer(lib, T)`, and `Timer.make(lib)` are built from the sealed `lib`
namespace so they can use the runtime's allocator, thread, timing, and shared
data-structure primitives. `Timer.make(lib)` uses that runtime to run a
background worker that waits for absolute millisecond deadlines.
`WakeFd.make(lib)` builds a tiny fd-backed wake primitive suitable for
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

For a std-backed host implementation, use `@import("glib_stdrt").sync.Channel`,
`@import("glib").sync.Pool.make(std, T)`, `@import("glib_stdrt").sync.Racer(...)`,
and `@import("glib").sync.Timer.make(std)`.
