const std = @import("std");
const esp = @import("esp");

const board_root = "lib/boards/szp";

pub fn build(b: *std.Build) void {
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSmall;
    const esp_build_dep = b.dependency("esp", .{});
    const build_config_module = createBoardBuildConfigModule(b, esp_build_dep, esp_build_dep.module("esp"));
    const context = esp.idf.resolveBuildContext(b, .{
        .build_config = build_config_module,
        .esp_dep = esp_build_dep,
    });

    const esp_dep = b.dependency("esp", .{
        .target = context.target,
        .optimize = optimize,
    });
    const glib_dep = b.dependency("glib", .{
        .target = context.target,
        .optimize = optimize,
    });
    const runtime_build_config_module = createBoardBuildConfigModule(b, esp_dep, esp_dep.module("esp"));
    const esp_grt_module = esp_dep.module("esp").import_table.get("esp_grt") orelse
        @panic("esp module is missing esp_grt import");
    esp_grt_module.addImport("build_config", runtime_build_config_module);

    const esp_embed_module = esp_dep.module("esp_embed");
    const lvgl_config_header = b.option(
        std.Build.LazyPath,
        "lvgl_config_header",
        "Optional path to a complete LVGL config header; otherwise use thirdparty/pkg/lvgl/config.default.h",
    ) orelse b.path("../../../thirdparty/pkg/lvgl/config.default.h");
    const thirdparty_dep = b.dependency("thirdparty", .{
        .target = context.target,
        .optimize = optimize,
        .lvgl_config_header = lvgl_config_header,
    });
    const opus_module = thirdparty_dep.module("opus");
    const opus_osal_module = thirdparty_dep.module("opus_osal");
    const lvgl_module = thirdparty_dep.module("lvgl");
    const lvgl_osal_module = thirdparty_dep.module("lvgl_osal");

    const entry_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = context.target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "esp", .module = esp_dep.module("esp") },
            .{ .name = "glib", .module = glib_dep.module("glib") },
            .{ .name = "embed", .module = esp_embed_module },
            .{ .name = "lvgl", .module = lvgl_module },
            .{ .name = "lvgl_osal", .module = lvgl_osal_module },
            .{ .name = "opus", .module = opus_module },
            .{ .name = "opus_osal", .module = opus_osal_module },
        },
        .link_libc = true,
    });

    const szp_board = addBoardComponent(b, esp_build_dep);
    const json_compat = esp.idf.Component.create(b, .{ .name = "json" });
    json_compat.addFile(.{
        .relative_path = "idf_component.yml",
        .file = b.path("components/json_compat/idf_component.yml"),
    });
    json_compat.addRequire("espressif__cjson");

    const app = esp.idf.addApp(b, "chant", .{
        .context = context,
        .entry = .{
            .symbol = "zig_esp_main",
            .module = entry_module,
        },
        .components = &.{ szp_board, json_compat },
    });

    const build_step = b.step("build", "Build the chant example");
    build_step.dependOn(app.combine_binaries);
    build_step.dependOn(app.elf_layout);
    b.default_step = build_step;

    const flash_step = b.step("flash", "Flash the chant example");
    flash_step.dependOn(app.flash);

    const monitor_step = b.step("monitor", "Monitor the chant example");
    monitor_step.dependOn(app.monitor);
}

fn createBoardBuildConfigModule(
    b: *std.Build,
    esp_dep: *std.Build.Dependency,
    esp_module: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = esp_dep.path(board_root ++ "/build_config.zig"),
        .imports = &.{
            .{ .name = "esp", .module = esp_module },
        },
    });
}

fn addBoardComponent(b: *std.Build, esp_dep: *std.Build.Dependency) *esp.idf.Component {
    const component = esp.idf.Component.create(b, .{ .name = "szp_board" });
    component.addFile(.{
        .relative_path = "idf_component.yml",
        .file = esp_dep.path(board_root ++ "/idf_component.yml"),
    });
    component.addIncludePath(esp_dep.path(board_root ++ "/include"));
    component.addCSourceFiles(.{
        .root = esp_dep.path(board_root ++ "/bindings"),
        .files = &.{
            "szp_board.c",
            "szp_storage.c",
            "szp_audio.c",
            "szp_button.c",
            "szp_display.c",
            "wifi_sta.c",
        },
    });
    component.addRequire("driver");
    component.addRequire("esp_driver_gpio");
    component.addRequire("esp_driver_i2s");
    component.addRequire("esp_driver_ledc");
    component.addRequire("esp_driver_spi");
    component.addRequire("esp_event");
    component.addRequire("esp_lcd");
    component.addRequire("esp_netif");
    component.addRequire("esp_timer");
    component.addRequire("esp_wifi");
    component.addRequire("log");
    component.addRequire("nvs_flash");
    component.addRequire("spiffs");
    return component;
}
