const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    glib_dep: *std.Build.Dependency,
    glib_stdrt_mod: *std.Build.Module,
) void {
    const test_mod = b.createModule(.{
        .root_source_file = b.path("test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("glib", glib_dep.module("glib"));
    _ = glib_stdrt_mod;

    const compile_test = b.addTest(.{
        .root_module = test_mod,
    });
    const run_test = b.addRunArtifact(compile_test);

    const test_step = b.step("test", "Run glib_stdrt tests");
    test_step.dependOn(&run_test.step);
}
