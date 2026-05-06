const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const app_name = b.option([]const u8, "app", "App module exported by the apps package") orelse "zux_button-ledstrip";

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

    const generated_main = createMainSource(b, app_name);
    const generated_test = createTestSource(b);

    const exe_mod = b.createModule(.{
        .root_source_file = generated_main,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "desktop", .module = desktop_dep.module("desktop") },
            .{ .name = "gstd", .module = gstd_dep.module("gstd") },
            .{ .name = "selected_app", .module = selected_app },
        },
    });

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

fn createMainSource(b: *std.Build, app_name: []const u8) std.Build.LazyPath {
    const write_files = b.addWriteFiles();
    return write_files.add("desktop_launcher_main.zig", b.fmt(
        \\const std = @import("std");
        \\const desktop = @import("desktop");
        \\const gstd = @import("gstd");
        \\const selected_app = @import("selected_app");
        \\
        \\pub fn main() void {{
        \\    run() catch |err| {{
        \\        std.log.err("desktop app '{f}' failed: {{s}}", .{{@errorName(err)}});
        \\        std.process.exit(1);
        \\    }};
        \\}}
        \\
        \\fn run() !void {{
        \\    const Launcher = selected_app.make(gstd.runtime);
        \\    const DesktopApp = desktop.App.make(Launcher);
        \\
        \\    var gpa: std.heap.GeneralPurposeAllocator(.{{}}) = .{{}};
        \\    defer _ = gpa.deinit();
        \\
        \\    var app = try DesktopApp.init(gpa.allocator(), .{{
        \\        .address = desktop.http.AddrPort.from4(.{{ 127, 0, 0, 1 }}, 8080),
        \\    }});
        \\    defer app.deinit();
        \\
        \\    std.log.info("desktop app '{f}' listening on http://127.0.0.1:8080", .{{}});
        \\    try app.listenAndServe();
        \\}}
        \\
    , .{
        std.zig.fmtString(app_name),
        std.zig.fmtString(app_name),
    }));
}

fn createTestSource(b: *std.Build) std.Build.LazyPath {
    const write_files = b.addWriteFiles();
    return write_files.add("desktop_launcher_test.zig",
        \\const glib = @import("glib");
        \\const gstd = @import("gstd");
        \\const selected_app = @import("selected_app");
        \\
        \\test "desktop launcher selected app" {
        \\    const Launcher = selected_app.make(gstd.runtime);
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
