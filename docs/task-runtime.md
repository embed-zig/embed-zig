# Task Runtime

`glib.task` is the portable task-launching contract for `embed-zig`. It is not
a `std.Thread` wrapper. Code calls `task.go(name, options, routine)` to describe
the work it needs to run, while platform and board code decide how that work is
mapped to pthreads, FreeRTOS tasks, fibers, CPU cores, priority, allocators,
and memory capabilities.

The design goal is close to a goroutine-style API for business code:

```zig
const handle = try grt.task.go(
    "zux/pipeline/driver",
    .{ .min_stack_size = 16 * 1024 },
    glib.task.Routine.init(&pipeline, runPipeline),
);
handle.join();
```

The C and embedded environment cannot provide Go-style dynamic stacks or a
single universal parking scheduler. Instead, `embed-zig` uses named task
handlers. A task name describes the kind of work; the handler selected by the
board decides the concrete resource policy.

## Design Goals

- Keep task startup simple at the business layer.
- Centralize platform placement, priority, allocator, and memory-capability
  decisions.
- Keep BSP and platform policy out of reusable `glib`, `embed`, `thirdparty`,
  and zux app logic.
- Make resource policy reviewable by scanning board task handlers instead of
  many call sites.

## API Contract

```zig
const handle = try grt.task.go(name, .{
    .min_stack_size = 4096,
}, glib.task.Routine.init(ctx, runFn));
```

- `name` is a slash-delimited static path such as `audio/processor`.
- `Routine` is an explicit `ptr + vtable` runnable object.
- `Handle` is joinable; some platform handles may also support `detach`.
- `Options.min_stack_size` is a lower-bound hint, not the final stack size.

Each `task.go` call should pass the smallest known stack requirement for that
task. That lower bound belongs to the `task.go` call site, not to the handler
registry. Handlers forward or satisfy it while choosing platform resources such
as core, priority, allocator, and memory capabilities based on the task name.

## Handler Routing

Handlers are registered with `glib.task.Builder.handle(prefix, Handler)`.
Runtime task names match the longest registered prefix.

Examples:

```text
audio/processor -> audio
zux/test        -> zux
```

The generic host runtime in `gstd` uses the default root handler. The current
ESP policy backend supports board-defined prefix policies through
`build_config.task_policy`.

Other boards should define equivalent prefixes when they enable the same
services. Exact values are board policy, but prefix names should stay stable so
shared code can stay unchanged.

## Task Name Registry

This table lists task names currently used by `glib`, `embed`, zux apps, and
third-party packages. The registry records stable task names and their owning
module path. Stack lower bounds belong at the `task.go` call site via
`Options.min_stack_size`; this registry does not assign stack sizes. Handlers
choose platform resources such as core, priority, allocator, or memory
capabilities.

| Module Path | Task Name | Description |
| --- | --- | --- |
| `glib.context` | `context/deadline` | Deadline timer worker for cancelable contexts. |
| `glib.net.Resolver` | `net/resolver/attempt_watch` | Watches one DNS lookup attempt race. |
| `glib.net.Resolver` | `net/resolver/server` | DNS lookup worker for one resolver server. |
| `glib.net.Resolver` | `net/resolver/cleanup` | Detached DNS lookup cleanup worker. |
| `glib.net.cmux.Session` | `net/cmux/session` | CMUX session worker. |
| `glib.net.http.Server` | `net/http/server/conn` | HTTP server connection worker. |
| `glib.net.http.Transport` | `net/http/request_body` | HTTP request-body writer worker. |
| `glib.net.ntp.Client` | `net/ntp/race` | NTP server race worker. |
| `glib.sync.Timer` | `sync/timer` | Timer callback worker. |
| `glib.sync.Racer` | caller-provided names | Detached race participants. |
| `embed.audio.AudioSystem` | `audio/read` | Pulls raw mic frames from the mic driver. |
| `embed.audio.AudioSystem` | `audio/processor` | Runs AFE/AEC and writes processed mic samples. |
| `embed.audio.AudioSystem` | `audio/write` | Mixes playback tracks and writes speaker PCM. |
| `embed.bt.host.Hci` | `bt/hci/recv` | HCI receive/event loop. |
| `embed.bt.host.server.Sender` | `bt/server/sender` | Server-side chunked read sender. |
| `embed.bt.host.server.Receiver` | `bt/server/receiver` | Server-side chunked write receiver. |
| `embed.zux.pipeline.Pipeline` | `zux/pipeline/driver` | Main zux message reducer/render driver. |
| `embed.zux.pipeline.Pipeline` | `zux/pipeline/tick` | Periodic tick injection. |
| `embed.zux.pipeline.Pipeline` | `zux/pipeline/poll` | Generic source polling worker. |
| `embed.zux.component.button.SinglePoller` | `zux/button/single` | Single button poller. |
| `embed.zux.component.button.GroupedPoller` | `zux/button/grouped` | Grouped button poller. |
| `embed.zux.component.touch.Poller` | `zux/touch/poller` | Touch polling worker. |
| `embed.zux.component.imu.Poller` | `zux/imu/poller` | IMU polling worker. |
| `thirdparty.lvgl_osal` | `lvgl/swdraw` | LVGL software draw worker. |
| `thirdparty.lvgl_osal` | `lvgl/pxpdraw` | LVGL PXP draw worker. |
| `thirdparty.lvgl_osal` | `lvgl/vglitedraw` | LVGL VG-Lite draw worker. |
| `thirdparty.lvgl_osal` | `lvgl/g2draw` | LVGL G2D draw worker. |
| `thirdparty.lvgl_osal` | `lvgl/thread` | LVGL OSAL fallback worker. |
| `apps.zux.chant.runtime.ui.Lvgl` | `zux/chant/ui` | LVGL UI runtime. |
| `apps.zux.chant.runtime.player` | `zux/chant/player` | Music playback control loop. |
| `apps.zux.chant.runtime.recorder` | `zux/chant/recorder` | Recording state/control loop. |
| `apps.zux.colorbar.runtime.ui.Lvgl` | `zux/colorbar/ui` | LVGL UI runtime. |
| `apps.zux.colorbar_adc.runtime.ui.Lvgl` | `zux/colorbar_adc/ui` | LVGL UI runtime. |
| `apps.zux.adc_group_debug.runtime.ui.Lvgl` | `zux/adc_group_debug/ui` | LVGL UI runtime. |
| `apps.zux.ble_speed.runtime.ui.Lvgl` | `zux/ble_speed/ui` | LVGL UI runtime. |
| `apps.zux.ble_speed.runtime.ble.client` | `zux/ble_speed/client` | BLE client loop. |
| `apps.zux.ble_speed.runtime.ble.server` | `zux/ble_speed/server` | BLE server loop. |
| `apps.zux.sync_smoke` | `zux/sync_smoke/wait` | Sync smoke condition wait worker. |
| `apps.zux.sync_smoke` | `zux/sync_smoke/semaphore_wait` | Sync smoke semaphore wait worker. |
| `apps.zux.sync_smoke` | `zux/sync_smoke/channel_send` | Sync smoke unbuffered channel send worker. |
| `apps.zux.task_smoke` | `zux/task_smoke/alpha` | Task smoke worker. |
| `apps.zux.task_smoke` | `zux/task_smoke/beta` | Task smoke worker. |
| `esp.net.ModemPpp` | `net/modem_ppp_rx` | PPP receive bridge. |
| `examples.esp.wifi_led_threads` | `wifi_led/led` | LED state loop. |
| `examples.esp.wifi_led_threads` | `wifi_led/wifi` | WiFi connection loop. |
| `desktop.http.ZuxServer` | `desktop/launcher/server` | Desktop HTTP server task. |

