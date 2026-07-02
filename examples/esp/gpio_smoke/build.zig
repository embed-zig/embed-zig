const std = @import("std");
const esp = @import("esp");

const board_root = "lib/boards/devkit";

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const esp_build_dep = b.dependency("esp", .{});
    const build_config_module = createBoardBuildConfigModule(
        b,
        esp_build_dep,
        esp_build_dep.module("esp"),
    );
    const context = esp.idf.resolveBuildContext(b, .{
        .build_config = build_config_module,
        .esp_dep = esp_build_dep,
    });

    const esp_dep = b.dependency("esp", .{
        .target = context.target,
        .optimize = optimize,
    });
    const runtime_build_config_module = createBoardBuildConfigModule(
        b,
        esp_dep,
        esp_dep.module("esp"),
    );
    const esp_grt_module = esp_dep.module("esp").import_table.get("esp_grt") orelse
        @panic("esp module is missing esp_grt import");
    esp_grt_module.addImport("build_config", runtime_build_config_module);
    const embed_module = esp_dep.module("esp_embed");

    const entry_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = context.target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "esp", .module = esp_dep.module("esp") },
            .{ .name = "embed", .module = embed_module },
        },
        .link_libc = true,
    });

    const app = esp.idf.addApp(b, "gpio_smoke", .{
        .context = context,
        .entry = .{
            .symbol = "zig_esp_main",
            .module = entry_module,
        },
        .components = &.{},
    });

    const build_step = b.step("build", "Build the ESP GPIO smoke example");
    build_step.dependOn(app.combine_binaries);
    build_step.dependOn(app.elf_layout);
    b.default_step = build_step;

    const flash_step = b.step("flash", "Flash the ESP GPIO smoke example");
    flash_step.dependOn(app.flash);

    const monitor_step = b.step("monitor", "Monitor the ESP GPIO smoke example");
    monitor_step.dependOn(app.monitor);
}

fn createBoardBuildConfigModule(
    b: *std.Build,
    esp_dep: *std.Build.Dependency,
    esp_module: *std.Build.Module,
) *std.Build.Module {
    const esp32s3_boards_common = b.createModule(.{
        .root_source_file = esp_dep.path("lib/boards/common/esp32s3.zig"),
    });
    return b.createModule(.{
        .root_source_file = esp_dep.path(board_root ++ "/build_config.zig"),
        .imports = &.{
            .{ .name = "esp", .module = esp_module },
            .{ .name = "esp32s3_boards_common", .module = esp32s3_boards_common },
        },
    });
}
