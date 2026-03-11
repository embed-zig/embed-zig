const std = @import("std");
const build_tools = @import("../build_tools.zig");

const repo = "https://github.com/xiph/speexdsp.git";
const pinned_commit = "7a158783df74efe7c2d1c6ee8363c1e695c71226";
const include_dirs: []const []const u8 = &.{
    "include",
    "libspeexdsp",
};
const c_flags: []const []const u8 = &.{
    "-fwrapv",
};
const macro_defines: []const build_tools.MacroDefine = &.{
    .{ .name = "USE_KISS_FFT" },
    .{ .name = "FLOATING_POINT" },
    .{ .name = "EXPORT", .value = "" },
};
const c_sources: []const []const u8 = &.{
    "libspeexdsp/preprocess.c",
    "libspeexdsp/jitter.c",
    "libspeexdsp/mdf.c",
    "libspeexdsp/fftwrap.c",
    "libspeexdsp/filterbank.c",
    "libspeexdsp/resample.c",
    "libspeexdsp/buffer.c",
    "libspeexdsp/scal.c",
    "libspeexdsp/kiss_fft.c",
    "libspeexdsp/kiss_fftr.c",
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
    const user_define = b.option([]const u8, "speexdsp_define", "Optional user C macro for speexdsp; pass with -Dspeexdsp_define=NAME or -Dspeexdsp_define=NAME=VALUE");

    const command = b.addSystemCommand(&.{
        "/bin/sh",
        "-c",
        "mkdir -p \"$TP_SOURCE_ROOT/include/speex\"; cp -f \"$TP_BUILD_ROOT/src/third_party/speexdsp/speex/speexdsp_config_types.h\" \"$TP_SOURCE_ROOT/include/speex/speexdsp_config_types.h\"",
    });
    command.setEnvironmentVariable("TP_BUILD_ROOT", b.pathFromRoot("."));
    command.setEnvironmentVariable("TP_SOURCE_ROOT", repo_dep.source_root_path);
    command.setEnvironmentVariable("TP_PREFIX_ROOT", repo_dep.prefix_path);
    command.step.dependOn(repo_dep.ensure_step);

    const lib = b.addLibrary(.{
        .name = "speexdsp",
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
    for (c_sources) |src| {
        lib.addCSourceFile(.{
            .file = repo_dep.sourcePath(b, src),
            .flags = c_flags,
        });
    }
    for (macro_defines) |define| {
        lib.root_module.addCMacro(define.name, define.value);
    }
    build_tools.applyUserDefine(lib.root_module, user_define);
    lib.step.dependOn(&command.step);

    return lib;
}

pub fn configureModule(
    b: *std.Build,
    module: *std.Build.Module,
) void {
    const repo_dep = build_tools.downloadSource(b, .{
        .git_repo = repo,
        .commit = pinned_commit,
    });
    for (include_dirs) |dir| {
        module.addIncludePath(repo_dep.includePath(b, dir));
    }
    for (macro_defines) |define| {
        module.addCMacro(define.name, define.value);
    }
}
