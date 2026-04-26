const std = @import("std");
const build_tests = @import("../tests.zig");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("pkg/core_bluetooth.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("core_bluetooth", mod) catch @panic("OOM");
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
    const mod = b.modules.get("core_bluetooth") orelse @panic("core_bluetooth module missing");
    mod.addImport("bt", build_tests.createBtShim(b, target, optimize));
    mod.addImport("embed_std", createEmbedStdShim(b, target, optimize, gstd_dep));
    mod.addImport("gstd", gstd_dep.module("gstd"));
    mod.addImport("testing", glib_dep.module("testing"));

    if (target.result.os.tag == .macos) {
        mod.linkFramework("CoreBluetooth", .{});
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
    compile_test.root_module.addImport("bt", build_tests.createBtShim(b, target, optimize));
    compile_test.root_module.addImport("gstd", b.dependency("gstd", .{
        .target = target,
        .optimize = optimize,
    }).module("gstd"));
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
    const embed_std_shim = b.addWriteFiles().add("core_bluetooth_embed_std.zig",
        \\pub const std = @import("gstd").runtime.std;
        \\pub const sync = @import("gstd").runtime.sync;
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
