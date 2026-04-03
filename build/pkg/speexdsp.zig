const std = @import("std");
const GitRepo = @import("../GitRepo.zig");

var library: ?*std.Build.Step.Compile = null;

const upstream_repo = "https://github.com/xiph/speexdsp.git";
const upstream_commit = "1b28a0f61bc31162979e1f26f3981fc3637095c8";

const include_dirs: []const []const u8 = &.{
    "include",
    "libspeexdsp",
};

// The package keeps the default path on floating-point + smallft, while
// compiling the upstream smallft/kiss FFT sources so complete config headers
// can select either backend through `-Dspeexdsp_config_header=...`.
const c_sources: []const []const u8 = &.{
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
    const repo = GitRepo.addGitRepo(b, .{
        .git_repo = upstream_repo,
        .commit = upstream_commit,
    });
    const local_include = b.path("pkg/speexdsp/include");
    const config_header = createConfigHeader(
        b,
        b.option(
            std.Build.LazyPath,
            "speexdsp_config_header",
            "Optional path to a complete SpeexDSP config header that matches the current compiled source closure; otherwise embed-zig includes pkg/speexdsp/config.default.h",
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
    addCommonInputs(b, lib.root_module, repo, local_include, config_header);
    addLibrarySources(b, lib.root_module, repo);
    repo.dependOn(&lib.step);

    const mod = b.createModule(.{
        .root_source_file = b.path("pkg/speexdsp.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addCommonInputs(b, mod, repo, local_include, config_header);

    b.modules.put("speexdsp", mod) catch @panic("OOM");
    b.installArtifact(lib);
    library = lib;
}

pub fn link(b: *std.Build) void {
    const embed = b.modules.get("embed") orelse @panic("speexdsp requires embed");
    const mod = b.modules.get("speexdsp") orelse @panic("speexdsp module missing");
    const lib = library orelse @panic("speexdsp library missing");
    mod.addImport("embed", embed);
    mod.linkLibrary(lib);
}

pub fn linkTest(b: *std.Build, compile: *std.Build.Step.Compile) void {
    const embed_std = b.modules.get("embed_std") orelse @panic("speexdsp tests require embed_std");
    const testing = b.modules.get("testing") orelse @panic("speexdsp tests require testing");
    compile.root_module.addImport("embed_std", embed_std);
    compile.root_module.addImport("testing", testing);
}

fn addCommonInputs(
    b: *std.Build,
    mod: *std.Build.Module,
    repo: GitRepo.GitRepo,
    local_include: std.Build.LazyPath,
    config_header: *std.Build.Step.ConfigHeader,
) void {
    mod.addConfigHeader(config_header);
    mod.addCMacro("HAVE_CONFIG_H", "1");
    mod.addIncludePath(local_include);
    for (include_dirs) |dir| {
        mod.addIncludePath(repo.includePath(dir));
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
    repo: GitRepo.GitRepo,
) void {
    mod.addCSourceFile(.{ .file = b.path("pkg/speexdsp/src/binding.c") });
    for (c_sources) |src| {
        mod.addCSourceFile(.{ .file = repo.sourcePath(src) });
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
