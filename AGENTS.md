# embed-zig

## Core Rules

- `embed` directly exports a curated subset of `std` types and helpers that are intended to remain cross-platform.
- If code needs a more complete `std`-shaped environment, build it at comptime with `embed.make(...)` and use the resulting namespace.
- The long-term goal of `embed` is to be a drop-in replacement for the `std` package.
- Outside `lib/embed` and `lib/embed_std`, non-test library code should not import `std` directly. Runtime, concurrency, networking, time, allocator, and similar capabilities should come from the injected `lib` / `embed` namespace.
- Direct `std` imports are allowed in `test` blocks. Integration tests and compatibility tests should use `std`, and `embed_std` remains the std-backed adapter layer.
- `make` is a function. New type / namespace construction entry points should use lowercase `make`.

## Testing Rules

- Put `test_runner` under `<module>/test_runner/` or `<package>/test_runner/`.
- By default, `test_runner` should be portable: prefer forms such as `run(comptime lib: type, ...)` that can run against different injected `embed` implementations on different platforms.
- If a runner is explicitly host-only / std-only, say so in the name and only call it from `compat_tests` or from clearly host-only test entry points.
- Test names must preserve these tokens because the build system filters by them: `unit_tests`, `integration_tests`, `compat_tests`.

### Unit Tests

- `unit test` should live next to the implementation file, directly inside that file, and should not require network access or external dependencies.
- Root-file `test "<name>/unit_tests"` imports nearby unit tests.

### Integration Tests

- `integration test` should live under the shared `integration/` tree rather than being scattered under each module or package, should use `std`, should call one or more cases from `test_runner`, should be exposed through `test {}` or `test "..." {}` blocks, and is the right place for tests that use network access, depend on external systems, or take longer to run.
- Root-file `test "<name>/integration_tests"` imports integration tests from the shared `integration/` tree.

### Compat Tests

- `compat test` is compatibility coverage, should live in the `embed_std` module, and should usually avoid network access and long-running scenarios.
- Compatibility coverage has two parts: tests against `embed_std`, and tests against `std`.
- `embed_std` hosts `test "<name>/compat_tests/embed"` and `test "<name>/compat_tests/std"` compatibility coverage.

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

- Read [`pkg/core_bluetooth/README.md`](pkg/core_bluetooth/README.md) before editing the Apple BLE backend / CoreBluetooth package.
- Read [`pkg/lvgl/README.md`](pkg/lvgl/README.md) before editing LVGL bindings, OSAL wiring, display tests, or screenshot-comparison logic.
- Read [`pkg/ogg/README.md`](pkg/ogg/README.md) before editing Ogg bindings or package tests.
- Read [`pkg/opus/README.md`](pkg/opus/README.md) before editing Opus bindings or package tests.
- Read [`pkg/stb_truetype/README.md`](pkg/stb_truetype/README.md) before editing stb_truetype bindings, font tests, or package wiring.
