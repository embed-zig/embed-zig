# pkg/ogg

`pkg/ogg` wraps `libogg` with a small Zig-facing API for page, packet, stream,
and sync-state handling.

## Quick start

```zig
const ogg = @import("ogg");

var sync = ogg.Sync.init();
defer sync.deinit();

var stream = try ogg.Stream.init(1234);
defer stream.deinit();

const buf = try sync.buffer(4);
buf[0] = 0;
try sync.wrote(1);
```

The root package exports:

- `ogg.Sync`
- `ogg.Stream`
- `ogg.Page`
- raw binding-facing state types such as `SyncState`, `StreamState`, and
  `Packet`

## API notes

- `ogg.Stream.init()` returns `Stream.InitError` when `libogg` cannot allocate
  or initialize stream state.
- `ogg.Sync.init()` follows libogg's documented contract: `ogg_sync_init()`
  always returns `0`, and the wrapper traps if that invariant is violated.
- `ogg.Sync.buffer()` and `ogg.Sync.wrote()` return `BufferError` and
  `WroteError`; requests larger than `c_long` are rejected with
  `error.SizeTooLarge` before crossing into C.
- `ogg.Stream.pageIn()` and `ogg.Stream.packetIn()` return
  `Stream.PageInError` and `Stream.PacketInError`, so callers can catch
  `error.PageInFailed` and `error.PacketInFailed` explicitly.
- `ogg.Stream.packetPeek()` mirrors `packetOut()` without consuming the packet;
  a subsequent `packetOut()` still returns that same packet.
- `ogg.Stream.pageOut()` and `ogg.Stream.flush()` return `true` when a page was
  produced and written into the supplied `ogg.Page`.
- `ogg.Sync` and `ogg.Stream` wrap mutable `libogg` state. Treat each instance
  as single-threaded unless you provide external synchronization.

## Configuration

`pkg/ogg` ships its default build configuration in `pkg/ogg/config.default.h`.
That default keeps CRC verification enabled.

When building this repo directly through the repository root `build.zig`,
enable the package and override the entire header via:

```text
-Dogg=true -Dogg_config_header=path/to/ogg_config.h
```

In `b.dependency(...)`, the package is already selected by name; just pass the
same file via
`.ogg_config_header = b.path("...")`.

`build/pkg/ogg.zig` always forwards the selected full header to upstream as
`config.h`, so configuration remains package-scoped instead of turning Ogg
macros into top-level Zig dependency options.

## Package layout

```text
pkg/ogg/
  src/binding.c
  src/binding.zig
  src/types.zig
  src/Page.zig
  src/Sync.zig
  src/Stream.zig
  test_runner/unit.zig
  test_runner/unit/ogg.zig
  test_runner/integration.zig
  test_runner/integration/common.zig
  test_runner/integration/roundtrip.zig
  test_runner/integration/compat.zig
```

`binding.c` and `binding.zig` provide the C interop layer. The higher-level Zig
wrappers such as `Sync` and `Stream` sit on top of that binding layer.

## Tests

`pkg/ogg` includes:

- source-file `TestRunner(comptime lib: type)` entrypoints covering the binding and wrapper modules
- `test_runner/unit.zig` aggregating package unit coverage
- `test_runner/integration.zig` aggregating package integration coverage
- `test_runner/integration/roundtrip.zig` validating the C-backed package on its own
- `test_runner/integration/compat.zig` comparing the C-backed package against `lib/audio/ogg`
- `integration_tests/embed` running through `embed_std.std`
- `integration_tests/std` running the same integration runner through `std`
