const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const internal_dep = b.dependency("internal", .{
        .target = target,
        .optimize = optimize,
    });

    const embed_mod = b.createModule(.{
        .root_source_file = b.path("lib/embed.zig"),
        .target = target,
        .optimize = optimize,
    });
    embed_mod.addImport("stdz", internal_dep.module("stdz"));
    embed_mod.addImport("testing", internal_dep.module("testing"));
    embed_mod.addImport("context", internal_dep.module("context"));
    embed_mod.addImport("sync", internal_dep.module("sync"));
    embed_mod.addImport("io", internal_dep.module("io"));
    embed_mod.addImport("drivers", internal_dep.module("drivers"));
    embed_mod.addImport("net", internal_dep.module("net"));
    embed_mod.addImport("mime", internal_dep.module("mime"));
    embed_mod.addImport("bt", internal_dep.module("bt"));
    embed_mod.addImport("motion", internal_dep.module("motion"));
    embed_mod.addImport("audio", internal_dep.module("audio"));
    embed_mod.addImport("ledstrip", internal_dep.module("ledstrip"));
    embed_mod.addImport("zux", internal_dep.module("zux"));
    embed_mod.addImport("runtime", internal_dep.module("runtime"));
    b.modules.put("embed", embed_mod) catch @panic("OOM");

    const embed_std_mod = b.createModule(.{
        .root_source_file = b.path("lib/embed_std.zig"),
        .target = target,
        .optimize = optimize,
    });
    embed_std_mod.addImport("embed_std_internal", internal_dep.module("embed_std"));
    b.modules.put("embed_std", embed_std_mod) catch @panic("OOM");
}
