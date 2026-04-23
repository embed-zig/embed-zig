# lib/embed_std

`lib/embed_std` is the std-backed host adapter layer for `embed-zig`.

Its public surface is intentionally small: `embed_std.std`, `embed_std.sync`,
and `embed_std.net`.

## Exports

```zig
const embed_std = @import("embed_std");

const lib = embed_std.std;
const sync = embed_std.sync;
const host_net = embed_std.net;
```

- `embed_std.std` is the canonical host `stdz` namespace backed by Zig `std`
- `embed_std.sync` provides std-backed sync helpers built on `embed_std.std`
- `embed_std.net` is the std-backed `net.make2(...)` namespace for host
  networking; platform dispatch lives under `embed_std/net.zig`

Use `embed_std.std` when code wants the sealed `stdz` namespace shape without
importing `std` directly. This is the normal host-side runtime for compatibility
coverage and for tests that want `stdz` semantics on top of Zig's standard
library.

Use `embed_std.net` when code wants the pre-instantiated `net.make2(...)`
namespace and its host-backed `Runtime` socket objects.

## Sync support

`embed_std` also provides std-backed sync adapters:

```zig
const embed_std = @import("embed_std");

const Channel = embed_std.sync.Channel;
const U32Racer = embed_std.sync.Racer(u32);
```

- `embed_std.sync.Channel(T)` is a concrete channel type backed by
`embed_std.std.Thread`
- `embed_std.sync.Racer(T)` is `sync.Racer(embed_std.std, T)`

## Testing role

`lib/embed_std` is the home for compatibility coverage.

- `compat_tests/stdz` exercise code through `embed_std.std`
- `compat_tests/std` exercise the same runners directly through `std`

That split keeps the project honest about two things at once:

- `stdz` remains aligned with `std` where it intentionally mirrors `std`
- `embed_std` stays a faithful adapter layer instead of growing its own behavior

## Thread notes

`embed_std.std.Thread` maps onto the host `std.Thread` surface as closely as the
`stdz` contract allows.

- `Thread.setName(...)` and `Thread.getName(...)` operate on the current thread
and use the same host facilities that `std.Thread` uses where supported
- on targets where `std.Thread` has no naming support, those calls return
`error.Unsupported`
- `stdz` caps thread-name buffers at 128 bytes, so `embed_std` also exposes at
most 128 bytes even on hosts where raw `std.Thread` allows longer names
- `SpawnConfig.stack_size` and `SpawnConfig.allocator` are forwarded to
`std.Thread.spawn(...)`
- `SpawnConfig.name`, `SpawnConfig.priority`, and `SpawnConfig.core_id` are
currently host hints only; `embed_std` does not apply them at spawn time
- `Thread.Condition.timedWait(...)` normalizes any underlying host wait failure
to `error.Timeout`, because the `stdz` contract only exposes that narrower
error surface today

