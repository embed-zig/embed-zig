# embed-zig

Before starting any development work, read the repository-wide conduct rules in [`docs/CODE_OF_CONDUCT.md`](docs/CODE_OF_CONDUCT.md).

## Read Before Editing

- Read [`lib/embed/README.md`](lib/embed/README.md) before editing runtime contracts, `embed.make(...)`, or std-alignment rules.
- Read [`lib/context/README.md`](lib/context/README.md) before editing context trees, cancellation / timeout semantics, or context tests.
- Read [`lib/sync/README.md`](lib/sync/README.md) before editing `Channel`, `Racer`, concurrency semantics, or sync tests.
- Read [`lib/io/README.md`](lib/io/README.md) before adding or reshaping generic IO helpers, or deciding whether an interface belongs in `io`.
- Read [`lib/net/README.md`](lib/net/README.md) before editing the networking root module, resolver, TLS, HTTP, NTP, fd, stack, or related test runners.
- Read [`lib/net/fd/README.md`](lib/net/fd/README.md) before editing the internal fd substrate, non-blocking socket semantics, or fd-specific net test runners.
- Read [`lib/net/http/README.md`](lib/net/http/README.md) before editing `lib/net/http`, the HTTP transport surface, or future HTTP client/server planning docs.
- Read [`lib/mime/README.md`](lib/mime/README.md) before editing MIME parsing / formatting or HTTP-related content-type handling.
- Read [`lib/bt/README.md`](lib/bt/README.md) before editing the Bluetooth host stack, client/server, mocker, xfer, or bt tests.
- Read [`lib/embed_std/README.md`](lib/embed_std/README.md) before editing the std-backed compatibility layer.
- Read [`lib/zux/README.md`](lib/zux/README.md) before editing the `zux` module.

## Package Docs

- Read [`lib/audio/ogg/AGENTS.md`](lib/audio/ogg/AGENTS.md) before editing the pure Zig Ogg implementation or its tests.
