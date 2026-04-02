const std = @import("std");
const GitRepo = @import("../GitRepo.zig");

var library: ?*std.Build.Step.Compile = null;
var supported_os: ?std.Target.Os.Tag = null;

const upstream_repo = "https://github.com/PortAudio/portaudio.git";
const upstream_commit = "147dd722548358763a8b649b3e4b41dfffbcfbb6";

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
    // PortAudio 19.7's CMake wires only these Unix support units.
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
    if (os_tag != .macos and os_tag != .linux) {
        @panic("portaudio currently supports only macOS and Linux targets");
    }

    const repo = GitRepo.addGitRepo(b, .{
        .git_repo = upstream_repo,
        .commit = upstream_commit,
    });
    const build_options = b.addOptions();
    build_options.addOption(
        bool,
        "portaudio_live",
        b.option(bool, "portaudio_live", "Run PortAudio live integration tests") orelse false,
    );

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
    addModuleInputs(b, lib.root_module, repo, target, os_tag);
    addLibraryCSources(lib.root_module, repo, os_tag);
    repo.dependOn(&lib.step);

    const mod = b.createModule(.{
        .root_source_file = b.path("pkg/portaudio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addModuleInputs(b, mod, repo, target, os_tag);
    mod.addOptions("build_options", build_options);

    b.modules.put("portaudio", mod) catch @panic("OOM");
    b.installArtifact(lib);
    library = lib;
    supported_os = os_tag;
}

pub fn link(b: *std.Build) void {
    const embed = b.modules.get("embed") orelse @panic("portaudio requires embed");
    const mod = b.modules.get("portaudio") orelse @panic("portaudio module missing");
    const lib = library orelse @panic("portaudio library missing");
    const os_tag = supported_os orelse @panic("portaudio target missing");

    mod.addImport("embed", embed);
    mod.linkLibrary(lib);
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
        else => unreachable,
    }
}

pub fn linkTest(b: *std.Build, compile: *std.Build.Step.Compile) void {
    const embed_std = b.modules.get("embed_std") orelse @panic("portaudio tests require embed_std");
    const testing = b.modules.get("testing") orelse @panic("portaudio tests require testing");
    compile.root_module.addImport("embed_std", embed_std);
    compile.root_module.addImport("testing", testing);
}

fn addModuleInputs(
    b: *std.Build,
    mod: *std.Build.Module,
    repo: GitRepo.GitRepo,
    target: std.Build.ResolvedTarget,
    os_tag: std.Target.Os.Tag,
) void {
    for (common_include_dirs) |dir| {
        mod.addIncludePath(repo.includePath(dir));
    }
    switch (os_tag) {
        .macos => {
            for (macos_include_dirs) |dir| {
                mod.addIncludePath(repo.includePath(dir));
            }
            mod.addCMacro("PA_USE_COREAUDIO", "1");
        },
        .linux => {
            for (linux_include_dirs) |dir| {
                mod.addIncludePath(repo.includePath(dir));
            }
            mod.addCMacro("PA_USE_ALSA", "1");
        },
        else => unreachable,
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
    }
}

fn addLibraryCSources(
    mod: *std.Build.Module,
    repo: GitRepo.GitRepo,
    os_tag: std.Target.Os.Tag,
) void {
    for (common_c_sources) |src| {
        mod.addCSourceFile(.{ .file = repo.sourcePath(src) });
    }
    switch (os_tag) {
        .macos => for (macos_c_sources) |src| {
            mod.addCSourceFile(.{ .file = repo.sourcePath(src) });
        },
        .linux => for (linux_c_sources) |src| {
            mod.addCSourceFile(.{ .file = repo.sourcePath(src) });
        },
        else => unreachable,
    }
}

fn targetEndianTag(target: std.Build.ResolvedTarget) std.builtin.Endian {
    return target.result.cpu.arch.endian();
}
