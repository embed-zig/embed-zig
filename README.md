# embed-zig

![CI](https://github.com/embed-zig/embed-zig/actions/workflows/ci.yml/badge.svg?branch=main)

`embed-zig` is a collection of portable Zig libraries for embedded and host
targets. Its runtime layer provides injectable platform backends so the same
code can run in tests, on desktop targets, and on embedded systems.

## Modules

- `glib`: portable library implementations and runtime contracts
- `gstd`: std-backed host compatibility layer
- `embed`: embedded implementation namespace
- `thirdparty/*`: explicitly exported third-party modules such as `lvgl`,
  `mbedtls`, `opus`, and platform packages

## Requirements

- [Zig](https://ziglang.org/) `0.15.2`

## Use As A Dependency

```zig
const dep = b.dependency("embed_zig", .{
    .target = target,
    .optimize = optimize,
});

const glib = dep.module("glib");
const gstd = dep.module("gstd");
const embed = dep.module("embed");
const core_bluetooth = dep.module("core_bluetooth");
const core_wlan = dep.module("core_wlan");
const lvgl = dep.module("lvgl");
const lvgl_osal = dep.module("lvgl_osal");
const mbedtls = dep.module("mbedtls");
const opus = dep.module("opus");
const portaudio = dep.module("portaudio");
const speexdsp = dep.module("speexdsp");
const stb_truetype = dep.module("stb_truetype");
```

The package name is `embed_zig`. The top-level package exposes core modules
`glib`, `gstd`, and `embed`, plus thirdparty modules exported directly from the
`thirdparty` package dependency: `core_bluetooth`, `core_wlan`, `lvgl`,
`lvgl_osal`, `mbedtls`, `opus`, `portaudio`, `speexdsp`, and `stb_truetype`.
The `embed` namespace contains `bt`, `drivers`, `motion`, `audio`, `ledstrip`,
and `zux`.

## Task Runtime

`glib.task` is the portable execution-unit contract used by runtime and
application code. It is designed as a goroutine-like API:

```zig
const handle = try grt.task.go(
    "audio/processor",
    .{ .min_stack_size = 24 * 1024 },
    glib.task.Routine.init(&state, processLoop),
);
handle.join();
```

Business code names the work it wants to run and does not choose FreeRTOS
task fields, pthread details, CPU affinity, priority, allocators, or PSRAM
policy directly. The task name is routed to a platform or board-owned handler,
and that handler owns the concrete resource policy.

`Options.min_stack_size` is the task call site's lower-bound stack requirement,
not a board policy decision or registry field. Each `task.go` call should pass
the smallest known stack requirement for that task. Board handlers forward or
satisfy it while choosing platform resources such as core, priority, allocator,
or memory capabilities, and may group multiple task names under one prefix
policy.

This gives the project two important boundaries:

- resource allocation is centralized in platform or board policy
- business logic stays separate from BSP-specific task setup

See [`docs/task-runtime.md`](docs/task-runtime.md) for the current task name
registry and board-owned policies.

## Build And Test

```sh
zig build
zig build test
```

## Package Docs

- [`glib/README.md`](glib/README.md)
- [`gstd/README.md`](gstd/README.md)
- [`embed/lib/bt/README.md`](embed/lib/bt/README.md)
- [`embed/lib/drivers/README.md`](embed/lib/drivers/README.md)
- [`embed/lib/zux/README.md`](embed/lib/zux/README.md)
- [`thirdparty/pkg/core_bluetooth/README.md`](thirdparty/pkg/core_bluetooth/README.md)
- [`thirdparty/pkg/core_wlan/README.md`](thirdparty/pkg/core_wlan/README.md)
- [`thirdparty/pkg/lvgl/README.md`](thirdparty/pkg/lvgl/README.md)
- [`thirdparty/pkg/mbedtls/README.md`](thirdparty/pkg/mbedtls/README.md)
- [`thirdparty/pkg/opus/README.md`](thirdparty/pkg/opus/README.md)
- [`thirdparty/pkg/portaudio/README.md`](thirdparty/pkg/portaudio/README.md)
- [`thirdparty/pkg/speexdsp/README.md`](thirdparty/pkg/speexdsp/README.md)
- [`thirdparty/pkg/stb_truetype/README.md`](thirdparty/pkg/stb_truetype/README.md)

## Contributing

Read [`docs/CODE_OF_CONDUCT.md`](docs/CODE_OF_CONDUCT.md) and [`AGENTS.md`](AGENTS.md)
before editing the repository.
