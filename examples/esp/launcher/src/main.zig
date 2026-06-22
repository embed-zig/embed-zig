const std = @import("std");
const glib = @import("glib");
const esp = @import("esp");
const config = @import("esp_launcher_config");
const lvgl_osal = @import("lvgl_osal");
const selected_app = @import("selected_app");

const sleep_interval: u64 = @intCast(1 * esp.grt.time.duration.Second);
const log = esp.grt.std.log.scoped(.esp_launcher_main);
const app_allocator = esp.heap.Allocator(.{ .caps = .spiram_8bit, .alignment = .align_u32 });

const LauncherMode = enum {
    app,
    @"test",
};

const launcher_mode = if (std.mem.eql(u8, config.mode, "app"))
    LauncherMode.app
else if (std.mem.eql(u8, config.mode, "test"))
    LauncherMode.@"test"
else
    @compileError("esp launcher mode must be app or test");

const Board = if (std.mem.eql(u8, config.board, "szp"))
    esp.embed.boards.szp.Board
else if (std.mem.eql(u8, config.board, "wv-esp32s3-touch-amoled-1.8"))
    esp.embed.boards.wv_esp32s3_touch_amoled_1_8.Board
else if (std.mem.eql(u8, config.board, "wv-esp32p4-wifi6-touch-lcd-4.3"))
    esp.embed.boards.wv_esp32p4_wifi6_touch_lcd_4_3.Board
else if (std.mem.eql(u8, config.board, "devkit"))
    esp.embed.boards.devkit.Board
else
    @compileError("esp launcher board must be devkit, szp, wv-esp32s3-touch-amoled-1.8, or wv-esp32p4-wifi6-touch-lcd-4.3");

const PlatformCtx = struct {
    pub const AudioSystem = if (@hasDecl(Board, "AudioSystem")) Board.AudioSystem else void;
    pub const fs = esp.fs;

    pub fn bleSpeedTaskOptions() glib.task.Options {
        return .{
            .min_stack_size = 32 * 1024,
        };
    }

    pub fn preferencesSmokeTaskOptions() glib.task.Options {
        return .{
            .min_stack_size = 12 * 1024,
        };
    }

    pub fn setup() !void {}

    pub fn teardown() void {}

    pub fn preferencesProvider(allocator: esp.grt.std.mem.Allocator) !esp.embed.system.preferences.Provider {
        return esp.embed.system.preferences.Provider.init(.{
            .allocator = allocator,
        });
    }
};

const App = if (launcher_mode == .app)
app: {
    const ZuxAppType = selected_app.make(PlatformCtx, esp.grt);
    break :app esp.Launcher.make(ZuxAppType, Board);
} else void;
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

pub export fn zig_esp_main() void {
    run() catch |err| {
        log.err("esp launcher failed: {s}", .{@errorName(err)});
        @panic("esp launcher failed");
    };
}

fn run() !void {
    switch (launcher_mode) {
        .app => return runApp(),
        .@"test" => return runTest(),
    }
}

fn runApp() !void {
    var launcher = try App.init(app_allocator, .{
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

fn runTest() !void {
    log.info("esp launcher test mode starting", .{});

    var task = TestRunTask{};
    const handle = try esp.grt.task.go("testing/zux/app", .{
        .min_stack_size = 96 * 1024,
    }, glib.task.Routine.init(&task, TestRunTask.run));
    handle.join();
    if (task.err) |err| return err;

    log.info("esp launcher test mode passed", .{});

    while (true) {
        esp.grt.time.sleep(sleep_interval);
    }
}

const TestRunTask = struct {
    err: ?anyerror = null,

    pub fn run(self: *@This()) void {
        selected_app.run(PlatformCtx, esp.grt) catch |err| {
            self.err = err;
            return;
        };
    }
};
