const bk = @import("bk");
const build_config = @import("build_config");
const glib = @import("glib");
const lvgl_osal = @import("lvgl_osal");
const selected_app = @import("selected_app");

const armino = bk.armino;
const grt = bk.ap.grt;
const log = grt.std.log.scoped(.bk_launcher_ap);
const app_allocator = bk.heap.psram_allocator;
const os_allocator = bk.heap.allocator;

const Board = build_config.Board;
const PlatformCtx = struct {
    pub const AudioSystem = Board.AudioSystem;
    pub const fs = struct {
        pub const storage_path = Board.littlefs_mount_path;

        pub fn hasStoragePartition() bool {
            return true;
        }

        pub fn mountStorage() bk.fs.MountError!void {
            return bk.fs.mountLittlefs(Board);
        }

        pub fn unmountStorage() void {
            bk.fs.unmountLittlefs(Board);
        }
    };

    pub fn setup() !void {}

    pub fn teardown() void {}

    pub fn bleSpeedTaskOptions() glib.task.Options {
        return .{
            .min_stack_size = 32 * 1024,
        };
    }

    pub fn bleSpeedUiTaskOptions() glib.task.Options {
        return .{
            .min_stack_size = 24 * 1024,
        };
    }

    pub fn colorbarUiTaskOptions() glib.task.Options {
        return .{
            .min_stack_size = 24 * 1024,
        };
    }

    pub fn chantPlayerTaskOptions() glib.task.Options {
        return .{
            .min_stack_size = 24 * 1024,
        };
    }

    pub fn chantRecorderTaskOptions() glib.task.Options {
        return .{
            .min_stack_size = 16 * 1024,
        };
    }

    pub fn chantUiTaskOptions() glib.task.Options {
        return .{
            .min_stack_size = 24 * 1024,
        };
    }
};
const ZuxAppType = selected_app.make(PlatformCtx, grt);
const Launcher = bk.Launcher.make(grt, ZuxAppType, Board);

var launcher_storage: ?Launcher = null;

comptime {
    _ = lvgl_osal.makeWithAllocators(grt, os_allocator, app_allocator);
}

export fn zig_ap_main() c_int {
    earlyLog("[BK AP] zig_ap_main entered\r\n");
    armino.system.init() catch |err| {
        earlyLog("[BK AP] armino init failed\r\n");
        log.err("bk_init failed: {}", .{err});
        return 1;
    };
    earlyLog("[BK AP] armino init ok\r\n");
    log.info("main entered board={s}", .{Board.name});

    launcher_storage = Launcher.init(app_allocator, .{
        .poller_poll_interval = 80 * grt.time.duration.MilliSecond,
        .pipeline_task_options = pipelineTaskOptions(),
        .poller_task_options = pollerTaskOptions(),
    }) catch |err| {
        earlyLog("[BK AP] launcher init failed\r\n");
        log.err("launcher init failed: {}", .{err});
        return 1;
    };
    earlyLog("[BK AP] launcher init ok\r\n");
    launcher_storage.?.startWithConfig(bkZuxStartConfig()) catch |err| {
        earlyLog("[BK AP] launcher start failed\r\n");
        log.err("launcher start failed: {}", .{err});
        launcher_storage.?.deinit();
        launcher_storage = null;
        return 1;
    };
    earlyLog("[BK AP] launcher start ok\r\n");

    return 0;
}

fn earlyLog(message: [:0]const u8) void {
    armino.system.emergencyUartWriteString(0, message);
}

fn pipelineTaskOptions() glib.task.Options {
    return .{
        .min_stack_size = 24 * 1024,
    };
}

fn pollerTaskOptions() glib.task.Options {
    return .{
        .min_stack_size = 16 * 1024,
    };
}

fn bkZuxStartConfig() ZuxAppType.StartConfig {
    return .{};
}
