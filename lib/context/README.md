# lib/context

`lib/context` provides Go-style context trees for:

- cancellation with causes
- deadlines and timeouts
- request-scoped values

The public entrypoint is `make(lib)`, where `lib` supplies the platform-facing
pieces (`lib.Thread`, `lib.time`, `lib.mem`, and `lib.debug` when needed).

## Quick start

```zig
const context_mod = @import("context");

const ContextApi = context_mod.make(lib);
var context = try ContextApi.init(allocator);
defer context.deinit();

const request_id_key: context_mod.Context.Key(u64) = .{};

const bg = context.background();

var cancel_ctx = try context.withCancel(bg);
defer cancel_ctx.deinit();

var value_ctx = try context.withValue(u64, cancel_ctx, &request_id_key, 42);
defer value_ctx.deinit();

cancel_ctx.cancelWithCause(error.BrokenPipe);

const cause = value_ctx.err();              // error.BrokenPipe
const id = value_ctx.value(u64, &request_id_key); // 42
```

## Model

Each `Context` is a small value handle:

```zig
pub const Context = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    type_id: *const anyopaque,
    allocator: embed.mem.Allocator,
};
```

Copying the handle is fine. The mutable state lives in the heap-allocated node
behind `ptr`.

The tree has one shared lock per root. Cancellation flows downward through the
children list. Deadline and value lookup walk upward through the parent chain.

## API shape

```zig
const ContextApi = context_mod.make(lib);
var context = try ContextApi.init(allocator);
defer context.deinit();
```

The API instance owns one fixed background root:

```zig
const bg = context.background();
```

Derived contexts inherit the parent's allocator:

```zig
var cc = try context.withCancel(bg);
var dc = try context.withDeadline(bg, lib.time.milliTimestamp() + 1000);
var tc = try context.withTimeout(bg, 1000);
var vc = try context.withValue(u64, cc, &request_id_key, 42);
```

All of these return `Context` handles directly.

## Core operations

`Context` exposes the common interface used by callers:

- `err()` returns `?anyerror`
- `deadline()` returns `?i128`
- `wait(timeout_ns)` blocks until cancel/deadline or timeout
- `cancel()` marks the node canceled with `error.Canceled`
- `cancelWithCause(err)` marks the node canceled with a custom cause
- `deinit()` detaches the node from the tree and frees its implementation
- `value(T, key)` performs typed lookup through the parent chain
- `as(T)` downcasts to a concrete implementation when tests/internal code need it

Recursive cancellation walks take shared locks as they descend, so the injected
`lib.Thread.RwLock` must allow nested shared-reader acquisition on the same
thread.

## Node types

### Background

The background context:

- never cancels
- has no deadline
- has no values
- is created once per `ContextApi.init(...)`

### CancelContext

`withCancel(parent)` creates a heap-backed cancelable node. Calling
`cancel()` or `cancelWithCause(...)`:

- records the first cause
- wakes waiters
- recursively propagates the cause to descendants

Canceling does not free the node. The creator still owns `deinit()`.

### DeadlineContext

`withDeadline(...)` and `withTimeout(...)` add an automatic cancellation point.
The effective deadline is the earlier of:

- the node's own deadline
- the nearest parent deadline

If the timer thread cannot be started, the context is canceled with that spawn
error instead of silently disabling the deadline.

### ValueContext

`withValue(T, parent, key, value)` adds one typed key/value binding.

- values are matched by key address identity
- lookups prefer the nearest matching value
- `cancel()` / `cancelWithCause()` are no-ops on the value node itself
- cancellation and wait behavior delegate through the parent chain

## Lifecycle contract

Derived contexts are owning handles. The creator that calls `withCancel`,
`withDeadline`, `withTimeout`, or `withValue` is responsible for eventually
calling `deinit()` on that returned handle.

`cancel()` only changes cancellation state. It does not free memory.

`deinit()`:

- detaches the node from its parent
- reparents any live children to its own parent
- frees that node's storage

This means a parent may be deinitialized before its children, and those
children continue to work after being reparented.

The root `ContextApi.deinit()` has a stricter contract: the tree must already
be empty. In debug builds this is guarded by an assertion on the background
root's children list. Callers must deinitialize all derived contexts before
deinitializing the API instance itself.

## Values

Keys are typed and compared by address identity:

```zig
const request_id_key: context_mod.Context.Key(u64) = .{};
const trace_id_key: context_mod.Context.Key(u128) = .{};

const request_id = ctx.value(u64, &request_id_key);
const trace_id = ctx.value(u128, &trace_id_key);
```

Each distinct key variable has a distinct address, so no hashing or dynamic
type checks are needed beyond the requested `T`.

## Testing

The reusable unit-test entrypoint now lives under the shared `lib/test/`
tree:

```zig
const testing = @import("testing").make(lib);
const context_runner = @import("test/context.zig").make(lib);

var t = testing.init();
defer t.deinit();
t.run("context", context_runner);
if (!t.wait()) return error.TestFailed;
```

The test runner covers:

- basic cancellation and custom causes
- propagation through cancel, deadline, and value nodes
- spurious wake handling in timed waits
- deadline timer startup failure behavior
- lifecycle rules such as reparent-on-deinit and root deinit's empty-tree
  contract
