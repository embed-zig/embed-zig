const std = @import("std");
const builtin = @import("builtin");
const desktop = @import("desktop");
const glib = @import("glib");
const gstd = @import("gstd");
const lvgl_osal = @import("lvgl_osal");
const selected_app = @import("selected_app");
const config = @import("desktop_launcher_config");

pub const std_options: std.Options = .{
    .logFn = desktop.log.logFn,
};

comptime {
    _ = lvgl_osal.make(gstd.runtime, std.heap.page_allocator);
}

const DesktopPlatformCtx = desktop.PlatformCtxWith(.{
    .bundle_id = config.bundle_id,
    .home_dir = config.home_dir,
    .storage_root = config.storage_root,
});

const PlatformCtx = struct {
    pub const AudioSystem = DesktopPlatformCtx.AudioSystem;
    pub const Net = DesktopPlatformCtx.Net;
    pub const fs = DesktopPlatformCtx.fs;

    pub fn preferencesProvider(allocator: gstd.runtime.std.mem.Allocator) !desktop.system.preferences.Provider {
        return DesktopPlatformCtx.preferencesProvider(allocator);
    }
};

pub fn main() void {
    if (comptime builtin.target.os.tag == .macos and config.run_tray) {
        runMacosApp();
        return;
    }

    run() catch |err| {
        std.log.err("desktop app '{s}' failed: {s}", .{ config.app_name, @errorName(err) });
        std.process.exit(1);
    };
}

extern fn desktop_launcher_run_tray(port: c_uint) void;

fn runMacosApp() void {
    const server_thread = gstd.runtime.task.go(
        "desktop/launcher/server",
        .{ .min_stack_size = 32 * 1024 },
        glib.task.Routine.init(&server_task, ServerTask.run),
    ) catch |err| {
        std.log.err("desktop app '{s}' failed to start server task: {s}", .{ config.app_name, @errorName(err) });
        std.process.exit(1);
    };
    server_thread.detach();

    desktop_launcher_run_tray(config.port);
    std.process.exit(0);
}

var server_task: ServerTask = .{};

const ServerTask = struct {
    fn run(_: *ServerTask) void {
        serverThreadMain();
    }
};

fn serverThreadMain() void {
    run() catch |err| {
        std.log.err("desktop app '{s}' server failed: {s}", .{ config.app_name, @errorName(err) });
        std.process.exit(1);
    };
}

pub export fn desktop_launcher_quit() callconv(.c) void {
    std.process.exit(0);
}

fn run() !void {
    const Launcher = selected_app.make(PlatformCtx, gstd.runtime);
    const DesktopApp = desktop.App.make(Launcher);

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    const address = desktop.http.AddrPort.from4(.{ 127, 0, 0, 1 }, config.port);
    var listener = try gstd.runtime.net.listen(gpa.allocator(), .{ .address = address });
    defer listener.deinit();

    var app = try DesktopApp.init(gpa.allocator(), .{
        .address = address,
    });
    defer app.deinit();

    std.log.info("desktop app '{s}' listening on http://127.0.0.1:{d}", .{
        config.app_name,
        config.port,
    });
    try app.serve(listener);
}
