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

const embed = dep.module("embed");
```

The package name is `embed_zig`. Additional modules such as `context`,
`sync`, `net`, `ledstrip`, and `zux` are exposed by the same package.

## Build And Test

```sh
zig build
zig build test
```

## Package Docs

- [`lib/embed/README.md`](lib/embed/README.md)
- [`lib/context/README.md`](lib/context/README.md)
- [`lib/sync/README.md`](lib/sync/README.md)
- [`lib/io/README.md`](lib/io/README.md)
- [`lib/net/README.md`](lib/net/README.md)
- [`lib/bt/README.md`](lib/bt/README.md)
- [`lib/embed_std/README.md`](lib/embed_std/README.md)
- [`lib/zux/README.md`](lib/zux/README.md)

## Contributing

Read [`docs/CODE_OF_CONDUCT.md`](docs/CODE_OF_CONDUCT.md) and [`AGENTS.md`](AGENTS.md)
before editing the repository.
