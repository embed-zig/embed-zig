# lib/task

`lib/task` provides a small named task-launching contract for `glib`.

It is not a wrapper around `std.Thread`. The module owns only:

- a comptime `Builder`
- static path routing from task names to handlers
- a `Routine` executable object
- a joinable `go` entrypoint on the generated task runtime

Platform handlers decide how a task is started. A handler may create an OS
thread, a FreeRTOS task, a fiber, or any other execution unit. The handler may
also choose stack size, priority, CPU affinity, allocator, or memory region from
the task name.

## Shape

```zig
pub const Task = comptime blk: {
    var builder = task.Builder();
    builder.handle("", DefaultHandler);
    builder.handle("ui/", UiHandler);
    builder.handle("ui/app/", UiAppHandler);
    builder.onError(TaskErrorHandler);
    break :blk builder.make();
};
```

Runtime code then calls:

```zig
const routine = task.Routine.init(&app, runUiApp);
const handle = try Task.go("ui/app", .{}, routine);
handle.join();
```

`Routine` is `ptr + vtable`; it makes state lifetime explicit at the call site.
`go` returns the platform handle and error set. Callers must keep ownership of
the handle by joining it or transferring it to a parent/supervisor. The public
API does not provide a fire-and-forget detach helper.

`Options.min_stack_size` is a lower-bound resource hint, not a thread config.
The platform handler still owns stack policy, memory placement, priority, core
affinity, pool selection, and whether dynamic stack growth is available.

## Routing

Handlers are registered on slash-delimited static paths. `make()` compiles the
registered paths into a static tree. Runtime task names are matched by longest
path prefix:

- `ui/app/render` matches `ui/app`
- `ui/button` matches `ui`
- unknown names match the root handler when one was registered with `""` or `/`

First-version path segments are restricted to Zig identifier-shaped names so
registered paths can map cleanly to generated struct fields.
