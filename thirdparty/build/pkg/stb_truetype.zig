const std = @import("std");

var library: ?*std.Build.Step.Compile = null;

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const local_include = b.path("pkg/stb_truetype/include");

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "stb_truetype",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_c = .off,
        }),
    });
    lib.root_module.addIncludePath(local_include);
    if (b.sysroot) |sysroot| {
        lib.root_module.addSystemIncludePath(.{
            .cwd_relative = b.pathJoin(&.{ sysroot, "include" }),
        });
    }
    lib.root_module.addCSourceFile(.{
        .file = b.path("pkg/stb_truetype/src/binding.c"),
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("pkg/stb_truetype.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(local_include);
    if (b.sysroot) |sysroot| {
        mod.addSystemIncludePath(.{
            .cwd_relative = b.pathJoin(&.{ sysroot, "include" }),
        });
    }
    b.modules.put("stb_truetype", mod) catch @panic("OOM");
    library = lib;
}

pub fn link(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const embed_dep = b.dependency("embed", .{
        .target = target,
        .optimize = optimize,
    });
    const mod = b.modules.get("stb_truetype") orelse @panic("stb_truetype module missing");
    const lib = library orelse @panic("stb_truetype library missing");
    mod.addImport("glib", glib_dep.module("glib"));
    mod.addImport("embed", embed_dep.module("embed"));
    mod.addObjectFile(lib.getEmittedBin());
}
