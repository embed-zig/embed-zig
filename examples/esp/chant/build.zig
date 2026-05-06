const std = @import("std");
const buildtools = @import("buildtools");
const esp = @import("esp");
const thirdparty_build = @import("thirdparty");
const szp_board_component = @import("components/szp_board/build.zig");

const lvgl_pkg = thirdparty_build.lvgl;

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
            .{ .name = "esp", .module = esp_dep.module("esp") },
        },
    });
    const esp_grt_module = esp_dep.module("esp").import_table.get("esp_grt") orelse
        @panic("esp module is missing esp_grt import");
    esp_grt_module.addImport("build_config", runtime_build_config_module);

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
    const lvgl_module = thirdparty_dep.module("lvgl");
    const lvgl_osal_module = thirdparty_dep.module("lvgl_osal");
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
            .{ .name = "lvgl", .module = lvgl_module },
            .{ .name = "lvgl_osal", .module = lvgl_osal_module },
            .{ .name = "opus", .module = opus_module },
            .{ .name = "opus_osal", .module = opus_osal_module },
        },
        .link_libc = true,
    });

    const lvgl_archive = buildtools.addFetchArchive(b, .{
        .url = lvgl_pkg.upstream_tarball_url,
        .version_key = lvgl_pkg.upstream_version_key,
        .cache_namespace = "lvgl-upstream",
        .step_name = "chant.lvgl.fetch-archive.ensure",
    });
    const lvgl_component = esp.idf.Component.create(b, .{ .name = "lvgl" });
    lvgl_component.addFile(.{ .relative_path = "lvgl.h", .file = lvgl_archive.path("lvgl.h") });
    lvgl_component.addFile(.{ .relative_path = "lvgl_private.h", .file = lvgl_archive.path("lvgl_private.h") });
    lvgl_component.addFile(.{ .relative_path = "src/lvgl.h", .file = lvgl_archive.path("lvgl.h") });
    lvgl_component.addFile(.{ .relative_path = "src/lvgl_private.h", .file = lvgl_archive.path("lvgl_private.h") });
    lvgl_component.addIncludePath(lvgl_archive.includePath("."));
    lvgl_component.addIncludePath(b.path("components/lvgl_local/include"));
    lvgl_component.addIncludePath(b.path("../../../thirdparty/pkg/lvgl/include"));
    const lvgl_sources = filterLvglSources(b, lvgl_pkg.c_sources);
    for (lvgl_sources) |source_file| {
        if (std.fs.path.dirname(source_file)) |source_dir| {
            lvgl_component.addIncludePath(lvgl_archive.includePath(source_dir));
        }
    }
    lvgl_component.addCSourceFiles(.{
        .root = lvgl_archive.root(),
        .files = lvgl_sources,
        .flags = &.{"-DLV_CONF_INCLUDE_SIMPLE=1"},
    });
    lvgl_component.addCSourceFiles(.{
        .root = b.path("components/lvgl_local"),
        .files = &.{"chant_lvgl_binding.c"},
        .flags = &.{"-DLV_CONF_INCLUDE_SIMPLE=1"},
    });
    const szp_board = szp_board_component.addTo(b);

    const app = esp.idf.addApp(b, "chant", .{
        .context = context,
        .entry = .{
            .symbol = "zig_esp_main",
            .module = entry_module,
        },
        .components = &.{ szp_board, lvgl_component },
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

fn filterLvglSources(b: *std.Build, sources: []const []const u8) []const []const u8 {
    var filtered = std.ArrayList([]const u8).empty;
    for (sources) |source| {
        if (!useLvglSource(source)) continue;
        filtered.append(b.allocator, source) catch @panic("OOM");
    }
    return filtered.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn useLvglSource(source: []const u8) bool {
    if (std.mem.startsWith(u8, source, "src/core/")) return true;
    if (std.mem.startsWith(u8, source, "src/display/")) return true;
    if (std.mem.startsWith(u8, source, "src/draw/convert/lv_draw_buf_convert")) return true;
    if (std.mem.startsWith(u8, source, "src/draw/lv_draw")) return true;
    if (std.mem.eql(u8, source, "src/draw/lv_image_decoder.c")) return true;
    if (std.mem.startsWith(u8, source, "src/draw/sw/")) return true;
    if (std.mem.eql(u8, source, "src/font/lv_font.c")) return true;
    if (std.mem.eql(u8, source, "src/font/fmt_txt/lv_font_fmt_txt.c")) return true;
    if (std.mem.eql(u8, source, "src/font/lv_font_montserrat_14.c")) return true;
    if (std.mem.startsWith(u8, source, "src/indev/")) return true;
    if (std.mem.eql(u8, source, "src/layouts/lv_layout.c")) return true;
    if (std.mem.eql(u8, source, "src/libs/bin_decoder/lv_bin_decoder.c")) return true;
    if (std.mem.startsWith(u8, source, "src/misc/")) return true;
    if (std.mem.eql(u8, source, "src/osal/lv_os.c")) return true;
    if (std.mem.eql(u8, source, "src/osal/lv_os_none.c")) return true;
    if (std.mem.startsWith(u8, source, "src/stdlib/")) return true;
    if (std.mem.startsWith(u8, source, "src/themes/")) return true;
    if (std.mem.startsWith(u8, source, "src/tick/")) return true;
    if (std.mem.eql(u8, source, "src/lv_init.c")) return true;
    if (std.mem.eql(u8, source, "src/widgets/bar/lv_bar.c")) return true;
    if (std.mem.eql(u8, source, "src/widgets/button/lv_button.c")) return true;
    if (std.mem.eql(u8, source, "src/widgets/label/lv_label.c")) return true;
    return false;
}
