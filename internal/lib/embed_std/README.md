# lib/embed_std

`lib/embed_std` is the std-backed adapter layer for `embed-zig`.

It gives the repo one canonical host implementation of the `stdz` contracts and
one canonical std-shaped namespace built from that implementation.

## Exports

```zig
const embed_std = @import("embed_std");

const platform = embed_std.stdz;
const lib = embed_std.std;
```

- `embed_std.stdz` is the concrete contract implementation backed by `std`
- `embed_std.std` is `@import("stdz").make(embed_std.stdz)`

Use `embed_std.std` when code wants the sealed `stdz` namespace shape without
importing `std` directly. This is the normal host-side runtime for compatibility
coverage and for tests that want `stdz` semantics on top of Zig's standard
library.

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

`embed_std.stdz.Thread` maps onto the host `std.Thread` surface as closely as the
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
