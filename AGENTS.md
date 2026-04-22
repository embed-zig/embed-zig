# embed-zig

Before starting any development work, read the repository-wide conduct rules in `[docs/CODE_OF_CONDUCT.md](docs/CODE_OF_CONDUCT.md)`.

## Package Layout

- The repository root is now a thin facade package.
- The top-level `build.zig` should only wire public exports and package dependencies.
- The top level exports exactly two public modules: `embed` and `embed_std`.
- The top-level `lib/embed.zig` is a facade namespace composed from the `internal` package modules.
- Do not reintroduce top-level implementation trees under `lib/` that mirror `internal/lib/`.
- Do not add top-level test build steps or top-level test entrypoints for this facade package; implementation tests belong in `internal/`.
- Put implementation code, module wiring, and tests in the `internal/` package unless the change is specifically about the top-level facade boundary.

## Read Before Editing

- Read `[internal/lib/stdz/README.md](internal/lib/stdz/README.md)` before editing runtime contracts, `embed.std`, or std-alignment rules.
- Read `[internal/lib/context/README.md](internal/lib/context/README.md)` before editing context trees, cancellation / timeout semantics, or context tests.
- Read `[internal/lib/sync/README.md](internal/lib/sync/README.md)` before editing `Channel`, `Racer`, concurrency semantics, or sync tests.
- Read `[internal/lib/io/README.md](internal/lib/io/README.md)` before adding or reshaping generic IO helpers, or deciding whether an interface belongs in `io`.
- Read `[internal/lib/net/README.md](internal/lib/net/README.md)` before editing the networking root module, resolver, TLS, HTTP, NTP, fd, stack, or related test runners.
- Read `[internal/lib/net/fd/README.md](internal/lib/net/fd/README.md)` before editing the internal fd substrate, non-blocking socket semantics, or fd-specific net test runners.
- Read `[internal/lib/net/http/README.md](internal/lib/net/http/README.md)` before editing `internal/lib/net/http`, the HTTP transport surface, or future HTTP client/server planning docs.
- Read `[internal/lib/mime/README.md](internal/lib/mime/README.md)` before editing MIME parsing / formatting or HTTP-related content-type handling.
- Read `[internal/lib/bt/README.md](internal/lib/bt/README.md)` before editing the Bluetooth host stack, client/server, mocker, xfer, or bt tests.
- Read `[internal/lib/embed_std/README.md](internal/lib/embed_std/README.md)` before editing the std-backed compatibility layer.
- Read `[internal/lib/zux/README.md](internal/lib/zux/README.md)` before editing the `zux` module.
- Read `[internal/lib/at/README.md](internal/lib/at/README.md)` before editing the AT session / transport stack or AT tests.
- Read `[internal/lib/drivers/README.md](internal/lib/drivers/README.md)` before editing generic drivers or device-specific driver modules.

