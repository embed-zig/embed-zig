# lib/embed

`lib/embed` is the platform-facing runtime layer for `embed-zig`.

Its long-term goal is to be a `std` drop-in replacement for the parts of Zig
that application and library code commonly program against, while still letting
the actual low-level implementation come from an injected platform backend.

## Goal

The intended usage model is:

```zig
const embed = @import("embed").Make(platform_impl);
```

Code written against `embed` should, as much as possible, also work against
`std` with minimal or zero source changes when the same symbols exist.

In other words:

- `embed` aims to look like `std`
- the backing implementation is not hard-coded to `std`
- platform code can provide its own `Thread`, `posix`, `log`, `time`, `crypto`,
  and other low-level pieces

## Current status

Today, `embed` is not yet a full `std` replacement.

It is currently best described as:

- a `std`-compatible subset
- plus compatible extensions where needed for platform support

For matching symbols, the target is behavioral compatibility with `std`.
If `embed` exposes `Thread`, `Thread.Mutex`, `log`, `posix`, `mem.Allocator`,
`crypto.Certificate`, or similar `std`-shaped APIs, code should be able to rely
on the same semantics.

At the same time, `embed` may expose extra fields or types that help with
portable runtime integration, as long as they do not break `std`-compatible
usage.

Example: `Thread.SpawnConfig` may carry platform-specific or runtime-specific
configuration beyond what `std.Thread.SpawnConfig` exposes. This is considered a
compatible extension, not a contradiction of the overall goal.

## What "drop-in replacement" means here

For this project, "drop-in replacement" does not mean that `embed` must already
mirror every public symbol in `std`.

It means:

1. When `embed` provides a `std`-shaped API, it should preserve `std`'s meaning.
2. `embed` should keep moving toward broader `std` surface coverage.
3. Missing pieces are acceptable for now.
4. Compatibility-preserving extensions are also acceptable.

So the direction is:

```text
goal: std drop-in replacement
today: compatible subset + compatible extensions
```

## Why `embed` exists

`std` is the semantic model.
`embed` adds one extra capability on top of that model: injectable low-level
implementation.

That lets higher-level code depend on a sealed runtime namespace instead of
binding directly to the host OS or to Zig's built-in runtime choices.

Typical layering:

```text
application / library code
        |
      embed
        |
   platform_impl
```

The application sees a `std`-like API surface.
The platform decides how that surface is implemented underneath.

## Design rule

When in doubt:

- prefer `std` naming
- prefer `std` behavior
- allow additive extensions only when they help platform abstraction and do not
  damage compatibility

That is the intended contract for `lib/embed`.
