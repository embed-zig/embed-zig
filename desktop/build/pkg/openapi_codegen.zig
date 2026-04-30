const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const og_dep = b.dependency("openapi_codegen", .{
        .target = target,
        .optimize = optimize,
    });
    const embed_dep = b.dependency("embed", .{
        .target = target,
        .optimize = optimize,
    });

    const openapi_mod = b.createModule(.{
        .root_source_file = og_dep.path("lib/openapi.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("openapi", openapi_mod) catch @panic("OOM");

    const codegen_mod = b.createModule(.{
        .root_source_file = og_dep.path("lib/codegen.zig"),
        .target = target,
        .optimize = optimize,
    });
    codegen_mod.addImport("openapi", openapi_mod);
    codegen_mod.addImport("embed", embed_dep.module("embed"));
    codegen_mod.addImport("net", embed_dep.module("net"));
    codegen_mod.addImport("context", embed_dep.module("context"));
    b.modules.put("codegen", codegen_mod) catch @panic("OOM");
}

pub fn link(_: *std.Build) void {}

pub fn linkTest(_: *std.Build, _: *std.Build.Step.Compile) void {}
