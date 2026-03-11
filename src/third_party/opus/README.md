# opus — Zig bindings for libopus

Zig-first API wrapping [libopus](https://github.com/xiph/opus), the reference
implementation of the Opus audio codec (RFC 6716).

Built for MCU targets — defaults to `FIXED_POINT` arithmetic.

## Directory layout

```
third_party/opus/
├── build.zig      # Build logic: source fetch, header sync, module export
├── src.zig        # Zig API: Encoder, Decoder, enums, error mapping
├── vendor/opus/   # (git-ignored) cloned libopus source
└── c_include/     # (git-ignored) public headers copied from vendor
```

`vendor/` and `c_include/` are generated at build time and not committed.

## Usage

From within this directory:

```bash
# Run API tests (source is fetched automatically on first build)
zig build test

# Pin to a specific libopus commit
zig build test -Dopus_commit=<sha>

# Build with floating-point instead of fixed-point
zig build test -Dopus_fixed_point=false
```

From the repository root:

```bash
zig build opus-test
```

## Zig API

Import the module as `"opus"` in a dependent `build.zig`:

```zig
const opus = @import("opus");

var encoder = try opus.Encoder.init(allocator, 16000, 1, .voip);
defer encoder.deinit(allocator);

encoder.setBitrate(24000) catch {};
encoder.setComplexity(0) catch {};

const encoded = try encoder.encode(&pcm_frame, 320, &out_buf);
```

### Exported types

| Type          | Description                              |
|---------------|------------------------------------------|
| `Encoder`     | Opus encoder with ctl methods            |
| `Decoder`     | Opus decoder with PLC support            |
| `Application` | `.voip`, `.audio`, `.restricted_lowdelay` |
| `Signal`      | `.auto`, `.voice`, `.music`              |
| `Bandwidth`   | `.auto`, `.narrowband` … `.fullband`     |
| `Error`       | Mapped from `OPUS_BAD_ARG` etc.          |

### Utility functions

- `getVersionString()` — libopus version string
- `packetGetSamples(data, sample_rate)` — samples in a packet
- `packetGetChannels(data)` — channel count from packet header
- `packetGetBandwidth(data)` — bandwidth from packet header
- `packetGetFrames(data)` — frame count in a packet

## Build options

| Option              | Type     | Default | Description                        |
|---------------------|----------|---------|------------------------------------|
| `opus_fixed_point`  | `bool`   | `true`  | Use fixed-point arithmetic (MCU)   |
| `opus_commit`       | `string` | —       | Pin libopus to a specific commit   |
