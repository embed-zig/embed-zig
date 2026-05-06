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
    const storage_component = esp.idf.Component.create(b, .{
        .name = "storage_component",
    });
    storage_component.addCSourceFiles(.{
        .root = b.path("components/storage_component"),
        .files = &.{"storage.c"},
    });
    storage_component.addRequire("log");
    storage_component.addRequire("nvs_flash");
    storage_component.addRequire("spiffs");

    const app = esp.idf.addApp(b, "storage_smoke", .{
        .context = context,
        .entry = .{
            .symbol = "zig_esp_main",
            .module = entry_module,
        },
        .components = &.{storage_component},
    });

    const build_step = b.step("build", "Build the storage_smoke example");
    build_step.dependOn(app.combine_binaries);
    build_step.dependOn(app.elf_layout);
    b.default_step = build_step;

    const flash_step = b.step("flash", "Flash the storage_smoke example");
    flash_step.dependOn(app.flash);

    const monitor_step = b.step("monitor", "Monitor the storage_smoke example");
    monitor_step.dependOn(app.monitor);
}
