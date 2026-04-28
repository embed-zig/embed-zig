# thirdparty/pkg/speexdsp

[![CI](https://github.com/embed-zig/speexdsp/actions/workflows/ci.yml/badge.svg)](https://github.com/embed-zig/speexdsp/actions/workflows/ci.yml)

`thirdparty/pkg/speexdsp` wraps the upstream [SpeexDSP](https://github.com/xiph/speexdsp)
C library, providing typed Zig wrappers for echo cancellation, preprocessing,
and resampling.

## Quick start

```zig
const speexdsp = @import("speexdsp");

var echo = try speexdsp.EchoState.init(160, 1600);
defer echo.deinit();

var preprocess = try speexdsp.PreprocessState.init(160, 16_000);
defer preprocess.deinit();
try preprocess.setEchoState(&echo);

var resampler = try speexdsp.Resampler.init(1, 16_000, 8_000, speexdsp.resampler_quality_default);
defer resampler.deinit();
```

The root package exports:

- `speexdsp.EchoState` — acoustic echo cancellation
- `speexdsp.PreprocessState` — noise suppression / AGC / VAD
- `speexdsp.Resampler` — sample-rate conversion
- Shared types: `Sample`, `SampleRate`, `ChannelCount`, `Quality`, `ProcessResult`

## Build integration

This module is exported by the top-level `embed_zig` package. Upstream
SpeexDSP C sources are fetched at build time over HTTPS from GitHub `codeload`
via the shared `buildtools` dependency declared in the repository
`build.zig.zon`.

```sh
zig build test
```

## Package layout

```text
speexdsp.zig                         # root module
build.zig                            # build script
build.zig.zon                        # dependency manifest
config.default.h
include/speex/speexdsp_config_types.h
src/binding.c
src/binding.zig
src/types.zig
src/error.zig
src/EchoState.zig
src/PreprocessState.zig
src/Resampler.zig
test_runner/unit.zig
test_runner/integration.zig
test_matrix/
  run.sh                           # config matrix runner
  *.h                              # fixed/float x smallft/kiss variants
```

## Tests

`thirdparty/pkg/speexdsp` includes:

- unit runners for binding, type, and wrapper modules
- `unit_tests/embed_std` and `unit_tests/std`
- `integration_tests/embed_std` and `integration_tests/std`
- config matrix tests (`test_matrix/run.sh`) for fixed/float and
  smallft/kiss FFT backend combinations
