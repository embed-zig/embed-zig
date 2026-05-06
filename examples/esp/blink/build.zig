const std = @import("std");
const esp = @import("esp");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const esp_dep = b.dependency("esp", .{});
    const build_config_module = b.createModule(.{
        .root_source_file = b.path("build_config.zig"),
        .imports = &.{
            .{ .name = "esp", .module = esp_dep.module("esp") },
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
    const blink_component = esp.idf.Component.create(b, .{
        .name = "blink_component",
    });
    blink_component.addCSourceFiles(.{
        .root = b.path("components/blink_component"),
        .files = &.{"blink.c"},
    });
    blink_component.addFile(.{
        .relative_path = "idf_component.yml",
        .file = b.path("components/blink_component/idf_component.yml"),
    });
    blink_component.addRequire("led_strip");
    blink_component.addRequire("log");

    const app = esp.idf.addApp(b, "blink", .{
        .context = context,
        .entry = .{
            .symbol = "zig_esp_main",
            .module = entry_module,
        },
        .components = &.{blink_component},
    });

    const build_step = b.step("build", "Build the blink example");
    build_step.dependOn(app.combine_binaries);
    build_step.dependOn(app.elf_layout);
    b.default_step = build_step;

    const flash_step = b.step("flash", "Flash the blink example");
    flash_step.dependOn(app.flash);

    const monitor_step = b.step("monitor", "Monitor the blink example");
    monitor_step.dependOn(app.monitor);
}
