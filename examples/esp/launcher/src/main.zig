const std = @import("std");
const glib = @import("glib");
const esp = @import("esp");
const config = @import("esp_launcher_config");
const lvgl_osal = @import("lvgl_osal");
const selected_app = @import("selected_app");

const sleep_interval: u64 = @intCast(1 * esp.grt.time.duration.Second);
const log = esp.grt.std.log.scoped(.esp_launcher_main);

const Board = if (std.mem.eql(u8, config.board, "szp"))
    esp.embed.boards.szp.Board
else if (std.mem.eql(u8, config.board, "wv-esp32s3-touch-amoled-1.8"))
    esp.embed.boards.wv_esp32s3_touch_amoled_1_8.Board
else if (std.mem.eql(u8, config.board, "devkit"))
    esp.embed.boards.devkit.Board
else
    @compileError("esp launcher board must be devkit, szp, or wv-esp32s3-touch-amoled-1.8");

const PlatformCtx = struct {
    pub const AudioSystem = Board.AudioSystem;
    pub const fs = esp.fs;

    pub fn bleSpeedTaskOptions() glib.task.Options {
        return .{
            .min_stack_size = 32 * 1024,
        };
    }
};

const ZuxAppType = selected_app.make(PlatformCtx, esp.grt);
const App = esp.Launcher.make(ZuxAppType, Board);
const lvgl_exports = lvgl_osal.makeWithAllocators(
    esp.grt,
    esp.heap.Allocator(.{ .caps = .internal_8bit }),
    esp.heap.Allocator(.{ .caps = .spiram_8bit, .alignment = .align_u32 }),
);

comptime {
    _ = lvgl_exports.lv_mutex_init;
    _ = lvgl_exports.lv_mutex_lock;
    _ = lvgl_exports.lv_mutex_lock_isr;
    _ = lvgl_exports.lv_mutex_unlock;
    _ = lvgl_exports.lv_mutex_delete;
    _ = lvgl_exports.lv_thread_sync_init;
    _ = lvgl_exports.lv_thread_sync_wait;
    _ = lvgl_exports.lv_thread_sync_signal;
    _ = lvgl_exports.lv_thread_sync_signal_isr;
    _ = lvgl_exports.lv_thread_sync_delete;
    _ = lvgl_exports.lv_thread_init;
    _ = lvgl_exports.lv_thread_delete;
    _ = lvgl_exports.lv_mem_init;
    _ = lvgl_exports.lv_mem_deinit;
    _ = lvgl_exports.lv_mem_add_pool;
    _ = lvgl_exports.lv_mem_remove_pool;
    _ = lvgl_exports.lv_malloc_core;
    _ = lvgl_exports.lv_realloc_core;
    _ = lvgl_exports.lv_free_core;
    _ = lvgl_exports.lv_mem_monitor_core;
    _ = lvgl_exports.lv_mem_test_core;
}

var app_heap: [128 * 1024]u8 align(16) = undefined;

pub export fn zig_esp_main() void {
    run() catch |err| {
        log.err("esp launcher failed: {s}", .{@errorName(err)});
        @panic("esp launcher failed");
    };
}

fn run() !void {
    var app_heap_allocator = std.heap.FixedBufferAllocator.init(&app_heap);
    var launcher = try App.init(app_heap_allocator.allocator(), .{
        .pipeline_task_options = .{
            .min_stack_size = 24 * 1024,
        },
        .poller_task_options = .{
            .min_stack_size = 16 * 1024,
        },
    });
    defer launcher.deinit();

    try launcher.start();
    defer launcher.stop() catch {};

    while (true) {
        esp.grt.time.sleep(sleep_interval);
    }
}
