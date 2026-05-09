const std = @import("std");
const esp = @import("esp");
const boards = @import("esp_boards");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const app_name = b.option([]const u8, "app", "App module exported by the apps package") orelse "zux_button-ledstrip";
    const board_name = b.option([]const u8, "board", "Board component under boards/") orelse "devkit";

    const esp_build_dep = b.dependency("esp", .{});
    const build_config_module = boards.createBuildConfigModule(
        b,
        board_name,
        esp_build_dep.module("esp"),
    );
    const context = esp.idf.resolveBuildContext(b, .{
        .build_config = build_config_module,
        .esp_dep = esp_build_dep,
    });

    if (context.toolchain_sysroot) |sysroot| {
        b.sysroot = sysroot.root;
    }

    const esp_dep = b.dependency("esp", .{
        .target = context.target,
        .optimize = optimize,
    });
    const embed_dep = b.dependency("embed", .{
        .target = context.target,
        .optimize = optimize,
    });
    const apps_dep = b.dependency("apps", .{
        .target = context.target,
        .optimize = optimize,
    });
    const selected_app = apps_dep.module(app_name);

    const board_module = boards.createBoardModule(b, board_name, context.target, optimize, .{
        .embed = embed_dep.module("embed"),
        .esp = esp_dep.module("esp"),
    });

    const entry_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = context.target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "esp", .module = esp_dep.module("esp") },
            .{ .name = "selected_app", .module = selected_app },
            .{ .name = "selected_board", .module = board_module },
        },
        .link_libc = true,
    });

    const board_component = boards.addComponent(b, board_name);
    const app = esp.idf.addApp(b, "launcher", .{
        .context = context,
        .entry = .{
            .symbol = "zig_esp_main",
            .module = entry_module,
        },
        .components = &.{board_component},
    });

    const build_step = b.step("build", "Build the ESP launcher example");
    build_step.dependOn(app.combine_binaries);
    build_step.dependOn(app.elf_layout);
    b.default_step = build_step;

    const flash_step = b.step("flash", "Flash the ESP launcher example");
    flash_step.dependOn(app.flash);

    const monitor_step = b.step("monitor", "Monitor the ESP launcher example");
    monitor_step.dependOn(app.monitor);
}
