# pkg/opus

`pkg/opus` wraps `libopus` for encoding, decoding, and packet inspection.

## Quick start

```zig
const opus = @import("opus");

var enc = try opus.Encoder.init(allocator, 48_000, 1, .audio);
defer enc.deinit();
```

The root package exports:

- `opus.Encoder`
- `opus.Decoder`
- packet helpers such as `packetGetSamples(...)`, `packetGetChannels(...)`,
  `packetGetBandwidth(...)`, and `packetGetFrames(...)`
- common enums and error types from `src/types.zig`

## Package layout

```text
pkg/opus/
  src/binding.c
  src/binding.zig
  src/types.zig
  src/error.zig
  src/packet.zig
  src/Encoder.zig
  src/Decoder.zig
  test_runner/opus.zig
```

## Tests

`pkg/opus` keeps unit tests next to the wrapper modules and also runs the same
portable runner through two host backends:

- `integration_tests/embed` via `embed_std.std`
- `integration_tests/std` via `std`
