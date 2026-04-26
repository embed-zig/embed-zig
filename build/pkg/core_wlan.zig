const std = @import("std");
const build_tests = @import("../tests.zig");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("pkg/core_wlan.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("core_wlan", mod) catch @panic("OOM");
}

pub fn link(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const gstd_dep = b.dependency("gstd", .{
        .target = target,
        .optimize = optimize,
    });
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const mod = b.modules.get("core_wlan") orelse @panic("core_wlan module missing");
    mod.addImport("embed", build_tests.createEmbedShim(b, target, optimize, gstd_dep));
    mod.addImport("embed_std", createEmbedStdShim(b, target, optimize, gstd_dep));
    mod.addImport("glib", glib_dep.module("glib"));
    mod.addImport("drivers", build_tests.createDriversShim(b, target, optimize));

    if (target.result.os.tag == .macos) {
        mod.linkFramework("CoreWLAN", .{});
        mod.linkFramework("Foundation", .{});
        mod.linkSystemLibrary("objc", .{});
    }
}

pub fn linkTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    compile_test: *std.Build.Step.Compile,
) void {
    build_tests.addCommonImports(b, target, optimize, compile_test);
    compile_test.root_module.addImport("drivers", build_tests.createDriversShim(b, target, optimize));
    compile_test.root_module.addImport("embed", build_tests.createEmbedShim(b, target, optimize, b.dependency("gstd", .{
        .target = target,
        .optimize = optimize,
    })));
}

pub fn testSupported(_: *std.Build, target: std.Build.ResolvedTarget) bool {
    return target.result.os.tag == .macos;
}

fn createEmbedStdShim(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    gstd_dep: *std.Build.Dependency,
) *std.Build.Module {
    const embed_std_shim = b.addWriteFiles().add("core_wlan_embed_std.zig",
        \\pub const std = @import("gstd").runtime.std;
        \\
    );
    const mod = b.createModule(.{
        .root_source_file = embed_std_shim,
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("gstd", gstd_dep.module("gstd"));
    return mod;
}
