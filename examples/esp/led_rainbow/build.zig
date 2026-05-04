const std = @import("std");
const esp = @import("esp");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const esp_dep = b.dependency("esp", .{});
    const build_config_module = b.createModule(.{
        .root_source_file = b.path("build_config.zig"),
        .imports = &.{
            .{ .name = "esp_idf", .module = esp_dep.module("esp_idf") },
        },
    });
    const context = esp.idf.resolveBuildContext(b, .{
        .build_config = build_config_module,
        .esp_dep = esp_dep,
    });

    if (context.toolchain_sysroot) |sysroot| {
        b.sysroot = sysroot.root;
    }

    const entry_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = context.target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "esp", .module = esp_dep.module("esp") },
        },
    });
    const rainbow_component = esp.idf.Component.create(b, .{
        .name = "rainbow_platform",
    });
    rainbow_component.addCSourceFiles(.{
        .root = b.path("components/rainbow_platform"),
        .files = &.{"rainbow_platform.c"},
    });
    rainbow_component.addFile(.{
        .relative_path = "idf_component.yml",
        .file = b.path("components/rainbow_platform/idf_component.yml"),
    });
    rainbow_component.addRequire("led_strip");
    rainbow_component.addRequire("log");

    const app = esp.idf.addApp(b, "led_rainbow", .{
        .context = context,
        .entry = .{
            .symbol = "zig_esp_main",
            .module = entry_module,
        },
        .components = &.{rainbow_component},
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
