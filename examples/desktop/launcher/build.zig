const std = @import("std");
const desktop_build = @import("desktop");

const exe_name = "desktop_launcher";
const bundle_name = "EmbedDesktopLauncher";
const bundle_id = "dev.embed.desktop.launcher";
const location_usage = "Embed desktop uses location permission to let CoreWLAN read WiFi network information.";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const app_name = b.option([]const u8, "app", "App module exported by the apps package") orelse "zux_button-ledstrip";
    const ble_speed_role = b.option([]const u8, "ble_speed_role", "BLE speed test role: client or server") orelse "client";
    const port = b.option(u16, "port", "HTTP port for the desktop launcher") orelse 8080;

    const apps_dep = b.dependency("apps", .{
        .target = target,
        .optimize = optimize,
        .ble_speed_role = ble_speed_role,
    });
    const desktop_dep = b.dependency("desktop", .{
        .target = target,
        .optimize = optimize,
    });
    const gstd_dep = b.dependency("gstd", .{
        .target = target,
        .optimize = optimize,
    });
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const thirdparty_dep = b.dependency("thirdparty", .{
        .target = target,
        .optimize = optimize,
    });
    const selected_app = apps_dep.module(app_name);

    const generated_test = createTestSource(b);
    const launcher_config = b.addOptions();
    launcher_config.addOption([]const u8, "app_name", app_name);
    launcher_config.addOption(u16, "port", port);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "desktop", .module = desktop_dep.module("desktop") },
            .{ .name = "gstd", .module = gstd_dep.module("gstd") },
            .{ .name = "lvgl_osal", .module = thirdparty_dep.module("lvgl_osal") },
            .{ .name = "selected_app", .module = selected_app },
        },
    });
    exe_mod.addOptions("desktop_launcher_config", launcher_config);

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the desktop launcher example");
    const build_step = b.step("build", "Build the desktop launcher example");
    run_step.dependOn(&run_cmd.step);
    if (target.result.os.tag == .macos) {
        const app_bundle = desktop_build.macos.addApp(b, .{
            .exe = exe,
            .bundle_name = bundle_name,
            .bundle_identifier = bundle_id,
            .executable_name = exe_name,
            .display_name = bundle_name,
            .minimum_system_version = "13.0",
            .usage_descriptions = .{
                .location = location_usage,
                .location_when_in_use = location_usage,
            },
            .sign = .ad_hoc,
        });

        const app_step = b.step("app", "Create a macOS .app wrapper for the desktop launcher");
        app_step.dependOn(app_bundle.step);

        build_step.dependOn(app_bundle.step);
    } else {
        build_step.dependOn(&exe.step);
    }

    const test_mod = b.createModule(.{
        .root_source_file = generated_test,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "desktop", .module = desktop_dep.module("desktop") },
            .{ .name = "glib", .module = glib_dep.module("glib") },
            .{ .name = "gstd", .module = gstd_dep.module("gstd") },
            .{ .name = "lvgl_osal", .module = thirdparty_dep.module("lvgl_osal") },
            .{ .name = "selected_app", .module = selected_app },
        },
    });
    const compile_test = b.addTest(.{
        .root_module = test_mod,
    });
    const run_test = b.addRunArtifact(compile_test);

    const test_step = b.step("test", "Run the selected app through the desktop launcher test hook");
    test_step.dependOn(&run_test.step);

    b.default_step = build_step;
}

fn createTestSource(b: *std.Build) std.Build.LazyPath {
    const write_files = b.addWriteFiles();
    return write_files.add("desktop_launcher_test.zig",
        \\const std = @import("std");
        \\const desktop = @import("desktop");
        \\const glib = @import("glib");
        \\const gstd = @import("gstd");
        \\const lvgl_osal = @import("lvgl_osal");
        \\const selected_app = @import("selected_app");
        \\
        \\comptime {
        \\    _ = lvgl_osal.make(gstd.runtime, std.heap.page_allocator);
        \\}
        \\
        \\const PlatformCtx = if (@hasDecl(selected_app, "TestPlatformCtx"))
        \\    selected_app.TestPlatformCtx
        \\else
        \\    desktop.PlatformCtx;
        \\
        \\test "desktop launcher selected app" {
        \\    const Launcher = selected_app.make(PlatformCtx, gstd.runtime);
        \\
        \\    var t = glib.testing.T.new(gstd.runtime.std, gstd.runtime.time, .desktop_launcher);
        \\    defer t.deinit();
        \\
        \\    t.run("app", Launcher.createTestRunner());
        \\    if (!t.wait()) return error.TestFailed;
        \\}
        \\
    );
}
