const std = @import("std");
const build_tools = @import("../build_tools.zig");

const default_repo = "https://github.com/xiph/ogg.git";
const pinned_commit = "06a5e0262cdc28aa4ae6797627a783b5010440f0";
const c_sources: []const []const u8 = &.{
    "src/bitwise.c",
    "src/framing.c",
};
const include_dirs: []const []const u8 = &.{
    "include",
    "include/ogg",
};

pub fn addLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const repo = build_tools.downloadSource(b, .{
        .git_repo = default_repo,
        .commit = pinned_commit,
    });
    const user_define = b.option([]const u8, "ogg_define", "Optional user C macro for ogg; pass with -Dogg_define=NAME or -Dogg_define=NAME=VALUE");

    const command = b.addSystemCommand(&.{
        "/bin/sh",
        "-c",
        "mkdir -p \"$TP_SOURCE_ROOT/include/ogg\"; cp -f \"$TP_BUILD_ROOT/src/third_party/ogg/ogg/config_types.h\" \"$TP_SOURCE_ROOT/include/ogg/config_types.h\"",
    });
    command.setEnvironmentVariable("TP_BUILD_ROOT", b.pathFromRoot("."));
    command.setEnvironmentVariable("TP_SOURCE_ROOT", repo.source_root_path);
    command.setEnvironmentVariable("TP_PREFIX_ROOT", repo.prefix_path);
    command.step.dependOn(repo.ensure_step);

    const lib = b.addLibrary(.{
        .name = "ogg",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    for (include_dirs) |dir| {
        lib.addIncludePath(repo.includePath(b, dir));
    }
    for (c_sources) |src| {
        lib.addCSourceFile(.{ .file = repo.sourcePath(b, src) });
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
        .git_repo = default_repo,
        .commit = pinned_commit,
    });
    for (include_dirs) |dir| {
        module.addIncludePath(repo_dep.includePath(b, dir));
    }
}
