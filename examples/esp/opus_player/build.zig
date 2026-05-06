const std = @import("std");
const esp = @import("esp");
const szp_board_component = @import("components/szp_board/build.zig");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const esp_build_dep = b.dependency("esp", .{});
    const build_config_module = b.createModule(.{
        .root_source_file = b.path("build_config.zig"),
        .imports = &.{
            .{ .name = "esp_idf", .module = esp_build_dep.module("esp_idf") },
        },
    });
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
    const glib_dep = b.dependency("glib", .{
        .target = context.target,
        .optimize = optimize,
    });
    const runtime_build_config_module = b.createModule(.{
        .root_source_file = b.path("build_config.zig"),
        .imports = &.{
            .{ .name = "esp_idf", .module = esp_dep.module("esp_idf") },
        },
    });
    esp_dep.module("esp_grt").addImport("build_config", runtime_build_config_module);
    esp_dep.module("esp_grt").addImport("esp_idf", esp_dep.module("esp_idf"));

    const embed_dep = b.dependency("embed", .{
        .target = context.target,
        .optimize = optimize,
    });
    const thirdparty_dep = b.dependency("thirdparty", .{
        .target = context.target,
        .optimize = optimize,
    });
    const opus_module = thirdparty_dep.module("opus");
    const opus_osal_module = thirdparty_dep.module("opus_osal");
    if (context.toolchain_sysroot) |sysroot| {
        opus_module.addSystemIncludePath(sysroot.include_dir);
        for (opus_module.link_objects.items) |link_object| {
            switch (link_object) {
                .other_step => |compile| compile.root_module.addSystemIncludePath(sysroot.include_dir),
                else => {},
            }
        }
    }

    const entry_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = context.target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "esp", .module = esp_dep.module("esp") },
            .{ .name = "glib", .module = glib_dep.module("glib") },
            .{ .name = "embed", .module = embed_dep.module("embed") },
            .{ .name = "opus", .module = opus_module },
            .{ .name = "opus_osal", .module = opus_osal_module },
        },
        .link_libc = true,
    });

    const szp_board = szp_board_component.addTo(b);

    const app = esp.idf.addApp(b, "opus_player", .{
        .context = context,
        .entry = .{
            .symbol = "zig_esp_main",
            .module = entry_module,
        },
        .components = &.{szp_board},
    });

    const build_step = b.step("build", "Build the opus_player example");
    build_step.dependOn(app.combine_binaries);
    build_step.dependOn(app.elf_layout);
    b.default_step = build_step;

    const flash_step = b.step("flash", "Flash the opus_player example");
    flash_step.dependOn(app.flash);

    const monitor_step = b.step("monitor", "Monitor the opus_player example");
    monitor_step.dependOn(app.monitor);
}
