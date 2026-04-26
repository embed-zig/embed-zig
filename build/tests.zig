const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    comptime Packages: type,
) void {
    const test_step = b.step("test", "Run all package tests");

    inline for (@typeInfo(Packages).@"struct".decls) |decl| {
        const pkg_name = decl.name;
        const pkg = @field(Packages, pkg_name);
        const enabled = if (comptime @hasDecl(pkg, "testSupported"))
            pkg.testSupported(b, target)
        else
            true;
        if (enabled) {
            const pkg_step = b.step(b.fmt("test-all-{s}", .{pkg_name}), b.fmt("Run all {s} tests", .{pkg_name}));
            const compile_test = b.addTest(.{
                .root_module = b.modules.get(pkg_name) orelse @panic("package test module missing"),
            });
            pkg.linkTest(b, target, optimize, compile_test);

            const run_test = b.addRunArtifact(compile_test);
            run_test.setName(b.fmt("{s}:test", .{pkg_name}));
            test_step.dependOn(&run_test.step);
            pkg_step.dependOn(&run_test.step);
        }
    }
}

pub fn addCommonImports(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    compile_test: *std.Build.Step.Compile,
) void {
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const gstd_dep = b.dependency("gstd", .{
        .target = target,
        .optimize = optimize,
    });

    compile_test.root_module.addImport("embed_std", createEmbedStdShim(b, target, optimize, gstd_dep));
    compile_test.root_module.addImport("glib", glib_dep.module("glib"));
    compile_test.root_module.addImport("gstd", gstd_dep.module("gstd"));
}

pub fn createEmbedShim(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    gstd_dep: *std.Build.Dependency,
) *std.Build.Module {
    const embed_shim = b.addWriteFiles().add("embed.zig",
        \\pub const ArrayListUnmanaged = @import("gstd").runtime.std.ArrayListUnmanaged;
        \\pub const fmt = @import("gstd").runtime.std.fmt;
        \\pub const mem = @import("gstd").runtime.std.mem;
        \\pub const atomic = @import("gstd").runtime.std.atomic;
        \\
    );
    const mod = b.createModule(.{
        .root_source_file = embed_shim,
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("gstd", gstd_dep.module("gstd"));
    return mod;
}

pub fn createDriversShim(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const drivers_shim = b.addWriteFiles().add("drivers.zig",
        \\pub const Display = @import("embed_pkg").drivers.Display;
        \\pub const wifi = @import("embed_pkg").drivers.wifi;
        \\
    );
    const mod = b.createModule(.{
        .root_source_file = drivers_shim,
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("embed_pkg", b.modules.get("embed") orelse @panic("embed module missing"));
    return mod;
}

pub fn createBtShim(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const bt_shim = b.addWriteFiles().add("bt.zig",
        \\const bt = @import("embed_pkg").bt;
        \\
        \\pub const make = bt.make;
        \\pub const Central = bt.Central;
        \\pub const Peripheral = bt.Peripheral;
        \\pub const Host = bt.Host;
        \\pub const Hci = bt.Hci;
        \\pub const test_runner = bt.test_runner;
        \\
    );
    const mod = b.createModule(.{
        .root_source_file = bt_shim,
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("embed_pkg", b.modules.get("embed") orelse @panic("embed module missing"));
    return mod;
}

fn createEmbedStdShim(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    gstd_dep: *std.Build.Dependency,
) *std.Build.Module {
    const embed_std_shim = b.addWriteFiles().add("embed_std.zig",
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
