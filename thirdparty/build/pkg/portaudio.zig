const std = @import("std");
const buildtools = @import("buildtools");

/// Upstream tree from GitHub codeload (`ref` = commit SHA).
const upstream_tarball_url = "https://codeload.github.com/PortAudio/portaudio/tar.gz/147dd722548358763a8b649b3e4b41dfffbcfbb6";
const upstream_version_key = "147dd722548358763a8b649b3e4b41dfffbcfbb6";

var library: ?*std.Build.Step.Compile = null;
var supported_os: ?std.Target.Os.Tag = null;

const common_include_dirs: []const []const u8 = &.{
    "include",
    "src/common",
    "src/os/unix",
};

const common_c_sources: []const []const u8 = &.{
    "src/common/pa_allocation.c",
    "src/common/pa_converters.c",
    "src/common/pa_cpuload.c",
    "src/common/pa_debugprint.c",
    "src/common/pa_dither.c",
    "src/common/pa_front.c",
    "src/common/pa_process.c",
    "src/common/pa_ringbuffer.c",
    "src/common/pa_stream.c",
    "src/common/pa_trace.c",
    "src/os/unix/pa_unix_hostapis.c",
    "src/os/unix/pa_unix_util.c",
};

const macos_include_dirs: []const []const u8 = &.{
    "src/hostapi/coreaudio",
};

const macos_c_sources: []const []const u8 = &.{
    "src/hostapi/coreaudio/pa_mac_core.c",
    "src/hostapi/coreaudio/pa_mac_core_blocking.c",
    "src/hostapi/coreaudio/pa_mac_core_utilities.c",
};

const linux_include_dirs: []const []const u8 = &.{
    "src/hostapi/alsa",
};

const linux_c_sources: []const []const u8 = &.{
    "src/hostapi/alsa/pa_linux_alsa.c",
};

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const os_tag = target.result.os.tag;
    const upstream = buildtools.addFetchArchive(b, .{
        .url = upstream_tarball_url,
        .version_key = upstream_version_key,
        .cache_namespace = "portaudio-upstream",
        .step_name = "portaudio.fetch-archive.ensure",
    });

    const build_options = b.addOptions();
    build_options.addOption(
        bool,
        "portaudio_live",
        b.option(bool, "portaudio_live", "Run PortAudio live integration tests") orelse false,
    );

    const mod = b.createModule(.{
        .root_source_file = b.path("pkg/portaudio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addModuleInputs(b, mod, upstream, target, os_tag);
    mod.addOptions("build_options", build_options);
    b.modules.put("portaudio", mod) catch @panic("OOM");

    if (!testSupported(b, target)) return;

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "portaudio",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_c = .off,
        }),
    });
    addModuleInputs(b, lib.root_module, upstream, target, os_tag);
    addLibraryCSources(lib.root_module, upstream, os_tag);
    upstream.dependOn(&lib.step);

    library = lib;
    supported_os = os_tag;
}

pub fn link(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.modules.get("portaudio") orelse @panic("portaudio module missing");
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const embed_dep = b.dependency("embed", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("glib", glib_dep.module("glib"));
    mod.addImport("embed", embed_dep.module("embed"));
    const lib = library orelse return;
    const os_tag = supported_os orelse return;
    mod.addObjectFile(lib.getEmittedBin());
    linkPlatformLibraries(mod, os_tag);
}

pub fn testSupported(_: *std.Build, target: std.Build.ResolvedTarget) bool {
    const os_tag = target.result.os.tag;
    return os_tag == .macos or os_tag == .linux;
}

fn linkPlatformLibraries(mod: *std.Build.Module, os_tag: std.Target.Os.Tag) void {
    switch (os_tag) {
        .macos => {
            mod.linkFramework("CoreAudio", .{});
            mod.linkFramework("AudioToolbox", .{});
            mod.linkFramework("AudioUnit", .{});
            mod.linkFramework("CoreFoundation", .{});
            mod.linkFramework("CoreServices", .{});
        },
        .linux => {
            mod.linkSystemLibrary("asound", .{});
            mod.linkSystemLibrary("m", .{});
            mod.linkSystemLibrary("pthread", .{});
        },
        else => {},
    }
}

fn addModuleInputs(
    b: *std.Build,
    mod: *std.Build.Module,
    upstream: buildtools.Archive,
    target: std.Build.ResolvedTarget,
    os_tag: std.Target.Os.Tag,
) void {
    for (common_include_dirs) |dir| {
        mod.addIncludePath(upstream.includePath(dir));
    }
    switch (os_tag) {
        .macos => {
            for (macos_include_dirs) |dir| {
                mod.addIncludePath(upstream.includePath(dir));
            }
            mod.addCMacro("PA_USE_COREAUDIO", "1");
        },
        .linux => {
            for (linux_include_dirs) |dir| {
                mod.addIncludePath(upstream.includePath(dir));
            }
            mod.addCMacro("PA_USE_ALSA", "1");
        },
        else => {},
    }

    if (targetEndianTag(target) == .little) {
        mod.addCMacro("PA_LITTLE_ENDIAN", "1");
    } else {
        mod.addCMacro("PA_BIG_ENDIAN", "1");
    }

    if (b.sysroot) |sysroot| {
        mod.addSystemIncludePath(.{
            .cwd_relative = b.pathJoin(&.{ sysroot, "include" }),
        });
        mod.addSystemIncludePath(.{
            .cwd_relative = b.pathJoin(&.{ sysroot, "usr", "include" }),
        });
    }
}

fn addLibraryCSources(
    mod: *std.Build.Module,
    upstream: buildtools.Archive,
    os_tag: std.Target.Os.Tag,
) void {
    for (common_c_sources) |src| {
        mod.addCSourceFile(.{ .file = upstream.sourcePath(src) });
    }
    switch (os_tag) {
        .macos => for (macos_c_sources) |src| {
            mod.addCSourceFile(.{ .file = upstream.sourcePath(src) });
        },
        .linux => for (linux_c_sources) |src| {
            mod.addCSourceFile(.{ .file = upstream.sourcePath(src) });
        },
        else => {},
    }
}

fn targetEndianTag(target: std.Build.ResolvedTarget) std.builtin.Endian {
    return target.result.cpu.arch.endian();
}
