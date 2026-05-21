const std = @import("std");
const desktop = @import("desktop");
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

const PlatformCtx = desktop.PlatformCtx;

pub fn main() void {
    run() catch |err| {
        std.log.err("desktop app '{s}' failed: {s}", .{ config.app_name, @errorName(err) });
        std.process.exit(1);
    };
}

fn run() !void {
    const Launcher = selected_app.make(PlatformCtx, gstd.runtime);
    const DesktopApp = desktop.App.make(Launcher);

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    const address = desktop.http.AddrPort.from4(.{ 127, 0, 0, 1 }, config.port);
    var app = try DesktopApp.init(gpa.allocator(), .{
        .address = address,
    });
    defer app.deinit();

    std.log.info("desktop app '{s}' listening on http://127.0.0.1:{d}", .{
        config.app_name,
        config.port,
    });
    try app.listenAndServe();
}
