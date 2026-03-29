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
- `opus.Packet` plus free helpers such as `packetGetSamples(...)`,
  `packetGetChannels(...)`, `packetGetBandwidth(...)`, and `packetGetFrames(...)`
- common enums and error types from `src/types.zig`

`pkg/opus` builds libopus in fixed-point mode by default, but keeps the float
wrapper entry points enabled. That means `Encoder.encodeFloat(...)` and
`Decoder.decodeFloat(...)` are part of the default package surface unless you
override the config header and explicitly define `DISABLE_FLOAT_API`.

This package currently targets the single-stream Opus encoder/decoder API:

- channels: `1` or `2`
- sample rates: `8_000`, `12_000`, `16_000`, `24_000`, or `48_000`

If you provide a custom `opus_config_header` that disables the float API, the
integer wrappers remain supported but float methods such as
`Encoder.encodeFloat(...)`, `Decoder.decodeFloat(...)`, and `Decoder.plcFloat(...)`
must not be used.

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
