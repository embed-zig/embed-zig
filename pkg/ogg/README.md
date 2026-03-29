# pkg/ogg

`pkg/ogg` wraps `libogg` with a small Zig-facing API for page, packet, stream,
and sync-state handling.

## Quick start

```zig
const ogg = @import("ogg");

var sync = ogg.Sync.init();
defer sync.deinit();
```

The root package exports:

- `ogg.Sync`
- `ogg.Stream`
- `ogg.Page`
- raw binding-facing state types such as `SyncState`, `StreamState`, and
  `Packet`

## Package layout

```text
pkg/ogg/
  src/binding.c
  src/binding.zig
  src/types.zig
  src/Page.zig
  src/Sync.zig
  src/Stream.zig
  test_runner/ogg.zig
```

`binding.c` and `binding.zig` provide the C interop layer. The higher-level Zig
wrappers such as `Sync` and `Stream` sit on top of that binding layer.

## Tests

`pkg/ogg` includes:

- unit tests for the binding and wrapper modules
- `integration_tests/embed` running through `embed_std.std`
- `integration_tests/std` running the same test runner through `std`
