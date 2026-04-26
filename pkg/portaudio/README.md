# portaudio — PortAudio bindings for Zig

[![CI](https://github.com/embed-zig/portaudio/actions/workflows/ci.yml/badge.svg)](https://github.com/embed-zig/portaudio/actions/workflows/ci.yml)

Vendored [PortAudio](https://www.portaudio.com/) (pinned commit), with Zig
wrappers under `src/`. Supports **macOS (CoreAudio)** and **Linux (ALSA)**.
Linux builds require ALSA development headers such as Debian/Ubuntu's
`libasound2-dev`.

This module lives under `embed-zig/pkg` and is exported by the top-level
`embed_zig` package as `portaudio`.

## Layout

```bash
zig build
zig build test

Live host I/O (optional):
zig build test -Dportaudio_live=true
```

On Debian/Ubuntu, install ALSA headers first:

```bash
sudo apt-get install libasound2-dev
```

## `build.zig` (consumer)

```zig
const embed_dep = b.dependency("embed_zig", .{ .target = target, .optimize = optimize });
const pa_mod = embed_dep.module("portaudio");
app_mod.addImport("portaudio", pa_mod);
```

The `embed_zig` package build wires `embed`, the static `libportaudio`, and
platform frameworks / `asound` on the module returned above.

## Tests

- Default `zig build test`: compiles and runs **unit** tests; integration tests
  in `PortAudio.zig` and root are gated on `-Dportaudio_live`.
- With `-Dportaudio_live=true`: runs host smoke tests that initialize PortAudio
  and query devices (requires working audio stack).

See the repository `AGENTS.md` for package layout rules.
