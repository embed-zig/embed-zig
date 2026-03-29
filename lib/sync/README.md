# lib/sync

`lib/sync` provides thread-coordination primitives that sit above the injected
runtime layer.

Today it has two main pieces:

- `Channel(impl)` for typed channels with close semantics
- `Racer(lib, T)` for "first result wins" task coordination

## Quick start

```zig
const sync = @import("sync");

const Channel = sync.Channel(platform.Channel);
const IntChan = Channel(u32);
const U32Racer = sync.Racer(lib, u32);
```

`Channel` is parameterized by a concrete channel factory, while `Racer` is built
from the sealed `lib` namespace so it can use the runtime's allocator, thread,
and timing primitives.

## Package shape

```text
lib/sync/
  Channel.zig
  Racer.zig
  test_runner/
    channel.zig
    racer.zig
```

## Testing

`lib/sync` follows the shared runner layout:

- unit tests live next to `Channel.zig` and `Racer.zig`
- portable runners live under `sync/test_runner/`
- integration or compatibility entrypoints call those runners from the shared
  test trees

For a std-backed host implementation, use `@import("embed_std").sync.Channel`
and `@import("embed_std").sync.Racer(...)`.
