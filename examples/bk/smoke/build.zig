const std = @import("std");
const bk = @import("bk");
const build_config = @import("build_config.zig");

pub fn build(b: *std.Build) void {
    const context = bk.armino.resolveBuildContext(b, .{
        .build_config = build_config,
    });
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSmall,
    });
    const bk_dep = b.dependency("bk", .{
        .target = context.zig_target,
        .optimize = optimize,
    });
    const bk_module = bk_dep.module("bk");
    const build_config_module = b.createModule(.{
        .root_source_file = b.path("build_config.zig"),
        .target = context.zig_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bk", .module = bk_module },
        },
    });

    const ap = addStaticLib(b, "smoke_ap_zig", "ap/main.zig", context.zig_target, optimize, bk_module, build_config_module);
    const cp = addStaticLib(b, "smoke_cp_zig", "cp/main.zig", context.zig_target, optimize, bk_module, build_config_module);

    const ap_install = b.addInstallArtifact(ap, .{});
    const cp_install = b.addInstallArtifact(cp, .{});

    const ap_step = b.step("ap", "Build AP Zig static library");
    ap_step.dependOn(&ap_install.step);

    const cp_step = b.step("cp", "Build CP Zig static library");
    cp_step.dependOn(&cp_install.step);

    const app = bk.armino.addDualCoreApp(b, "smoke", .{
        .context = context,
        .partition_table = build_config.partition_table,
        .ram_regions = build_config.ram_regions,
        .ap = .{
            .root_source_file = b.path("ap/main.zig"),
            .root_source_path = "ap/main.zig",
            .build_config = build_config.ap,
        },
        .cp = .{
            .root_source_file = b.path("cp/main.zig"),
            .root_source_path = "cp/main.zig",
            .build_config = build_config.cp,
        },
    });

    b.default_step.dependOn(app.package);
}

fn addStaticLib(
    b: *std.Build,
    name: []const u8,
    root_source_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    bk_module: *std.Build.Module,
    build_config_module: *std.Build.Module,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_source_file),
            .target = target,
            .optimize = optimize,
            .unwind_tables = .none,
            .imports = &.{
                .{ .name = "bk", .module = bk_module },
                .{ .name = "build_config", .module = build_config_module },
            },
        }),
    });
    lib.bundle_compiler_rt = false;
    return lib;
}