Board policies may still route several task names through the same prefix, but
that is an implementation choice. The registry above remains the source of
truth for task naming only.

## Testing Task Name Registry

Testing-only task names use the `testing/` prefix so they cannot be confused
with business or runtime service tasks.

| Module Path | Task Name | Description |
| --- | --- | --- |
| `glib.testing.T` | `testing/subtest` | Runs subtests through `task.go`. |
| `glib.context.tests` | `testing/context/waiter` | Context wait/cancel test worker. |
| `glib.context.tests` | `testing/context/create_deinit` | Context create/deinit test worker. |
| `glib.context.tests` | `testing/context/deadline_reader` | Deadline reader test worker. |
| `glib.context.tests` | `testing/context/cancel_wake` | Cancel wake test worker. |
| `glib.context.tests` | `testing/context/value_waiter` | Value context wait test worker. |
| `glib.context.tests` | `testing/context/deadline_wake` | Deadline wake test worker. |
| `glib.context.tests` | `testing/context/deinit_parent` | Parent deinit test worker. |
| `gstd.tests.runtime_task` | `testing/gstd/main` | Host task runtime test. |
| `gstd.tests.runtime_task` | `testing/gstd/batch` | Host task runtime batch test. |
| `gstd.tests.runtime_task` | `testing/gstd/explicit_stack` | Verifies explicit stack hints are forwarded. |
| `embed.audio.tests.mixer` | `testing/audio/ring_buffer_writer` | Ring buffer writer test worker. |
| `embed.audio.tests.mixer` | `testing/audio/gain_reader` | Mixer gain reader test worker. |
| `embed.audio.tests.mixer` | `testing/audio/concurrent_writer` | Concurrent mixer writer test worker. |
| `embed.audio.tests.mixer` | `testing/audio/close_error_writer` | Mixer close-with-error writer test worker. |
| `embed.audio.tests.mixer` | `testing/audio/backpressure_writer` | Mixer backpressure writer test worker. |
| `embed.bt.tests.xfer` | `testing/bt/xfer/read` | Transfer read-side test worker. |
| `embed.bt.tests.xfer` | `testing/bt/xfer/send` | Transfer send-side test worker. |
| `embed.bt.tests.xfer` | `testing/bt/xfer/write` | Transfer write-side test worker. |
| `embed.bt.tests.xfer` | `testing/bt/xfer/recv` | Transfer receive-side test worker. |
| `thirdparty.kcp.tests.loopback` | `testing/kcp/server` | Loopback test server. |
| `thirdparty.lvgl.embed.LvglZuxRuntime` | `testing/lvgl` | LVGL runtime test worker. |
| `examples.esp.launcher` | `testing/zux/app` | zux app test runner on ESP. |

## Adding A Task Name

When adding a new task:

1. Pick a stable slash-delimited name owned by the package or app.
2. Prefer a service prefix that board policies can route, such as `audio`,
   `bt`, `zux`, or `kcp`.
3. Pass `min_stack_size` only as a measured lower bound.
4. Add the new name or prefix to this registry.
5. Add or update board `task_policy` entries when the task needs distinct
   priority, core, allocator, or memory capabilities.

Do not encode BSP policy in business code. Business code should not know
whether a task becomes a FreeRTOS task, pthread, fiber, or a board-specific
execution unit.
