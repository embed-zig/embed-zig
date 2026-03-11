# embed-zig

English | [中文](./README.md)

`embed-zig` is a Zig infrastructure stack for device applications. It uses `comptime` to organize `hal` and `runtime` adaptation layers, hide differences across hardware targets and host environments, and provide reusable cross-platform capabilities on top.

## TOC

- [Project Positioning](#project-positioning)
- [Project Goals](#project-goals)
- [Development Loop](#development-loop)
- [Core Capabilities](#core-capabilities)
- [Directory Structure](#directory-structure)
- [Build And Test](#build-and-test)
- [Dependency Integration](#dependency-integration)

## Project Positioning

`embed-zig` is not a single-platform SDK. Its core is a `comptime`-driven abstraction and composition model:

- `hal`: hardware abstractions for GPIO, I2C, SPI, UART, Wi-Fi, display, audio, and other device capabilities
- `runtime`: runtime abstractions for threads, time, IO, networking, file systems, random sources, and other host capabilities
- `pkg`: cross-platform feature modules built on top of `hal` / `runtime`
- `websim`: web-based simulation for development, automated testing, and remote mocking

Target platforms include ESP, BK, and host environments.

## Project Goals

This project aims to help developers:

1. focus on the application itself rather than platform differences
2. use one code path across firmware development, simulation testing, and multi-platform adaptation
3. enable fast development and fast testing in Agentic Coding workflows

## Development Loop

The intended workflow is:

1. develop firmware or application logic
2. validate and test in `websim`
3. adapt automatically to multiple hardware platforms
4. produce releases

## Core Capabilities

Current cross-platform capabilities include:

- event bus
- app stage management
- flux / reducer
- UI rendering engine
- audio processing
- BLE, networking, async execution, and other reusable components

The goal is to maximize reuse in upper-layer application code while pushing platform-specific differences down into the `comptime` adaptation layer.

## Directory Structure

```text
src/
  mod.zig             # top-level export, module name is embed
  runtime/            # runtime abstractions and standard implementations
  hal/                # HAL abstractions
  pkg/                # event, audio, BLE, networking, UI, app, and other higher-level modules
  websim/             # web simulation, test execution, and remote HAL
  third_party/        # third-party libraries, fonts, and related assets
cmd/
  audio_engine/       # host-side audio example
  bleterm/            # host-side BLE terminal tool
test/
  firmware/           # platform-agnostic firmware/app test assets
  websim/             # test cases built on websim
  esp/                # ESP platform build and adaptation examples
assets/
  embed-zig-icon-omgflux.jpg
```

## Build And Test

Requirements:

- Zig `0.15.0` or newer

Common commands from the repository root:

```bash
zig build test
zig build test-audio
zig build test-ble
zig build test-ui
zig build test-event
```

If you only want to validate a single file, you can also run:

```bash
zig test src/mod.zig
zig test src/runtime/std.zig
```

Run host-side example apps from their own directories:

```bash
zig build run
```

## Dependency Integration

`embed-zig` exports the module name `embed` by default, but the integration pattern depends on the target platform and build system.

- Host environments can usually integrate it as a normal Zig dependency
- Platforms such as `esp-zig` may require different module imports, linking rules, and build configuration
- Upper-layer application code should depend on the shared `hal` / `runtime` interfaces instead of hardcoding platform implementations

A typical host-side pattern looks like this:

```zig
const embed_dep = b.dependency("embed_zig", .{});
const embed_mod = embed_dep.module("embed");
```

If you need extra capabilities such as `portaudio`, `speexdsp`, `opus`, `ogg`, or `stb_truetype`, configure the corresponding dependencies and link settings per target platform.
