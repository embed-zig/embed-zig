const std = @import("std");
const GitRepo = @import("../GitRepo.zig");

var library: ?*std.Build.Step.Compile = null;

const c_sources: []const []const u8 = &.{
    "src/bitwise.c",
    "src/framing.c",
};

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const repo = GitRepo.addGitRepo(b, .{
        .git_repo = "https://github.com/xiph/ogg.git",
        .commit = "06a5e0262cdc28aa4ae6797627a783b5010440f0",
    });
    const local_include = b.path("pkg/ogg/include");
    const config_header = createConfigHeader(
        b,
        b.option(
            std.Build.LazyPath,
            "ogg_config_header",
            "Optional path to a complete Ogg config header; otherwise embed-zig includes pkg/ogg/config.default.h",
        ) orelse b.path("pkg/ogg/config.default.h"),
    );

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "ogg",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .sanitize_c = .off,
        }),
    });
    lib.root_module.addConfigHeader(config_header);
    lib.root_module.addCMacro("HAVE_CONFIG_H", "1");
    lib.root_module.addIncludePath(local_include);
    lib.root_module.addIncludePath(repo.includePath("include"));
    if (b.sysroot) |sysroot| {
        lib.root_module.addSystemIncludePath(.{
            .cwd_relative = b.pathJoin(&.{ sysroot, "include" }),
        });
    }
    lib.root_module.addCSourceFile(.{ .file = b.path("pkg/ogg/src/binding.c") });
    for (c_sources) |src| {
        lib.root_module.addCSourceFile(.{ .file = repo.sourcePath(src) });
    }
    repo.dependOn(&lib.step);

    const mod = b.createModule(.{
        .root_source_file = b.path("pkg/ogg.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addConfigHeader(config_header);
    mod.addCMacro("HAVE_CONFIG_H", "1");
    mod.addIncludePath(local_include);
    mod.addIncludePath(repo.includePath("include"));
    if (b.sysroot) |sysroot| {
        mod.addSystemIncludePath(.{
            .cwd_relative = b.pathJoin(&.{ sysroot, "include" }),
        });
    }
    b.modules.put("ogg", mod) catch @panic("OOM");
    b.installArtifact(lib);
    library = lib;
}

pub fn link(b: *std.Build) void {
    const embed = b.modules.get("embed") orelse @panic("ogg requires embed");
    const mod = b.modules.get("ogg") orelse @panic("ogg module missing");
    const lib = library orelse @panic("ogg library missing");
    mod.addImport("embed", embed);
    mod.linkLibrary(lib);
}

pub fn linkTest(b: *std.Build, compile: *std.Build.Step.Compile) void {
    const audio = b.modules.get("audio") orelse @panic("ogg tests require audio");
    const embed_std = b.modules.get("embed_std") orelse @panic("ogg tests require embed_std");
    const testing = b.modules.get("testing") orelse @panic("ogg tests require testing");
    compile.root_module.addImport("audio", audio);
    compile.root_module.addImport("embed_std", embed_std);
    compile.root_module.addImport("testing", testing);
}

fn createConfigHeader(
    b: *std.Build,
    selected_header: std.Build.LazyPath,
) *std.Build.Step.ConfigHeader {
    const write_files = b.addWriteFiles();
    const template = write_files.add("ogg_config_header.template",
        \\#ifndef EMBED_ZIG_OGG_CONFIG_H
        \\#define EMBED_ZIG_OGG_CONFIG_H
        \\#include "@OGG_SELECTED_CONFIG_HEADER@"
        \\#endif
        \\
    );
    return b.addConfigHeader(.{
        .style = .{ .autoconf_at = template },
        .include_path = "config.h",
    }, .{
        .OGG_SELECTED_CONFIG_HEADER = normalizeIncludePath(b, selected_header),
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
