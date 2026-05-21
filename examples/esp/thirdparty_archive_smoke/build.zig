const std = @import("std");
const esp = @import("esp");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const esp_build_dep = b.dependency("esp", .{});
    const build_config_module = b.createModule(.{
        .root_source_file = b.path("build_config.zig"),
        .imports = &.{
            .{ .name = "esp", .module = esp_build_dep.module("esp") },
        },
    });
    const context = esp.idf.resolveBuildContext(b, .{
        .build_config = build_config_module,
        .esp_dep = esp_build_dep,
    });

    const esp_dep = b.dependency("esp", .{
        .target = context.target,
        .optimize = optimize,
    });
    const thirdparty_dep = b.dependency("thirdparty", .{
        .target = context.target,
        .optimize = optimize,
    });

    const entry_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = context.target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "esp", .module = esp_dep.module("esp") },
        },
        .link_libc = true,
    });

    const lvgl_component = addArchiveComponent(b, "thirdparty_lvgl", thirdparty_dep.module("lvgl"));
    const opus_component = addArchiveComponent(b, "thirdparty_opus", thirdparty_dep.module("opus"));
    const speexdsp_component = addArchiveComponent(b, "thirdparty_speexdsp", thirdparty_dep.module("speexdsp"));
    const stb_component = addArchiveComponent(b, "thirdparty_stb_truetype", thirdparty_dep.module("stb_truetype"));

    const app = esp.idf.addApp(b, "thirdparty_archive_smoke", .{
        .context = context,
        .entry = .{
            .symbol = "zig_esp_main",
            .module = entry_module,
        },
        .components = &.{
            lvgl_component,
            opus_component,
            speexdsp_component,
            stb_component,
        },
    });

    const build_step = b.step("build", "Build the thirdparty archive smoke example");
    build_step.dependOn(app.combine_binaries);
    build_step.dependOn(app.elf_layout);
    b.default_step = build_step;
}

fn addArchiveComponent(
    b: *std.Build,
    name: []const u8,
    module: *std.Build.Module,
) *esp.idf.Component {
    const component = esp.idf.Component.create(b, .{ .name = name });
    var archive_count: usize = 0;
    for (module.link_objects.items) |link_object| {
        switch (link_object) {
            .other_step => |artifact| {
                if (artifact.kind == .lib and artifact.linkage == .static) {
                    component.addArtifact(artifact);
                    archive_count += 1;
                }
            },
            .static_path => |file| {
                component.addArchiveFile(.{
                    .relative_path = b.fmt("{s}_{d}.a", .{ name, archive_count }),
                    .file = file,
                });
                archive_count += 1;
            },
            else => {},
        }
    }
    if (archive_count == 0) {
        std.debug.panic("module for component '{s}' does not expose a static archive", .{name});
    }
    return component;
}
