const std = @import("std");
const build_modules = @import("build/modules.zig");
const build_tests = @import("tests/build.zig");
const esp_build = @import("esp/build.zig");

pub const esp = esp_build;

pub const desktop = struct {
    pub const macos = @import("build/desktop/macos.zig");
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sysroot = b.option([]const u8, "sysroot", "C sysroot path for cross-target libc headers") orelse "";
    const lvgl_c_short_enums = b.option(bool, "lvgl_c_short_enums", "Pass -fshort-enums to the LVGL C build") orelse false;
    const ble_speed_transport = b.option([]const u8, "ble_speed_transport", "BLE speed transport: raw-gatt or kcp-stream") orelse "raw-gatt";
    if (sysroot.len != 0) b.sysroot = sysroot;
    const embed_dep = b.dependency("embed", .{
        .target = target,
        .optimize = optimize,
    });
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const gstd_dep = b.dependency("gstd", .{
        .target = target,
        .optimize = optimize,
    });
    const desktop_dep = b.dependency("desktop", .{
        .target = target,
        .optimize = optimize,
    });
    const apps_dep = b.dependency("apps", .{
        .target = target,
        .optimize = optimize,
        .sysroot = sysroot,
        .lvgl_c_sysroot = sysroot,
        .lvgl_c_short_enums = lvgl_c_short_enums,
        .ble_speed_transport = ble_speed_transport,
    });
    const openapi_codegen_dep = b.dependency("openapi_codegen", .{
        .target = target,
        .optimize = optimize,
    });
    const thirdparty_dep = b.dependency("thirdparty", .{
        .target = target,
        .optimize = optimize,
    });
    const glib = glib_dep.module("glib");
    const gstd = gstd_dep.module("gstd");
    const embed = embed_dep.module("embed");
    const openapi = openapi_codegen_dep.module("openapi");
    const codegen = openapi_codegen_dep.module("codegen");
    const desktop_module = desktop_dep.module("desktop");
    const esp_modules = esp_build.createModules(b, .{
        .target = target,
        .optimize = optimize,
        .glib = glib,
        .embed_core = embed,
        .sources = esp_build.moduleSources(b, "esp"),
    });

    b.modules.put("glib", glib) catch @panic("OOM");
    b.modules.put("gstd", gstd) catch @panic("OOM");
    b.modules.put("embed", embed) catch @panic("OOM");
    b.modules.put("openapi", openapi) catch @panic("OOM");
    b.modules.put("codegen", codegen) catch @panic("OOM");
    b.modules.put("openapi-codegen", codegen) catch @panic("OOM");
    b.modules.put("desktop", desktop_module) catch @panic("OOM");
    b.modules.put("esp", esp_modules.esp) catch @panic("OOM");
    const apps_lvgl = apps_dep.module("lvgl");
    const apps_lvgl_osal = apps_dep.module("lvgl_osal");
    if (isKcpTransport(ble_speed_transport)) {
        apps_dep.module("zux_ble_speed_test_common").addImport("kcp", thirdparty_dep.module("kcp"));
    }
    for (build_modules.thirdparty_modules) |module_spec| {
        const module = if (std.mem.eql(u8, module_spec.dependency_module_name, "lvgl"))
            apps_lvgl
        else if (std.mem.eql(u8, module_spec.dependency_module_name, "lvgl_osal"))
            apps_lvgl_osal
        else
            thirdparty_dep.module(module_spec.dependency_module_name);
        b.modules.put(module_spec.export_name, module) catch @panic("OOM");
    }
    for (build_modules.apps_modules) |module_spec| {
        const app_mod = apps_dep.module(module_spec.dependency_module_name);
        app_mod.addImport("glib", glib);
        if (std.mem.startsWith(u8, module_spec.dependency_module_name, "zux_")) {
            app_mod.addImport("embed", embed);
            app_mod.addImport("lvgl", apps_lvgl);
        }
        if (std.mem.eql(u8, module_spec.dependency_module_name, "zux_kcp-test")) {
            app_mod.addImport("kcp", thirdparty_dep.module("kcp"));
        }
        b.modules.put(module_spec.export_name, app_mod) catch @panic("OOM");
    }

    desktop_module.addImport("embed", embed);
    desktop_module.addImport("glib", glib);
    desktop_module.addImport("gstd", gstd);
    desktop_module.addImport("openapi", openapi);
    desktop_module.addImport("codegen", codegen);
    desktop_module.addImport("core_bluetooth", thirdparty_dep.module("core_bluetooth"));
    desktop_module.addImport("core_wlan", thirdparty_dep.module("core_wlan"));
    desktop_module.addImport("portaudio", thirdparty_dep.module("portaudio"));
    desktop_module.addImport("speexdsp", thirdparty_dep.module("speexdsp"));

    addCmdctl(b, target, optimize, embed);
    build_tests.create(b, target, optimize);
}

fn isKcpTransport(transport: []const u8) bool {
    return std.mem.eql(u8, transport, "kcp-stream") or std.mem.eql(u8, transport, "kcp_stream");
}

fn addCmdctl(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    embed: *std.Build.Module,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("tools/cmdctl/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "embed", .module = embed },
        },
    });
    const exe = b.addExecutable(.{
        .name = "cmdctl",
        .root_module = mod,
    });
    const install = b.addInstallArtifact(exe, .{});

    const cmdctl_step = b.step("cmdctl", "Build the cmdctl host command tool");
    cmdctl_step.dependOn(&install.step);

    const unit_mod = b.createModule(.{
        .root_source_file = b.path("tests/tools_cmdctl.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cmdctl", .module = mod },
        },
    });
    const unit = b.addTest(.{
        .root_module = unit_mod,
    });
    const run_unit = b.addRunArtifact(unit);
    const test_step = b.step("cmdctl-test", "Run cmdctl unit tests");
    test_step.dependOn(&run_unit.step);
}
