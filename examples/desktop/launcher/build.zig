const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const app_name = b.option([]const u8, "app", "App module exported by the apps package") orelse "zux_button-ledstrip";
    const port = b.option(u16, "port", "HTTP port for the desktop launcher") orelse 8080;

    const apps_dep = b.dependency("apps", .{
        .target = target,
        .optimize = optimize,
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
            .{ .name = "selected_app", .module = selected_app },
        },
    });
    exe_mod.addOptions("desktop_launcher_config", launcher_config);

    const exe = b.addExecutable(.{
        .name = "desktop_launcher",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the desktop launcher example");
    run_step.dependOn(&run_cmd.step);

    const build_step = b.step("build", "Build the desktop launcher example");
    build_step.dependOn(&exe.step);

    const test_mod = b.createModule(.{
        .root_source_file = generated_test,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "glib", .module = glib_dep.module("glib") },
            .{ .name = "gstd", .module = gstd_dep.module("gstd") },
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
        \\const glib = @import("glib");
        \\const gstd = @import("gstd");
        \\const selected_app = @import("selected_app");
        \\
        \\const PlatformCtx = struct {};
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
