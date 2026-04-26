# embed-zig

Before starting any development work, read the repository-wide conduct rules in `[docs/CODE_OF_CONDUCT.md](docs/CODE_OF_CONDUCT.md)`.

## Package Layout

- The repository root is now a thin package-export layer.
- The top-level `build.zig` should only wire public exports and package dependencies.
- The top level exports the core public modules `glib`, `gstd`, and `embed`, plus explicit package-backed public modules from `pkg/` such as `core_bluetooth`, `core_wlan`, `lvgl`, `opus`, `portaudio`, `speexdsp`, and `stb_truetype`.
- The `embed` module is a namespace composed from the implementation modules under `embed/lib/`.
- Do not reintroduce additional top-level public modules such as `bt`, `drivers`, or `embed_std`.
- Do not reintroduce top-level implementation trees under `lib/` that mirror `embed/lib/`.
- Top-level test build steps may only orchestrate exported package tests; implementation test entrypoints belong in `embed/` or the relevant `pkg/`.
- Put embed implementation code, module wiring, and tests in the `embed/` package unless the change is specifically about the top-level package boundary; put external package modules under `pkg/`.

## Read Before Editing

- Read `[glib/lib/stdz/README.md](glib/lib/stdz/README.md)` before editing runtime contracts, `glib.std`, or std-alignment rules.
- Read `[glib/lib/context/README.md](glib/lib/context/README.md)` before editing context trees, cancellation / timeout semantics, or context tests.
- Read `[glib/lib/sync/README.md](glib/lib/sync/README.md)` before editing `Channel`, `Racer`, concurrency semantics, or sync tests.
- Read `[glib/lib/io/README.md](glib/lib/io/README.md)` before adding or reshaping generic IO helpers, or deciding whether an interface belongs in `io`.
- Read `[glib/lib/net/README.md](glib/lib/net/README.md)` before editing the networking root module, resolver, TLS, HTTP, NTP, stack, or related test runners.
- Read `[glib/lib/net/http/README.md](glib/lib/net/http/README.md)` before editing `glib/lib/net/http`, the HTTP transport surface, or future HTTP client/server planning docs.
- Read `[glib/lib/mime/README.md](glib/lib/mime/README.md)` before editing MIME parsing / formatting or HTTP-related content-type handling.
- Read `[embed/lib/bt/README.md](embed/lib/bt/README.md)` before editing the Bluetooth host stack, client/server, mocker, xfer, or bt tests.
- Read `[gstd/README.md](gstd/README.md)` before editing the std-backed compatibility layer.
- Read `[embed/lib/zux/README.md](embed/lib/zux/README.md)` before editing the `zux` module.
- Read `[embed/lib/drivers/README.md](embed/lib/drivers/README.md)` before editing generic drivers or device-specific driver modules.

