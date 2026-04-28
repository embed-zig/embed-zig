# opus

[![CI](https://github.com/embed-zig/opus/actions/workflows/ci.yml/badge.svg)](https://github.com/embed-zig/opus/actions/workflows/ci.yml)

Zig wrapper for `libopus` — encoding, decoding, and packet inspection.

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

This package builds libopus in fixed-point mode by default, but keeps the float
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

## Configuration

The default build configuration is in `config.default.h`.

Downstream can override the entire header through the `thirdparty` dependency's
`opus_config_header` build option:

```zig
const dep = b.dependency("thirdparty", .{
    .target = target,
    .optimize = optimize,
    .opus_config_header = b.path("my_opus_config.h"),
});
```

`build.zig` forwards the selected header to upstream as `config.h`, so the
public build API stays package-scoped instead of exposing individual `libopus`
macros as top-level Zig options.

## Package layout

```text
opus.zig              — root module
src/
  binding.c
  binding.zig
  types.zig
  error.zig
  Packet.zig
  Encoder.zig
  Decoder.zig
test_runner/
  unit.zig
  integration.zig
  integration/
    version.zig
    i16_48k_1ch_5s.zig
    i16_48k_2ch_2s.zig
    i16_24k_1ch_1s.zig
    i16_16k_1ch_2s.zig
    f32_48k_1ch_2s.zig
    f32_48k_2ch_2s.zig
    test_utils/
      scenario.zig
config.default.h
build.zig
build.zig.zon
```

## Tests

Unit coverage is exported from the wrapper modules through file-level
`TestRunner` functions. Integration tests run per-scenario runners through two
host backends:

- `integration_tests/embed_std` via `embed_std.std`
- `integration_tests/std` via `std`

```sh
zig build test
```
