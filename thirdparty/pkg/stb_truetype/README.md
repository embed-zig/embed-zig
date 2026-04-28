# stb_truetype

[![CI](https://github.com/embed-zig/stb-truetype/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/embed-zig/stb-truetype/actions/workflows/ci.yml)

`stb_truetype` wraps `stb_truetype.h` for font parsing and bitmap-related
font queries.

## Quick start

```zig
const stb = @import("stb_truetype");

const font = try stb.Font.init(bytes);
```

`stb.Font` borrows `bytes`; the caller must keep the font data alive and
unchanged for as long as the `Font` is used.

The root package exports:

- `stb.Font`
- `stb.FontInfo`
- metrics/value types such as `VMetrics`, `HMetrics`, and `BitmapBox`

## Notes

- `stb_truetype` does not provide security guarantees for malicious font data; use
  this package only with trusted font files.
- `stb.Font.glyphIndex(codepoint)` returns `0` when the font does not provide a
  glyph for that codepoint.
- `stb.BitmapBox.width()` and `height()` are signed deltas. Check that they are
  positive before casting them to `usize` for bitmap sizing.
- `stb.Font.renderCodepointBitmap(...)` validates the caller-provided bitmap
  layout and returns an error when the buffer is too small, the stride is
  invalid, or a dimension cannot be represented by `stb_truetype`. Zero-sized
  renders are treated as a no-op.

## Package layout

```text
stb_truetype.zig
include/stb_truetype.h
src/binding.c
src/binding.zig
src/types.zig
src/Font.zig
test_runner/unit.zig
test_runner/integration.zig
test_runner/unit/test_utils/font.ttf
```

`font.ttf` is a tiny checked-in test fixture used by the package test runner.

## Tests

`stb_truetype` includes:

- unit tests for the binding and wrapper modules
- `integration_tests/embed` via `embed_std.std`
- `integration_tests/std` via `std`
