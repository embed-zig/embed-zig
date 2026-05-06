const esp = @import("esp");
const lvgl = @import("lvgl");
const lvgl_osal = @import("lvgl_osal");
const opus_osal = @import("opus_osal");
const assets = @import("assets.zig");
const board = @import("board.zig");
const player = @import("player.zig");

const log = esp.grt.std.log.scoped(.chant_main);
const opus_exports = opus_osal.make(esp.grt, esp.heap.Allocator(.{
    .caps = .spiram_8bit,
    .alignment = .align_u32,
}));
const lvgl_exports = lvgl_osal.make(esp.grt, esp.heap.Allocator(.{ .caps = .internal_8bit }));

comptime {
    _ = opus_exports.opus_alloc_scratch;
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
}

pub export fn zig_esp_main() void {
    board.initNvs() catch |err| fail("nvs", err);
    board.mountStorage() catch |err| fail("spiffs mount", err);
    defer board.unmountStorage();

    const info = board.storageInfo() catch |err| fail("spiffs info", err);
    log.info("spiffs total={d} used={d}", .{ info.total, info.used });

    board.initBoard() catch |err| fail("board init", err);
    lvgl.init();
    board.initAudio() catch |err| fail("audio init", err);
    log.info("board initialized; tracks={d}", .{assets.tracks.len});

    player.run();
}

fn fail(name: []const u8, err: anyerror) noreturn {
    log.err("{s} failed: {s}", .{ name, @errorName(err) });
    @panic("chant init failed");
}
