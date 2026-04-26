# embed-zig

![CI](https://github.com/embed-zig/embed-zig/actions/workflows/ci.yml/badge.svg?branch=main)

`embed-zig` is a collection of portable Zig libraries for embedded and host
targets. Its core runtime layer, [`lib/embed`](lib/embed/README.md), aims to
provide a `std`-shaped API with injectable platform backends so the same code
can run in tests, on desktop targets, and on embedded systems.

## Modules

- `embed`: platform-facing runtime surface
- `context`: cancellation, deadlines, and request-scoped state
- `sync`: channels, racing, and concurrency helpers
- `io`: generic IO helpers
- `net`: networking, resolver, TLS, HTTP, and socket layers
- `mime`: MIME parsing and formatting
- `bt`: Bluetooth host stack
- `ledstrip`: LED frame, transition, and animator helpers
- `zux`: snapshot-driven state runtime

## Requirements

- [Zig](https://ziglang.org/) `0.15.2`

## Use As A Dependency

```zig
const dep = b.dependency("embed_zig", .{
    .target = target,
    .optimize = optimize,
});

const glib = dep.module("glib");
const glib_stdrt = dep.module("glib_stdrt");
const bt = dep.module("bt");
```

The package name is `embed_zig`. Modules are exposed directly by name; examples
include `glib`, `glib_stdrt`, `bt`, `drivers`, `motion`, `audio`, `ledstrip`,
and `zux`.

## Build And Test

```sh
zig build
zig build test
```

## Package Docs

- [`glib/README.md`](glib/README.md)
- [`glib_stdrt/README.md`](glib_stdrt/README.md)
- [`internal/lib/bt/README.md`](internal/lib/bt/README.md)
- [`internal/lib/drivers/README.md`](internal/lib/drivers/README.md)
- [`internal/lib/zux/README.md`](internal/lib/zux/README.md)

## Contributing

Read [`docs/CODE_OF_CONDUCT.md`](docs/CODE_OF_CONDUCT.md) and [`AGENTS.md`](AGENTS.md)
before editing the repository.
