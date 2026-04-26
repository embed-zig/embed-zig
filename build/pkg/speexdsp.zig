const std = @import("std");
const buildtools = @import("buildtools");
const build_tests = @import("../tests.zig");

var library: ?*std.Build.Step.Compile = null;

/// Pinned upstream tree, fetched over HTTPS from GitHub codeload.
const upstream_tarball_url = "https://codeload.github.com/xiph/speexdsp/tar.gz/1b28a0f61bc31162979e1f26f3981fc3637095c8";
const upstream_version_key = "1b28a0f61bc31162979e1f26f3981fc3637095c8";

const upstream_include_dirs: []const []const u8 = &.{
    "include",
    "libspeexdsp",
};

const upstream_c_sources: []const []const u8 = &.{
    "libspeexdsp/preprocess.c",
    "libspeexdsp/mdf.c",
    "libspeexdsp/resample.c",
    "libspeexdsp/fftwrap.c",
    "libspeexdsp/filterbank.c",
    "libspeexdsp/scal.c",
    "libspeexdsp/smallft.c",
    "libspeexdsp/kiss_fft.c",
    "libspeexdsp/kiss_fftr.c",
};

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const upstream = buildtools.addFetchArchive(b, .{
        .url = upstream_tarball_url,
        .version_key = upstream_version_key,
        .cache_namespace = "speexdsp-upstream",
        .step_name = "speexdsp.fetch-archive.ensure",
    });

    const local_include = b.path("pkg/speexdsp/include");
    const config_header = createConfigHeader(
        b,
        b.option(
            std.Build.LazyPath,
            "speexdsp_config_header",
            "Optional path to a complete SpeexDSP config header; otherwise uses pkg/speexdsp/config.default.h",
        ) orelse b.path("pkg/speexdsp/config.default.h"),
    );

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "speexdsp",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_c = .off,
        }),
    });
    addCommonInputs(b, lib.root_module, upstream, local_include, config_header);
    addLibrarySources(b, lib.root_module, upstream);
    upstream.dependOn(&lib.step);

    const mod = createSpeexdspModule(b, target, optimize, upstream, local_include, config_header);
    b.modules.put("speexdsp", mod) catch @panic("OOM");
    library = lib;
}

pub fn link(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const gstd_dep = b.dependency("gstd", .{
        .target = target,
        .optimize = optimize,
    });
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const mod = b.modules.get("speexdsp") orelse @panic("speexdsp module missing");
    const lib = library orelse @panic("speexdsp library missing");
    mod.addImport("embed", build_tests.createEmbedShim(b, target, optimize, gstd_dep));
    mod.addImport("glib", glib_dep.module("glib"));
    mod.linkLibrary(lib);
}

pub fn linkTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    compile_test: *std.Build.Step.Compile,
) void {
    build_tests.addCommonImports(b, target, optimize, compile_test);
}

fn createSpeexdspModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    upstream: buildtools.Archive,
    local_include: std.Build.LazyPath,
    config_header: *std.Build.Step.ConfigHeader,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("pkg/speexdsp.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addCommonInputs(b, mod, upstream, local_include, config_header);
    return mod;
}

fn addCommonInputs(
    b: *std.Build,
    mod: *std.Build.Module,
    upstream: buildtools.Archive,
    local_include: std.Build.LazyPath,
    config_header: *std.Build.Step.ConfigHeader,
) void {
    mod.addConfigHeader(config_header);
    mod.addCMacro("HAVE_CONFIG_H", "1");
    mod.addIncludePath(local_include);
    mod.addIncludePath(b.path("pkg/speexdsp/include/speex"));
    for (upstream_include_dirs) |dir| {
        mod.addIncludePath(upstream.includePath(dir));
    }
    if (b.sysroot) |sysroot| {
        mod.addSystemIncludePath(.{
            .cwd_relative = b.pathJoin(&.{ sysroot, "include" }),
        });
    }
}

fn addLibrarySources(
    b: *std.Build,
    mod: *std.Build.Module,
    upstream: buildtools.Archive,
) void {
    mod.addCSourceFile(.{ .file = b.path("pkg/speexdsp/src/binding.c") });
    for (upstream_c_sources) |src| {
        mod.addCSourceFile(.{ .file = upstream.sourcePath(src) });
    }
}

fn createConfigHeader(
    b: *std.Build,
    selected_header: std.Build.LazyPath,
) *std.Build.Step.ConfigHeader {
    const write_files = b.addWriteFiles();
    const template = write_files.add("speexdsp_config_header.template",
        \\#ifndef EMBED_ZIG_SPEEXDSP_CONFIG_H
        \\#define EMBED_ZIG_SPEEXDSP_CONFIG_H
        \\#include "@SPEEXDSP_SELECTED_CONFIG_HEADER@"
        \\#endif
        \\
    );
    return b.addConfigHeader(.{
        .style = .{ .autoconf_at = template },
        .include_path = "config.h",
    }, .{
        .SPEEXDSP_SELECTED_CONFIG_HEADER = normalizeIncludePath(b, selected_header),
    });
}

fn normalizeIncludePath(b: *std.Build, header: std.Build.LazyPath) []const u8 {
    const raw = header.getPath(b);
    const resolved = if (std.fs.path.isAbsolute(raw))
        raw
    else
        b.pathFromRoot(raw);
    return std.mem.replaceOwned(u8, b.allocator, resolved, "\\", "/") catch @panic("OOM");
}
