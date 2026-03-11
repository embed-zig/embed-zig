const std = @import("std");
const build_tools = @import("../build_tools.zig");

const repo = "https://github.com/PortAudio/portaudio.git";
const pinned_commit = "147dd722548358763a8b649b3e4b41dfffbcfbb6";
const include_dirs: []const []const u8 = &.{
    "include",
    "src/common",
    "src/os/unix",
    "src/os/win",
    "src/hostapi/coreaudio",
    "src/hostapi/skeleton",
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
};

pub fn addTo(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const repo_dep = build_tools.downloadSource(b, .{
        .git_repo = repo,
        .commit = pinned_commit,
    });
    const lib = b.addLibrary(.{
        .name = "portaudio",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_c = .off,
        }),
    });
    for (include_dirs) |dir| {
        lib.addIncludePath(repo_dep.includePath(b, dir));
    }
    for (common_c_sources) |src| {
        lib.addCSourceFile(.{ .file = repo_dep.sourcePath(b, src) });
    }
    lib.step.dependOn(repo_dep.ensure_step);

    switch (target.result.os.tag) {
        .macos => {
            lib.addCSourceFile(.{ .file = repo_dep.sourcePath(b, "src/os/unix/pa_unix_hostapis.c") });
            lib.addCSourceFile(.{ .file = repo_dep.sourcePath(b, "src/os/unix/pa_unix_util.c") });
            lib.root_module.addCMacro("PA_USE_COREAUDIO", "1");
            lib.addCSourceFile(.{ .file = repo_dep.sourcePath(b, "src/hostapi/coreaudio/pa_mac_core.c") });
            lib.addCSourceFile(.{ .file = repo_dep.sourcePath(b, "src/hostapi/coreaudio/pa_mac_core_blocking.c") });
            lib.addCSourceFile(.{ .file = repo_dep.sourcePath(b, "src/hostapi/coreaudio/pa_mac_core_utilities.c") });
            lib.linkFramework("AudioToolbox");
            lib.linkFramework("AudioUnit");
            lib.linkFramework("CoreAudio");
            lib.linkFramework("CoreFoundation");
            lib.linkFramework("Carbon");
        },
        .linux => {
            lib.addCSourceFile(.{ .file = repo_dep.sourcePath(b, "src/os/unix/pa_unix_hostapis.c") });
            lib.addCSourceFile(.{ .file = repo_dep.sourcePath(b, "src/os/unix/pa_unix_util.c") });
            lib.addCSourceFile(.{ .file = repo_dep.sourcePath(b, "src/hostapi/skeleton/pa_hostapi_skeleton.c") });
            lib.root_module.addCMacro("PA_USE_SKELETON", "1");
        },
        .windows => {
            lib.addCSourceFile(.{ .file = repo_dep.sourcePath(b, "src/os/win/pa_win_hostapis.c") });
            lib.addCSourceFile(.{ .file = repo_dep.sourcePath(b, "src/os/win/pa_win_util.c") });
            lib.addCSourceFile(.{ .file = repo_dep.sourcePath(b, "src/hostapi/skeleton/pa_hostapi_skeleton.c") });
            lib.root_module.addCMacro("PA_USE_SKELETON", "1");
        },
        else => {
            lib.addCSourceFile(.{ .file = repo_dep.sourcePath(b, "src/hostapi/skeleton/pa_hostapi_skeleton.c") });
            lib.root_module.addCMacro("PA_USE_SKELETON", "1");
        },
    }

    return lib;
}

pub fn configureModule(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
) void {
    const repo_dep = build_tools.downloadSource(b, .{
        .git_repo = repo,
        .commit = pinned_commit,
    });
    for (include_dirs) |dir| {
        module.addIncludePath(repo_dep.includePath(b, dir));
    }

    switch (target.result.os.tag) {
        .macos => module.addCMacro("PA_USE_COREAUDIO", "1"),
        .linux, .windows => module.addCMacro("PA_USE_SKELETON", "1"),
        else => module.addCMacro("PA_USE_SKELETON", "1"),
    }
}
