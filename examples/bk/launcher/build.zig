const std = @import("std");
const bk = @import("bk");
const build_config = @import("build_config.zig");

pub fn build(b: *std.Build) void {
    const app_name = b.option([]const u8, "app", "App module exported by the apps package") orelse "zux_colorbar";
    const board_name = b.option([]const u8, "board", "BK board: bk7258_v3_2024") orelse build_config.Board.name;
    validateBoard(board_name);

    const context = bk.armino.resolveBuildContext(b, .{
        .build_config = build_config,
    });
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe,
    });
    const bk_dep = b.dependency("bk", .{
        .target = context.zig_target,
        .optimize = optimize,
    });
    const glib_module = b.dependency("glib", .{
        .target = context.zig_target,
        .optimize = optimize,
    }).module("glib");
    const lvgl_c_sysroot = b.pathJoin(&.{ context.toolchain_dir, "arm-none-eabi" });
    const apps_dep = b.dependency("apps", .{
        .target = context.zig_target,
        .optimize = optimize,
        .lvgl_c_sysroot = lvgl_c_sysroot,
        .lvgl_c_short_enums = true,
    });
    const thirdparty_dep = b.dependency("thirdparty", .{
        .target = context.zig_target,
        .optimize = optimize,
        .lvgl_c_sysroot = lvgl_c_sysroot,
        .lvgl_c_short_enums = true,
    });
    const bk_module = bk_dep.module("bk");
    const selected_app = selectedAppModule(b, app_name, context.zig_target, optimize, bk_module, apps_dep);
    const lvgl_osal = thirdparty_dep.module("lvgl_osal");
    const build_config_module = b.createModule(.{
        .root_source_file = b.path("build_config.zig"),
        .target = context.zig_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bk", .module = bk_module },
        },
    });

    const ap = addStaticLib(b, "launcher_ap_zig", "ap/main.zig", context.zig_target, optimize, bk_module, build_config_module, glib_module, selected_app, lvgl_osal);
    const cp = addStaticLib(b, "launcher_cp_zig", "cp/main.zig", context.zig_target, optimize, bk_module, build_config_module, null, null, null);
    var lvgl_component = bk.armino.Component.create(b, .{
        .name = "lvgl",
    });
    lvgl_component.addArtifact(thirdparty_dep.artifact("lvgl"));

    const ap_install = b.addInstallArtifact(ap, .{});
    const lvgl_install = b.addInstallArtifact(thirdparty_dep.artifact("lvgl"), .{});
    const cp_install = b.addInstallArtifact(cp, .{});

    const ap_step = b.step("ap", "Build AP Zig static library");
    ap_step.dependOn(&ap_install.step);
    ap_step.dependOn(&lvgl_install.step);

    const cp_step = b.step("cp", "Build CP Zig static library");
    cp_step.dependOn(&cp_install.step);

    const app = bk.armino.addDualCoreApp(b, "launcher", .{
        .context = context,
        .zig_build_options = &.{
            b.fmt("-Dapp={s}", .{app_name}),
        },
        .partition_table = build_config.partition_table,
        .ram_regions = build_config.ram_regions,
        .ap = .{
            .root_source_file = b.path("ap/main.zig"),
            .root_source_path = "ap/main.zig",
            .extra_source_paths = &.{},
            .components = &.{lvgl_component},
            .build_config = build_config.ap,
        },
        .cp = .{
            .root_source_file = b.path("cp/main.zig"),
            .root_source_path = "cp/main.zig",
            .extra_source_paths = &.{},
            .build_config = build_config.cp,
        },
    });

    const build_step = b.step("build", "Build the BK launcher example");
    build_step.dependOn(app.package);
    b.default_step = build_step;
}

fn selectedAppModule(
    b: *std.Build,
    app_name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    bk_module: *std.Build.Module,
    apps_dep: *std.Build.Dependency,
) *std.Build.Module {
    if (std.mem.eql(u8, app_name, "raw_colorbar")) {
        return b.createModule(.{
            .root_source_file = b.path("apps/raw_colorbar.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bk", .module = bk_module },
            },
        });
    }
    return apps_dep.module(app_name);
}

fn validateBoard(board_name: []const u8) void {
    if (std.mem.eql(u8, board_name, "bk7258_v3_2024")) return;
    std.debug.panic("unknown board '{s}', expected bk7258_v3_2024", .{board_name});
}

fn addStaticLib(
    b: *std.Build,
    name: []const u8,
    root_source_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    bk_module: *std.Build.Module,
    build_config_module: *std.Build.Module,
    glib_module: ?*std.Build.Module,
    selected_app_module: ?*std.Build.Module,
    lvgl_osal_module: ?*std.Build.Module,
) *std.Build.Step.Compile {
    var imports = std.array_list.Managed(std.Build.Module.Import).init(b.allocator);
    imports.append(.{ .name = "bk", .module = bk_module }) catch @panic("OOM");
    imports.append(.{ .name = "build_config", .module = build_config_module }) catch @panic("OOM");
    if (glib_module) |module| {
        imports.append(.{ .name = "glib", .module = module }) catch @panic("OOM");
    }
    if (selected_app_module) |module| {
        imports.append(.{ .name = "selected_app", .module = module }) catch @panic("OOM");
    }
    if (lvgl_osal_module) |module| {
        imports.append(.{ .name = "lvgl_osal", .module = module }) catch @panic("OOM");
    }

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_source_file),
            .target = target,
            .optimize = optimize,
            .unwind_tables = .none,
            .imports = imports.toOwnedSlice() catch @panic("OOM"),
        }),
    });
    lib.bundle_compiler_rt = false;
    return lib;
}
