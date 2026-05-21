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

    const board_component = addBoardComponent(b, esp_build_dep);
    const app = esp.idf.addApp(b, "led_rainbow", .{
        .context = context,
        .entry = .{
            .symbol = "zig_esp_main",
            .module = entry_module,
        },
        .components = &.{board_component},
    });

    const build_step = b.step("build", "Build the led_rainbow example");
    build_step.dependOn(app.combine_binaries);
    build_step.dependOn(app.elf_layout);
    b.default_step = build_step;

    const flash_step = b.step("flash", "Flash the led_rainbow example");
    flash_step.dependOn(app.flash);

    const monitor_step = b.step("monitor", "Monitor the led_rainbow example");
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
    const component = esp.idf.Component.create(b, .{ .name = "devkit_board" });
    component.addFile(.{
        .relative_path = "idf_component.yml",
        .file = esp_dep.path(board_root ++ "/idf_component.yml"),
    });
    component.addCSourceFiles(.{
        .root = esp_dep.path(board_root ++ "/bindings"),
        .files = &.{
            "power_button.c",
            "led_strip.c",
            "wifi_sta.c",
        },
    });
    component.addRequire("driver");
    component.addRequire("esp_driver_gpio");
    component.addRequire("esp_event");
    component.addRequire("esp_netif");
    component.addRequire("esp_wifi");
    component.addRequire("led_strip");
    component.addRequire("log");
    component.addRequire("nvs_flash");
    return component;
}
