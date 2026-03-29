const std = @import("std");
const GitRepo = @import("../GitRepo.zig");

var library: ?*std.Build.Step.Compile = null;

pub const Config = struct {
    config_header: ?std.Build.LazyPath = null,
};

const ConfigHeaderValues = struct {
    DISABLE_CRC: ?u8 = null,
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
    const config: Config = .{
        .config_header = b.option(
            std.Build.LazyPath,
            "ogg_config_header",
            "Optional path to a complete Ogg config header; otherwise embed-zig renders pkg/ogg/config.h.in with Zig's config header support",
        ),
    };
    const config_header = createConfigHeader(b, config);
    const c_wrappers = createWrappedCSources(b, repo);

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
    lib.root_module.addIncludePath(local_include);
    lib.root_module.addIncludePath(repo.includePath("include"));
    if (b.sysroot) |sysroot| {
        lib.root_module.addSystemIncludePath(.{
            .cwd_relative = b.pathJoin(&.{ sysroot, "include" }),
        });
    }
    lib.root_module.addCSourceFile(.{ .file = b.path("pkg/ogg/src/binding.c") });
    for (c_wrappers) |src| {
        lib.root_module.addCSourceFile(.{ .file = src });
    }
    repo.dependOn(&lib.step);

    const mod = b.createModule(.{
        .root_source_file = b.path("pkg/ogg.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addConfigHeader(config_header);
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
    const embed_std = b.modules.get("embed_std") orelse @panic("ogg tests require embed_std");
    const testing = b.modules.get("testing") orelse @panic("ogg tests require testing");
    compile.root_module.addImport("embed_std", embed_std);
    compile.root_module.addImport("testing", testing);
}

fn createConfigHeader(b: *std.Build, config: Config) *std.Build.Step.ConfigHeader {
    if (config.config_header) |header| {
        const write_files = b.addWriteFiles();
        const template = write_files.add("config.h.in",
            \\#ifndef EMBED_ZIG_OGG_CONFIG_H
            \\#define EMBED_ZIG_OGG_CONFIG_H
            \\#include "@OGG_USER_CONFIG_HEADER@"
            \\#endif
            \\
        );
        return b.addConfigHeader(.{
            .style = .{ .autoconf_at = template },
            .include_path = "config.h",
        }, .{
            .OGG_USER_CONFIG_HEADER = normalizeIncludePath(b, header),
        });
    }

    return b.addConfigHeader(.{
        .style = .{ .autoconf_undef = b.path("pkg/ogg/config.h.in") },
        .include_path = "config.h",
    }, ConfigHeaderValues{});
}

fn createWrappedCSources(
    b: *std.Build,
    repo: GitRepo.GitRepo,
) []const std.Build.LazyPath {
    const write_files = b.addWriteFiles();
    const wrapper_sources = [_][]const u8{
        "src/bitwise.c",
        "src/framing.c",
    };
    const c_wrappers = b.allocator.alloc(std.Build.LazyPath, wrapper_sources.len) catch @panic("OOM");
    for (c_wrappers, wrapper_sources) |*wrapper, src| {
        wrapper.* = write_files.add(wrapperName(b, src), b.fmt(
            \\#include "config.h"
            \\#include "{s}"
            \\
        , .{normalizeIncludePath(b, repo.sourcePath(src))}));
    }
    return c_wrappers;
}

fn normalizeIncludePath(b: *std.Build, header: std.Build.LazyPath) []const u8 {
    const raw = header.getPath(b);
    const resolved = if (std.fs.path.isAbsolute(raw))
        raw
    else
        b.pathFromRoot(raw);
    return std.mem.replaceOwned(u8, b.allocator, resolved, "\\", "/") catch @panic("OOM");
}

fn wrapperName(b: *std.Build, src: []const u8) []const u8 {
    const flattened = std.mem.replaceOwned(u8, b.allocator, src, "/", "__") catch @panic("OOM");
    return b.fmt("{s}.wrap.c", .{flattened});
}
