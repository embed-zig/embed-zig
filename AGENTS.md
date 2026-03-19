# embed-zig

Cross-platform runtime library for Zig. Platform implementations inject
concrete types via `embed.Make(platform)`, producing a namespace that code
can program against without depending on `std` directly.

## Table of Contents

- [Relationship with std](#relationship-with-std)
- [Project structure](#project-structure)
- [Contracts and comptime verification](#contracts-and-comptime-verification)
- [Error sets and type re-exports](#error-sets-and-type-re-exports)
- [Testing](#testing)
- [CI](#ci)
- [example/fake\_platform](#examplefake_platform)
- [Adding a new platform](#adding-a-new-platform)

## Relationship with std

embed is a **strict superset** of a subset of std:

1. **Matching names must match behavior.** If embed exposes a symbol that
   also exists in std (e.g. `Thread`, `Thread.Mutex`, `log`, `posix`,
   `atomic.Value`, `mem.Allocator`), its API surface and semantics must be
   identical to std. Code written against embed must compile and behave
   correctly when `std` is substituted in.

2. **embed may extend std.** embed can provide types that have no std
   equivalent. `Channel` is the primary example today -- a typed,
   bounded, multi-producer/multi-consumer channel with Go-style close
   semantics. These extensions live alongside the std-compatible surface
   and do not conflict with it.

In short: `std` code is valid embed code, but not vice versa (because of
extensions like Channel).

## Project structure

```
lib/embed.zig              Root module; Make(Impl) entry point
lib/embed/                 Contracts (Thread, Channel, log, posix, ...)
lib/embed/test_runner/     Built-in test runners (see Testing below)
example/fake_platform/     Reference platform implementation
build.zig / build.zig.zon  Package definition
.github/workflows/ci.yml   CI workflow
```

## Contracts and comptime verification

Each contract (`Thread.zig`, `posix.zig`, `log.zig`, etc.) uses a
`make(comptime Impl: type) type` pattern. Inside `make`, a `comptime {}`
block verifies the Impl's function signatures via `@as` casts:

```zig
comptime {
    _ = @as(*const fn () YieldError!void, &Impl.yield);
    _ = @as(*const fn ([]const u8) SetNameError!void, &Impl.setName);
    // ...
}
```

If an Impl is missing a function or has a wrong signature, the build fails
immediately with a clear error. Constants like `Impl.max_name_len` are
also range-checked at comptime (must be 1..128 for Thread).

## Error sets and type re-exports

Where embed's error sets are identical to std's, the contract re-exports
them directly (e.g. `pub const SocketError = std.posix.SocketError;`).
This avoids duplication drift. Types that embed extends or customizes
(e.g. `SpawnConfig` with `priority`/`core_id` fields, or
`max_name_len` which is platform-dependent) remain hand-defined.

## Testing

Two built-in test runners live in `lib/embed/test_runner/`:

- **std_compat** (`std.zig`) -- Exercises Thread, Mutex, Condition, RwLock,
  log, posix (TCP/UDP/file/seek), net, time, atomic, and mem. Accepts any
  type with the same shape as std. The `test "compact_test"` block at the
  bottom passes `std` itself, proving embed is a proper subset.

- **channel** (`channel.zig`) -- 57 tests covering buffered/unbuffered
  channels: init, FIFO ordering, ring wrap, close semantics, blocking/wakeup,
  SPSC/MPSC/SPMC/MPMC concurrency, and resource safety.

Run tests via any example platform:

```
cd example/fake_platform && zig build test
```

## CI

GitHub Actions workflow (`.github/workflows/ci.yml`) runs on every push
and pull request:

- **build** job: `zig build` at the repo root (ubuntu + macos).
- **test** job: `zig build test` for each example in the `example/` matrix
  (ubuntu + macos x each example). To add a new example, append its
  directory name to the `example:` list in the matrix.

## example/fake_platform

A reference platform implementation that wires every embed contract to its
std equivalent. It serves two purposes:

1. **Example for implementors.** Shows exactly which types and functions a
   platform must provide (`Thread`, `Channel`, `log`, `posix`, `time`).

2. **Integration test harness.** `platform.zig` contains a `test` block
   that runs both `std_compat` and `channel` test runners against the
   fake platform, verifying the full embed surface end-to-end.

## Adding a new platform

1. Create `example/<name>/` with `build.zig`, `build.zig.zon`, and
   `platform.zig`.
2. Implement each contract (`Thread`, `Channel`, `log`, `posix`, `time`).
   Use `fake_platform/src/` as a reference.
3. Add a `test` block in `platform.zig` that calls the test runners.
4. Add `<name>` to the `example:` matrix in `.github/workflows/ci.yml`.
