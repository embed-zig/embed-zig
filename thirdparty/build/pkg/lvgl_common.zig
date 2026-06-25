const std = @import("std");
const buildtools = @import("buildtools");

var options_loaded: bool = false;
var c_sysroot: ?[]const u8 = null;
var c_short_enums: bool = false;
var upstream_archive: ?buildtools.Archive = null;
var config_header: ?*std.Build.Step.ConfigHeader = null;

/// Pinned upstream tree, fetched over HTTPS from GitHub codeload.
pub const upstream_version_key = "85aa60d18b3d5e5588d7b247abf90198f07c8a63";
pub const upstream_tarball_url = "https://codeload.github.com/lvgl/lvgl/tar.gz/" ++ upstream_version_key;

const bundled_custom_include = "lv_os_custom.h";

pub fn configure(b: *std.Build, selected_c_sysroot: []const u8, selected_c_short_enums: bool) void {
    c_short_enums = selected_c_short_enums;
    c_sysroot = if (selected_c_sysroot.len == 0) null else b.dupe(selected_c_sysroot);
    options_loaded = true;
}

pub fn getUpstreamArchive(b: *std.Build) buildtools.Archive {
    if (upstream_archive) |a| return a;
    const a = buildtools.addFetchArchive(b, .{
        .url = upstream_tarball_url,
        .version_key = upstream_version_key,
        .cache_namespace = "lvgl-upstream",
        .step_name = "lvgl.fetch-archive.ensure",
    });
    upstream_archive = a;
    return a;
}

pub fn getConfigHeader(b: *std.Build) *std.Build.Step.ConfigHeader {
    if (config_header) |header| return header;
    loadOptions(b);
    const custom_config_header = b.option(
        std.Build.LazyPath,
        "lvgl_config_header",
        "Optional path to a complete LVGL config header; otherwise use pkg/lvgl/config.default.h",
    );
    const header = createConfigHeader(
        b,
        custom_config_header orelse b.path("pkg/lvgl/config.default.h"),
    );
    config_header = header;
    return header;
}

pub fn cFlags(b: *std.Build) []const []const u8 {
    loadOptions(b);
    if (c_short_enums) return &.{ "-g0", "-fshort-enums" };
    return &.{"-g0"};
}

pub fn addCommonIncludes(
    b: *std.Build,
    mod: *std.Build.Module,
    repo: buildtools.Archive,
    header: *std.Build.Step.ConfigHeader,
) void {
    loadOptions(b);
    mod.addConfigHeader(header);
    mod.addIncludePath(repo.includePath("."));
    mod.addIncludePath(b.path("."));
    mod.addIncludePath(b.path("pkg/lvgl/include"));
    if (b.sysroot) |sysroot| {
        mod.addSystemIncludePath(.{
            .cwd_relative = b.pathJoin(&.{ sysroot, "include" }),
        });
    }
    if (c_sysroot) |sysroot| {
        mod.addSystemIncludePath(.{
            .cwd_relative = b.pathJoin(&.{ sysroot, "include" }),
        });
    }
}

fn loadOptions(b: *std.Build) void {
    if (options_loaded) return;
    const selected_c_sysroot = b.option(
        []const u8,
        "lvgl_c_sysroot",
        "Optional C sysroot used when compiling LVGL for freestanding embedded targets",
    ) orelse "";
    c_short_enums = b.option(
        bool,
        "lvgl_c_short_enums",
        "Compile LVGL C sources with -fshort-enums to match embedded GCC ABI settings",
    ) orelse false;
    c_sysroot = if (selected_c_sysroot.len == 0) null else b.dupe(selected_c_sysroot);
    options_loaded = true;
}

fn createConfigHeader(
    b: *std.Build,
    selected_header: std.Build.LazyPath,
) *std.Build.Step.ConfigHeader {
    const write_files = b.addWriteFiles();
    const template = write_files.add("lvgl_config_header.template",
        \\#ifndef EMBED_ZIG_LV_CONF_WRAPPER_H
        \\#define EMBED_ZIG_LV_CONF_WRAPPER_H
        \\
        \\/* embed-zig fixes LVGL to the custom OS ABI used by lvgl_osal. */
        \\#define LV_USE_OS LV_OS_CUSTOM
        \\#define LV_OS_CUSTOM_INCLUDE "@LVGL_OS_CUSTOM_INCLUDE@"
        \\
        \\#include "@LVGL_SELECTED_CONFIG_HEADER@"
        \\
        \\#undef LV_USE_OS
        \\#define LV_USE_OS LV_OS_CUSTOM
        \\#undef LV_OS_CUSTOM_INCLUDE
        \\#define LV_OS_CUSTOM_INCLUDE "@LVGL_OS_CUSTOM_INCLUDE@"
        \\#endif
        \\
    );
    return b.addConfigHeader(.{
        .style = .{ .autoconf_at = template },
        .include_path = "lv_conf.h",
    }, .{
        .LVGL_SELECTED_CONFIG_HEADER = normalizeIncludePath(b, selected_header),
        .LVGL_OS_CUSTOM_INCLUDE = bundled_custom_include,
    });
}

fn normalizeIncludePath(b: *std.Build, header: std.Build.LazyPath) []const u8 {
    const raw = header.getPath(b);
    const thirdparty_prefix = "thirdparty/";
    const package_relative = if (std.mem.startsWith(u8, raw, thirdparty_prefix))
        raw[thirdparty_prefix.len..]
    else
        raw;
    return std.mem.replaceOwned(u8, b.allocator, package_relative, "\\", "/") catch @panic("OOM");
}
